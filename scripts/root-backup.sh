#!/bin/bash
# Weekly backup of the SD-card root onto the USB SSD, keeping the SSD a COMPLETE,
# BOOTABLE fallback root. Replaces sd-clone.sh, whose direction (SSD -> SD) was
# inverted by the 2026-08-27 migration.
#
# Layout since 2026-08-27:
#   /              = SD card p2   (OS only, ~20G)
#   /mnt/ssd       = USB SSD sda1 (bulk data + this backup copy of the OS)
#   /var/lib/qbt   = bind of /mnt/ssd/var/lib/qbt  (73G, cloud-backed, NEVER copied to SD)
#
# Rollback if the SD card dies: swap cmdline.txt <-> cmdline.ssd.txt on /boot/firmware.
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

DEST=/mnt/ssd

# --- guards -----------------------------------------------------------------
CURROOT=$(findmnt -n -o SOURCE /)
case "$CURROOT" in
  *mmcblk0p2*) : ;;
  *) echo "REFUSING: root is $CURROOT, expected the SD card. Are you running from the SSD fallback?"; exit 1;;
esac
mountpoint -q "$DEST" || { echo "REFUSING: $DEST is not mounted (SSD absent?)"; exit 1; }
findmnt -n -o SOURCE "$DEST" | grep -q sda1 || { echo "REFUSING: $DEST is not sda1"; exit 1; }
[ -e /run/initramfs/degraded-boot ] && exit 1

/usr/local/sbin/io-health.sh
if [ -e /root/ALERT-io-health.txt ] && [ "$FORCE" -ne 1 ]; then
  logger -t root-backup "REFUSING backup"; /usr/local/sbin/ha-alert.sh "Weekly root backup REFUSED: SSD health alerts exist"; exit 1
elif [ -e /root/ALERT-io-health.txt ]; then
  logger -t root-backup "WARNING: forced backup despite ALERT - user override"
fi
for sf in /etc/passwd /etc/fstab /usr/bin/dockerd /boot/firmware/cmdline.txt /usr/local/sbin/ssd-recover.sh; do
  [ -s "$sf" ] || { logger -t root-backup "REFUSING: sentinel $sf missing/empty"; /usr/local/sbin/ha-alert.sh "Root backup REFUSED: $sf missing - possible corruption"; exit 1; }
done

exec > /root/root-backup.log 2>&1

touch /run/sd-clone.active   # ha-core-watchdog.sh stands down on this flag
APPS_STATE=/run/sd-clone.apps
core_up() {
  systemctl start docker 2>/dev/null
  systemctl start hassio-supervisor 2>/dev/null
  for i in $(seq 1 60); do docker exec hassio_cli ha core info --no-progress >/dev/null 2>&1 && break; sleep 5; done
  docker exec hassio_cli ha core start --no-progress >/dev/null 2>&1 || docker start homeassistant >/dev/null 2>&1
  while read -r slug; do
    [ -n "$slug" ] && docker exec hassio_cli ha apps start "$slug" --no-progress >/dev/null 2>&1
  done < <(cat "$APPS_STATE" 2>/dev/null)
}
trap 'core_up; rm -f /run/sd-clone.active "$APPS_STATE"' EXIT

docker exec hassio_cli ha apps --raw-json --no-progress 2>/dev/null \
  | python3 -c 'import json,sys; d=next(iter(json.load(sys.stdin)["data"].values())); print("\n".join(a["slug"] for a in d if a.get("state")=="started"))' \
  > "$APPS_STATE" 2>/dev/null || : > "$APPS_STATE"
echo "=== apps running before backup: $(tr '\n' ' ' < "$APPS_STATE") ==="

echo "=== source root: $CURROOT   dest: $DEST ($(findmnt -n -o SOURCE $DEST)) ==="
df -h / "$DEST" | grep -v ^Filesystem

echo "=== stopping HA core $(date) ==="
docker exec hassio_cli ha core stop --no-progress || docker stop -t 120 homeassistant
docker ps --format '{{.Names}}' | grep -qx homeassistant && { echo "FATAL: homeassistant still running"; exit 1; }
echo "=== stopping supervisor/docker $(date) ==="
systemctl stop hassio-supervisor
systemctl stop docker docker.socket

# qbittorrent is NOT stopped: its data and config live entirely under /var/lib/qbt,
# which is on the destination disk and is excluded below.

