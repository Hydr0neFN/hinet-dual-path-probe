# Unit files, udev rules and the PPPoE hooks

**English** · [繁體中文](README.md)

The real files from the machine that produced the data, flattened into one directory
because their install paths differ. Copy each to the path in the table, then
`systemctl daemon-reload`.

| File here | Install to |
|---|---|
| `netmeasure.service` | `/etc/systemd/system/` — runs `probe.sh` |
| `netmeasure-ppp.service` | `/etc/systemd/system/` — holds the second PPPoE session up across reboots |
| `probe-publish.{service,timer}` | `/etc/systemd/system/` — hourly regenerate + push |
| `heartbeat.{service,timer}` | `/etc/systemd/system/` — outbound dead-man ping |
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
- USB disk recovery, the RTL9210 quirks, `root-backup.sh` and their units and udev
  rules now live in **[rpi4-usb-ssd-resilience](https://github.com/Hydr0neFN/rpi4-usb-ssd-resilience)**.

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
