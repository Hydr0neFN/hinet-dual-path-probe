# unit 檔、udev 規則與 PPPoE hook

**繁體中文** · [English](README.en.md)

這裡收錄的是直接從跑這些量測的那台機器上抓下來的**實際配置檔案**。因為每個檔案在 Linux 系統中的安裝路徑各不相同，在此統一攤平放在同一個目錄。請參考下表將檔案複製到對應位置，並執行 `systemctl daemon-reload`。

| 這裡的檔名 | 安裝到 |
|---|---|
| `netmeasure.service` | `/etc/systemd/system/`——執行 `probe.sh` |
| `netmeasure-ppp.service` | `/etc/systemd/system/`——讓第二條 PPPoE session 跨重開機存活 |
| `probe-publish.{service,timer}` | `/etc/systemd/system/`——每小時重新產生並推送 |
| `heartbeat.{service,timer}` | `/etc/systemd/system/`——對外的 dead-man 心跳 |
| `ppp-peers-measure.example` | `/etc/ppp/peers/<name>`——**先改 `user` 那一行** |
| `ppp-ip-up.d-50measure` | `/etc/ppp/ip-up.d/50measure`（要可執行） |
| `ppp-ip-down.d-50measure` | `/etc/ppp/ip-down.d/50measure`（要可執行） |

## 啟用之前務必確認

- **PPPoE 密碼不在這裡，也絕對不該放進來。** 請自己把帳密填進 `/etc/ppp/pap-secrets`（mode 600）。這個 repo 裡沒有任何東西會讀取或寫入它。
- **`nodefaultroute` 是關鍵。** 少了它，量測用的 session 會搶下預設路由，整個家裡的流量都會改走它。
- **檢查介面名稱。** peers 檔裡的 `nic-eth0`，以及 `probe.sh` 裡的 `eth0` / `ppp0`，都是這台機器專屬的。
- USB 碟復原、RTL9210 quirks、`root-backup.sh` 與對應的 unit／udev 規則，已獨立整理至專案 **[rpi4-usb-ssd-resilience](https://github.com/Hydr0neFN/rpi4-usb-ssd-resilience)**。

## 安裝後的檢查

```sh
systemctl status netmeasure netmeasure-ppp
ip rule show | grep 200          # policy 規則
ip route show table 200          # 一定要看到 default route，否則根本沒在量第二條路徑
tail -3 /root/netmeasure/paired.csv
```

**同一個時間戳有兩列、而且來源位址不同** → 正常運作。
**兩列的來源位址相同** → policy route 沒生效，你正在把同一條路徑量兩次。