echo "=== rsync start $(date) ==="
# --delete is dangerous here: the destination also holds 73G of live bulk data.
# /var/lib/qbt MUST stay excluded, and rsync protects excluded paths from --delete.
rsync -aHAXx --delete --info=stats1 \
  --exclude=/proc/* --exclude=/sys/* --exclude=/dev/* --exclude=/run/* \
  --exclude=/tmp/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found \
  --exclude=/var/lib/qbt --exclude=/var/lib/qbt/** \
  / "$DEST"/
RS=$?
echo "=== rsync exit=$RS $(date) ==="

echo "=== bulk data untouched? ==="
echo "  /mnt/ssd/var/lib/qbt = $(du -sh $DEST/var/lib/qbt 2>/dev/null | cut -f1)"

systemctl start docker
systemctl start hassio-supervisor

echo "=== fstab on the SSD copy -> standalone bootable root ==="
SSD_PARTUUID=$(blkid -s PARTUUID -o value /dev/sda1)
grep -vE "^[^#[:space:]]+[[:space:]]+/[[:space:]]" "$DEST/etc/fstab" > "$DEST/etc/fstab.new"
sed -i '\|/mnt/ssd|d;\|/var/lib/qbt|d;/swapfile/d' "$DEST/etc/fstab.new"
echo "PARTUUID=$SSD_PARTUUID  /  ext4  defaults,noatime  0  1" >> "$DEST/etc/fstab.new"
mv "$DEST/etc/fstab.new" "$DEST/etc/fstab"
mkdir -p "$DEST/mnt/ssd" "$DEST/var/lib/qbt"
chmod 1777 "$DEST/tmp" 2>/dev/null
grep -v '^#' "$DEST/etc/fstab"

echo "=== refresh the SSD rescue cmdline ==="
sed -E "s|root=[^ ]+|root=PARTUUID=$SSD_PARTUUID|" /boot/firmware/cmdline.txt > /boot/firmware/cmdline.ssd.txt.new \
  && mv /boot/firmware/cmdline.ssd.txt.new /boot/firmware/cmdline.ssd.txt
cat /boot/firmware/cmdline.ssd.txt
{ echo "CURRENT LAYOUT: root = SD card p2. USB SSD = /mnt/ssd (nofail), bulk data + this fallback root.";
  echo "";
  echo "SD CARD DEAD? Boot the SSD fallback:";
  echo "  1. rename cmdline.txt     -> cmdline.sd.txt";
  echo "  2. rename cmdline.ssd.txt -> cmdline.txt";
  echo "  3. power cycle";
  echo "";
  echo "SSD DEAD OR UNPLUGGED? Nothing to do - the OS boots from SD and does not need it.";
  echo "Only qbittorrent stops. ssd-recover.service retries automatically.";
  echo "";
  echo "Backup date: $(date)"; } > /boot/firmware/RESCUE-README.txt

echo "=== spot check (files that actually exist on this system) ==="
for f in /etc/fstab /etc/systemd/system/netmeasure.service /etc/systemd/system/netmeasure-ppp.service \
         /usr/local/sbin/ssd-recover.sh /usr/local/sbin/io-health.sh /root/netmeasure/probe.sh \
         /etc/udev/rules.d/98-rtl9210-recover.rules /etc/systemd/system.conf.d/10-watchdog.conf; do
  if [ "$f" = /etc/fstab ]; then
    [ -s "$DEST$f" ] && echo "OK   $f (intentionally differs: root device)" || echo "MISSING $f"
  elif cmp -s "$f" "$DEST$f"; then echo "OK   $f"; else echo "MISMATCH $f"; fi
done
df -h "$DEST" | tail -1

echo "=== bringing HA core back $(date) ==="
core_up
docker ps --format '{{.Names}}'
CODE=000
for i in $(seq 1 60); do
  CODE=$(curl -s -o /dev/null -m 5 -w "%{http_code}" http://127.0.0.1:8123/ 2>/dev/null)
  case "$CODE" in 200|30[123]|401) break;; esac
  sleep 10
done
echo "8123 http=$CODE after backup $(date)"
case "$CODE" in
  200|30[123]|401) echo "=== ALL DONE (core healthy) ===";;
  *) logger -t root-backup "HA core did NOT come back (http=$CODE)"
     /usr/local/sbin/ha-alert.sh "Root backup finished but HA core is NOT responding on 8123 (http=$CODE)"
     echo "=== DONE WITH ERROR: core unreachable ===";;
esac
