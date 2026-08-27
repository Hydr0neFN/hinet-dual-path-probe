# unit 檔、udev 規則與 PPPoE hook

**繁體中文** · [English](README.en.md)

這些是從產出這份數據的那台機器上直接取下來的**實際檔案**。因為它們的安裝路徑各不相同，這裡把它們
攤平放在同一個目錄。請依下表複製到對應位置，然後執行 `systemctl daemon-reload`。

| 這裡的檔名 | 安裝到 |
|---|---|
| `netmeasure.service` | `/etc/systemd/system/` —— 執行 `probe.sh` |
| `netmeasure-ppp.service` | `/etc/systemd/system/` —— 讓第二條 PPPoE session 跨重開機存活 |
| `probe-publish.{service,timer}` | `/etc/systemd/system/` —— 每小時重新產生並推送 |
| `heartbeat.{service,timer}` | `/etc/systemd/system/` —— 對外的 dead-man 心跳 |
| `ssd-recover.{service,timer}` | `/etc/systemd/system/` —— USB 磁碟復原與 60 秒 backstop |
| `systemd-system.conf.d-10-watchdog.conf` | `/etc/systemd/system.conf.d/10-watchdog.conf` |
| `98-rtl9210-recover.rules` | `/etc/udev/rules.d/` —— 橋接器一列舉就觸發復原 |
| `99-rtl9210-timeout.rules` | `/etc/udev/rules.d/` —— 給這顆橋接器較長的 SCSI timeout |
| `ppp-peers-measure.example` | `/etc/ppp/peers/<name>` —— **先改 `user` 那一行** |
| `ppp-ip-up.d-50measure` | `/etc/ppp/ip-up.d/50measure`（要可執行） |
| `ppp-ip-down.d-50measure` | `/etc/ppp/ip-down.d/50measure`（要可執行） |

## 啟用之前務必確認

- **PPPoE 密碼不在這裡，也不該在這裡。** 請自己把帳密寫進 `/etc/ppp/pap-secrets`（mode 600）。
  這個 repo 裡沒有任何東西會讀取或寫入它。
- **`nodefaultroute` 是關鍵。** 少了它，量測用的 session 會接管預設路由，整個家裡的流量都會改走它。
- **檢查介面名稱。** peers 檔裡的 `nic-eth0`，以及 `probe.sh` 裡的 `eth0` / `ppp0`，都是這台機器
  專屬的。
- **udev 規則寫死了 `0bda:9210`**（Realtek RTL9210）。請改成你自己橋接器的 ID，或者如果你的碟不是
  USB 就直接刪掉這兩條規則。
- `ssd-recover.sh` 與 `root-backup.sh` 會呼叫 `/usr/local/sbin/ha-alert.sh`（Home Assistant 通知）
  與 `/usr/local/sbin/io-health.sh`（SMART / dmesg 檢查）。這兩支是主機專屬的，**沒有包含在這裡**。
  `ha-alert.sh` 有 `[ -x ]` 保護，不存在就自動跳過；**`io-health.sh` 沒有** —— 你得自己補一支，
  或是在使用 `root-backup.sh` 之前把那一行刪掉。
- `root-backup.sh` 假設的佈局寫在 [`../STORAGE-RESILIENCE.md`](../STORAGE-RESILIENCE.md)：root 在
  SD 卡、USB 碟以 `nofail` 掛在 `/mnt/ssd`。不符合就會拒絕執行，但**在把檔案系統交給它之前請先讀過**
  —— 它用的是 `rsync --delete`，而目的地上同時放著活資料。

## 安裝後的檢查

```sh
systemctl status netmeasure netmeasure-ppp
ip rule show | grep 200          # policy 規則
ip route show table 200          # 一定要看到 default route，否則根本沒在量第二條路徑
tail -3 /root/netmeasure/paired.csv
```

**同一個時間戳有兩列、而且來源位址不同** → 正常運作。
**兩列的來源位址相同** → policy route 沒生效，你正在把同一條路徑量兩次。
