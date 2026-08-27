# Surviving a flaky USB SSD on a Raspberry Pi 4

**English** · [繁體中文](STORAGE-RESILIENCE.en.md)

The probe host was crashing whenever the desk was bumped. This is what was actually
wrong, and the three bugs found while proving the fix works — including two that would
have left the machine dead and unreachable.

Hardware: RPi 4, DietPi on Debian 13, USB SSD behind a **Realtek RTL9210B-CG**
(`0bda:9210`), root filesystem on that SSD.

## The four things that were wrong

Only the first is obvious.

**1. Root lived on the removable disk.** A momentary contact glitch on a USB connector
should cost you a mount. It should not cost you the kernel. With root on the SSD, every
flicker was fatal.

**2. UAS was bound to the bridge.** `/sys/bus/usb/drivers/uas/2-1:1.0`, no quirks set
anywhere. RPi 4 + RTL9210 + UAS is a well-known stall combination.

**3. USB3 link power management was failing every boot:**

```
usb 2-1: enable of device-initiated U1 failed
```

LPM negotiation failing is a classic source of spurious disconnects and is easy to miss
because the device works anyway.

**4. There was no evidence, and that was structural.** The persistent journal was
bind-mounted from a directory **on the SSD**, and `/var/log` is a 50 MB tmpfs (DietPi
ramlog). So when the disk dropped, the log of the disk dropping died with it.
`journalctl --list-boots` showed one boot. Months of crashes, zero forensics.

> If you are debugging intermittent storage, check where your logs live **first**.
> Everything else is guessing until that is fixed.

## The fix

**Invert the roles.** Root on the SD card; the SSD demoted to a `nofail` data mount.

```
# /etc/fstab
PARTUUID=<ssd>  /mnt/ssd  ext4  nofail,noatime,x-systemd.device-timeout=10,x-systemd.mount-timeout=20  0 0
/mnt/ssd/var/lib/<app>  /var/lib/<app>  none  bind,nofail,x-systemd.requires=/mnt/ssd  0 0
```

Plus `RequiresMountsFor=` on the service that uses the data, so it cannot start against
an empty mountpoint and quietly corrupt its own state.

**Harden the bridge** on the kernel command line:

```
usb-storage.quirks=0bda:9210:u    # IGNORE_UAS -> bulk-only transport
usbcore.quirks=0bda:9210:k        # NO_LPM -> stop the U1/U2 negotiation that was failing
usbcore.autosuspend=-1
```

and give the SCSI layer room to retry instead of giving up, via udev:

```
ACTION=="add|change", KERNEL=="sd[a-z]", SUBSYSTEMS=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="9210", \
  RUN+="/bin/sh -c 'echo 180 > /sys/block/%k/device/timeout; echo 60 > /sys/block/%k/device/eh_timeout'"
```

Confirmation it took effect:

```
usb 2-1: UAS is ignored for this device, using usb-storage instead
usb-storage 2-1:1.0: Quirks match for vid 0bda pid 9210: 800000
```

and the `U1 failed` line stops appearing. Cost: sequential read drops to ~153 MB/s
without command queuing. For bulk storage that is a fine trade; it is still several times
an SD card.

> **Order matters.** Apply the USB quirks only *after* root is off the SSD. If bulk-only
> transport turns out to break your bridge while root still lives on it, the machine will
> not boot — and you may not be there to fix it.

## Three bugs found by actually testing it

None of these show up until you pull the disk. Simulate it at the bus level:

```
echo 2-1 > /sys/bus/usb/drivers/usb/unbind    # yank
echo 2-1 > /sys/bus/usb/drivers/usb/bind      # plug back in
```

**Bug 1 — the bridge does not come back on its own.** After a rebind it re-enumerates
(`lsusb` sees it, `usb-storage` attaches, a SCSI host is created) and then **no block
device ever appears**. It loops on:

```
usb 2-1: reset SuperSpeed USB device number 2 using xhci_hcd
```

A SCSI host rescan (`echo "- - -" > /sys/class/scsi_host/host0/scan`) does **not** fix
it. What does, reliably, first attempt, every time:

```
echo 0 > /sys/bus/usb/devices/2-1/authorized
sleep 4
echo 1 > /sys/bus/usb/devices/2-1/authorized
```

Deauthorising forces a genuine re-enumeration instead of the half-initialised reset loop.
This is the single most useful thing in this document.

**Bug 2 — the udev rule can never fire.** The obvious trigger is the block device:

```udev
ACTION=="add", KERNEL=="sda1", ...        # WRONG
```

But `sda1` is exactly what recovery has to *create*. Chicken and egg: the rule waits
forever for the thing it is supposed to produce. Trigger on the USB bridge instead — and
match `bind` as well as `add`, because a driver-level rebind emits `bind`:

```udev
ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="9210", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="ssd-recover.service"
```

**Bug 3 — systemd start-rate-limiting fights you exactly when it matters.** Default is 5
starts per 10 s. A flapping connector blows straight through that and systemd then
*refuses* to start the recovery unit. Set `StartLimitIntervalSec=0`, and take a
`flock -n` in the script so overlapping triggers step aside instead of fighting over the
device.

## The recovery ladder

[`scripts/ssd-recover.sh`](scripts/ssd-recover.sh), triggered by udev and by a 60 s
backstop timer:

1. Fast path — already mounted and writable, do nothing.
2. Stale mount whose device vanished → stop the one service holding handles, then
   `umount -l`. **Not** `fuser -k -m`, which would take Docker and everything else with it.
3. Up to 4 attempts of: SCSI rescan → `authorized` toggle → `usb-storage` unbind/rebind.
4. Mount, then **verify it did not land read-only** and pass a write smoke test. Only if
   that fails, run `e2fsck -p`; refuse to mount and alert if it returns ≥ 2. Never
   auto-fsck a healthy disk, and never fsck a half-connected one on a hunch.
5. Re-bind the data mount, restart the dependent service.

Measured, hands-off, from a real disconnect:

```
20:07:20  --- trigger=udev ---
20:07:26  authorized toggle on /sys/bus/usb/devices/2-1
20:07:42  sda1 present after 1 attempt(s)
20:07:42  mounted /mnt/ssd rw -> service restarted -> recovery complete
```

22 seconds. During the outage the OS never blinked: root writable, Docker, Home
Assistant, Tailscale, SSH and the probe all stayed up, systemd unmounted the dead disk
cleanly with no zombie mount, and the data service stopped itself rather than running
against an empty directory.

## Two more things worth copying

**A watchdog you did not check is a watchdog you do not have.** The BCM2835 hardware
watchdog caps at 15 s — `cat /sys/class/watchdog/watchdog0/timeout`. Request 10 s and
systemd will report 15 s; request 30 s and you silently get 15 s anyway. Plan around the
real ceiling.

**Every alert your box can raise dies with the box.** Notifications routed through a
service running *on* the machine tell you nothing about a power cut, a dead card, or a
kernel wedge. Add an outbound heartbeat to something external, so silence itself is the
alert. [`cf-heartbeat/`](cf-heartbeat/) is a small Cloudflare Worker that does this —
KV for last-seen, a Cron Trigger to notice the silence, Email Routing to send the mail.

## What software cannot fix

The trigger was almost certainly a physically loose connector, and nothing here repairs
that. What changed is the consequence: a bump used to take down the whole machine
indefinitely, and now costs one service for 22 seconds. Fix the connector too.
