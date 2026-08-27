#!/bin/bash
# USB/SSD resilience hardening for RPi4 + RTL9210B-CG (0bda:9210).
# Safe to run ONLY once root is already on the SD card: if bulk-only transport
# turned out to break this bridge, the machine must not need it to boot.
set -euo pipefail

ROOTSRC=$(findmnt -n -o SOURCE /)
case "$ROOTSRC" in
  *mmcblk0p2*) : ;;
  *) echo "REFUSING: root is $ROOTSRC, expected /dev/mmcblk0p2. Run this only after the SD cutover."; exit 1;;
esac

CM=/boot/firmware/cmdline.txt
cp -a "$CM" "${CM}.pre-usbharden.$(date +%Y%m%d-%H%M%S)"

add_param() {
  local p="$1" key="${1%%=*}"
  if grep -qw -- "$p" "$CM"; then
    echo "  already present: $p"
  elif grep -qE "(^| )${key}=" "$CM"; then
    sed -i -E "s|(^| )${key}=[^ ]*|\1${p}|" "$CM"; echo "  replaced: $p"
  else
    sed -i -E "s|[[:space:]]*$| ${p}|" "$CM"; echo "  added: $p"
  fi
}
echo "=== cmdline before ==="; cat "$CM"
add_param "usb-storage.quirks=0bda:9210:u"   # IGNORE_UAS -> bulk-only transport
add_param "usbcore.quirks=0bda:9210:k"       # NO_LPM -> stop U1/U2 link-power negotiation
add_param "usbcore.autosuspend=-1"           # never autosuspend the bridge
# cmdline.txt must stay exactly one line
tr -d '\n' < "$CM" > "${CM}.tmp" && printf '\n' >> "${CM}.tmp" && mv "${CM}.tmp" "$CM"
echo "=== cmdline after ==="; cat "$CM"
[ "$(wc -l < "$CM")" -eq 1 ] || { echo "FATAL: cmdline.txt is not one line"; exit 1; }

echo "=== udev: long SCSI timeouts for this bridge ==="
cat > /etc/udev/rules.d/99-rtl9210-timeout.rules <<'UDEV'
# Survive long USB stalls instead of erroring out and dropping the device.
ACTION=="add|change", KERNEL=="sd[a-z]", SUBSYSTEMS=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="9210", \
  RUN+="/bin/sh -c 'echo 180 > /sys/block/%k/device/timeout; echo 60 > /sys/block/%k/device/eh_timeout'"
UDEV
udevadm control --reload

echo "=== hardware watchdog (BCM2835 ceiling is 15s -> request 10s) ==="
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/10-watchdog.conf <<'WD'
[Manager]
RuntimeWatchdogSec=10
RebootWatchdogSec=2min
WD
echo "  configured. current hw ceiling: $(cat /sys/class/watchdog/watchdog0/timeout)s"

echo "=== DONE. Reboot required for cmdline + watchdog to take effect. ==="
