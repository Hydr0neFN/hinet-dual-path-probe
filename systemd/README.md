# Unit files, udev rules and the PPPoE hooks

The real files from the machine that produced the data, flattened into one directory
because their install paths differ. Copy each to the path in the table, then
`systemctl daemon-reload`.

| File here | Install to |
|---|---|
| `netmeasure.service` | `/etc/systemd/system/` — runs `probe.sh` |
| `netmeasure-ppp.service` | `/etc/systemd/system/` — holds the second PPPoE session up across reboots |
| `probe-publish.{service,timer}` | `/etc/systemd/system/` — hourly regenerate + push |
| `heartbeat.{service,timer}` | `/etc/systemd/system/` — outbound dead-man ping |
| `ssd-recover.{service,timer}` | `/etc/systemd/system/` — USB disk recovery + 60 s backstop |
| `systemd-system.conf.d-10-watchdog.conf` | `/etc/systemd/system.conf.d/10-watchdog.conf` |
| `98-rtl9210-recover.rules` | `/etc/udev/rules.d/` — fire recovery when the bridge enumerates |
| `99-rtl9210-timeout.rules` | `/etc/udev/rules.d/` — long SCSI timeouts for the bridge |
| `ppp-peers-measure.example` | `/etc/ppp/peers/<name>` — **edit the `user` line first** |
| `ppp-ip-up.d-50measure` | `/etc/ppp/ip-up.d/50measure` (must be executable) |
| `ppp-ip-down.d-50measure` | `/etc/ppp/ip-down.d/50measure` (must be executable) |

## Before you enable any of it

- **The PPPoE password is not here and must not be.** Put the credential in
  `/etc/ppp/pap-secrets` (mode 600) yourself. Nothing in this repo reads or writes it.
- **`nodefaultroute` is load-bearing.** Without it the measurement session takes over the
  default route and your whole household starts using it.
- **Check the interface names.** `nic-eth0` in the peers file, and `eth0` / `ppp0` in
  `probe.sh`, are specific to this box.
- **The udev rules hard-code `0bda:9210`** (Realtek RTL9210). Change the IDs for your
  bridge, or drop the rules if your disk is not USB.
- `ssd-recover.sh` and `root-backup.sh` call `/usr/local/sbin/ha-alert.sh` (Home
  Assistant notification) and `/usr/local/sbin/io-health.sh` (SMART/dmesg check). Those
  are host-specific and not included. `ha-alert.sh` is guarded by `[ -x ]` and simply
  does nothing if absent; **`io-health.sh` is not** — either supply one or delete that
  line from `root-backup.sh` before using it.
- `root-backup.sh` assumes the layout described in
  [`../STORAGE-RESILIENCE.md`](../STORAGE-RESILIENCE.md): root on the SD card, the USB
  disk mounted `nofail` at `/mnt/ssd`. It refuses to run otherwise, but read it before
  trusting it with your filesystem — it uses `rsync --delete` against a destination that
  also holds live data.

## Sanity check after installing

```sh
systemctl status netmeasure netmeasure-ppp
ip rule show | grep 200          # the policy rule
ip route show table 200          # must show a default route, or nothing is measured
tail -3 /root/netmeasure/paired.csv
```

Two rows per timestamp, with two different source addresses, means it is working. Two
rows with the *same* source address means the policy route is not in effect and you are
measuring one path twice.
