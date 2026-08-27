#!/bin/bash
# Bring the USB SSD back after an intermittent disconnect, with no human hands.
# Triggered by udev when 0bda:9210 reappears, and by ssd-recover.timer every 5 min.
#
# Measured on this hardware 2026-08-27 by unbinding the USB device live:
#   - a plain SCSI host rescan does NOT recover this bridge
#   - toggling /sys/bus/usb/devices/2-1/authorized 0 -> 1 DOES
# so the escalation ladder below is ordered by what actually worked, not by theory.
set -uo pipefail

LOG=/var/lib/ssd-recover.log
LOCK=/run/ssd-recover.lock
USBDEV=/sys/bus/usb/devices/2-1
DEV=/dev/sda1

exec >> "$LOG" 2>&1
if [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -c 131072 "$LOG" > "$LOG.trim" && mv "$LOG.trim" "$LOG"
fi

log(){ echo "$(date -Is) $*"; logger -t ssd-recover -- "$*"; }
alert(){ [ -x /usr/local/sbin/ha-alert.sh ] && /usr/local/sbin/ha-alert.sh "$*" >/dev/null 2>&1; }

# A loose connector can flap many times per second. Without this, udev would start a
# fresh recovery for every flap and they would fight each other over the same device.
# Non-blocking: if a recovery is already in flight, this invocation simply steps aside.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "$(date -Is) another recovery already running (trigger=${1:-manual}), skipping"
  exit 0
fi

log "--- trigger=${1:-manual} ---"

# mount_ssd: mount, then make sure we did not land read-only. A dirty ext4 replays its
# journal automatically, but a filesystem with real errors mounts ro (or not at all) and
# every write then fails silently. Only in that case do we run a conservative preen fsck.
mount_ssd() {
  mount /mnt/ssd 2>/dev/null
  if mountpoint -q /mnt/ssd && ! findmnt -n -o OPTIONS /mnt/ssd | grep -Eq '(^|,)ro(,|$)'; then
    # writable smoke test: options can lie if the fs flipped ro after an error
    if touch /mnt/ssd/.rwtest 2>/dev/null; then
      rm -f /mnt/ssd/.rwtest
      return 0
    fi
    log "mounted but NOT writable -> treating as dirty"
  fi
  # not mounted, or mounted read-only / unwritable
  if mountpoint -q /mnt/ssd; then
    umount /mnt/ssd 2>/dev/null || umount -l /mnt/ssd 2>/dev/null
    sleep 1
  fi
  # Running e2fsck against a still-mounted filesystem corrupts it. If we cannot get
  # it detached, stop here and let a human look instead.
  if findmnt -S "$DEV" >/dev/null 2>&1; then
    log "REFUSING e2fsck: $DEV is still mounted somewhere"
    alert "RPi4: SSD is stuck mounted and unwritable; refusing to fsck it. Needs a human."
    return 1
  fi
  log "running e2fsck -p (safe repairs only) on $DEV"
  timeout 900 e2fsck -p "$DEV"
  rc=$?
  # 0 = clean, 1 = errors corrected. >=2 needs a human.
  if [ "$rc" -ge 2 ]; then
    log "e2fsck returned $rc -- manual intervention required, NOT mounting"
    alert "RPi4: SSD filesystem needs a manual fsck (e2fsck rc=$rc). OS is fine, root is on SD. qbittorrent stays down."
    return 1
  fi
  log "e2fsck rc=$rc, retrying mount"
  mount /mnt/ssd 2>/dev/null && mountpoint -q /mnt/ssd
}

# 0. Fast path: everything already healthy.
if mountpoint -q /mnt/ssd && timeout 5 stat /mnt/ssd >/dev/null 2>&1 \
   && timeout 5 touch /mnt/ssd/.rwtest 2>/dev/null; then
  rm -f /mnt/ssd/.rwtest
  if ! mountpoint -q /var/lib/qbt; then
    mount /var/lib/qbt && log "re-bound /var/lib/qbt"
    systemctl is-enabled qbittorrent >/dev/null 2>&1 && systemctl restart qbittorrent
  fi
  exit 0
fi

# 1. A mount whose device vanished will hang every process that touches it.
#    Stop the one service that actually holds file handles there before detaching,
#    rather than fuser -k, which would also take docker and Home Assistant down.
if mountpoint -q /mnt/ssd; then
  log "stale mount at /mnt/ssd -> stopping qbittorrent, then lazy unmount"
  systemctl stop qbittorrent 2>/dev/null
  mountpoint -q /var/lib/qbt && umount -l /var/lib/qbt
  umount -l /mnt/ssd
  sleep 2
  mountpoint -q /mnt/ssd && log "WARNING: /mnt/ssd still shows as a mountpoint after lazy unmount"
fi

# 2. Get the block device back.
attempt=0
while [ ! -b "$DEV" ] && [ "$attempt" -lt 4 ]; do
  attempt=$((attempt+1))
  log "sda1 absent, recovery attempt $attempt"

  # 2a. cheapest: ask the SCSI layer to look again
  for h in /sys/class/scsi_host/host*; do echo "- - -" > "$h/scan" 2>/dev/null; done
  sleep 5
  [ -b "$DEV" ] && break

  # 2b. the one that actually works on the RTL9210: deauthorise and reauthorise, forcing
  #     a full re-enumeration instead of the half-initialised xhci reset loop it otherwise
  #     gets stuck in
  if [ -w "$USBDEV/authorized" ]; then
    log "authorized toggle on $USBDEV"
    echo 0 > "$USBDEV/authorized" 2>/dev/null
    sleep 4
    echo 1 > "$USBDEV/authorized" 2>/dev/null
    sleep 12
  else
    log "WARNING: $USBDEV/authorized not writable (bridge not enumerated at all)"
    sleep 10
  fi
  [ -b "$DEV" ] && break

  # 2c. last resort: re-bind the usb-storage interface
  echo 2-1:1.0 > /sys/bus/usb/drivers/usb-storage/unbind 2>/dev/null
  sleep 3
  echo 2-1:1.0 > /sys/bus/usb/drivers/usb-storage/bind 2>/dev/null
  sleep 10
done

if [ ! -b "$DEV" ]; then
  log "FAILED: sda1 still absent after $attempt attempts"
  alert "RPi4: USB SSD did not come back after $attempt recovery attempts. OS is fine (root is on SD); qbittorrent stays down."
  exit 1
fi
log "sda1 present after $attempt attempt(s)"
udevadm settle --timeout=20 || true

# 3. Mount (with the read-only / dirty handling above).
if mount_ssd; then
  log "mounted /mnt/ssd rw"
else
  log "FAILED: could not get /mnt/ssd mounted read-write"
  exit 1
fi

mountpoint -q /var/lib/qbt || mount /var/lib/qbt || log "bind of /var/lib/qbt failed"

if systemctl is-enabled qbittorrent >/dev/null 2>&1; then
  systemctl restart qbittorrent && log "qbittorrent restarted"
fi
log "recovery complete"
