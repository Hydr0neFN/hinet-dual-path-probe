# 在 Raspberry Pi 4 上跟一顆接觸不良的 USB SSD 共存

**繁體中文** · [English](STORAGE-RESILIENCE.en.md)

探針主機只要桌子被碰一下就當機。以下是**真正的原因**，以及在驗證修法的過程中抓到的三個 bug ——
其中兩個會讓機器直接死掉而且遠端救不回來。

硬體：RPi 4、DietPi on Debian 13、USB SSD 後面是 **Realtek RTL9210B-CG**（`0bda:9210`），
root 檔案系統就放在那顆 SSD 上。

## 四個問題，只有第一個是明顯的

**1. root 放在可插拔的磁碟上。** USB 接頭瞬間接觸不良，代價應該是掉一個掛載點，不應該是掉整個
kernel。root 在 SSD 上時，每一次閃斷都是致命的。

**2. `uas` 驅動綁在橋接器上。** `/sys/bus/usb/drivers/uas/2-1:1.0`，而且沒有設定任何 quirk。
RPi 4 + RTL9210 + UAS 是一組出了名會 stall 的組合。

**3. USB3 link power management 每次開機都協商失敗：**

```
usb 2-1: enable of device-initiated U1 failed
```

LPM 協商失敗是偽掉線的經典來源，而且很容易被忽略 —— 因為裝置**還是能用**。

**4. 沒有任何證據，而且這是結構性的問題。** persistent journal 是從**位於 SSD 上**的目錄
bind mount 過來的，而 `/var/log` 是 50 MB 的 tmpfs（DietPi ramlog）。所以磁碟一掉，記錄「磁碟掉了」
的那份 log 也跟著死。`journalctl --list-boots` 只看得到一次開機。數個月的當機，**零筆鑑識資料**。

> 如果你在追一個間歇性的儲存問題，**第一件事是確認你的 log 放在哪裡**。在那件事修好之前，
> 其他所有動作都只是在猜。

## 修法

**把角色對調。** root 放 SD 卡；SSD 降級成 `nofail` 的資料掛載點。

```
# /etc/fstab
PARTUUID=<ssd>  /mnt/ssd  ext4  nofail,noatime,x-systemd.device-timeout=10,x-systemd.mount-timeout=20  0 0
/mnt/ssd/var/lib/<app>  /var/lib/<app>  none  bind,nofail,x-systemd.requires=/mnt/ssd  0 0
```

再加上對應服務的 `RequiresMountsFor=`，這樣它就不可能在掛載點是空的情況下啟動，然後默默把自己的
狀態寫壞。

**硬化橋接器**，寫在 kernel command line：

```
usb-storage.quirks=0bda:9210:u    # IGNORE_UAS -> 強制走 bulk-only transport
usbcore.quirks=0bda:9210:k        # NO_LPM -> 關掉一直協商失敗的 U1/U2
usbcore.autosuspend=-1
```

並且透過 udev 給 SCSI 層足夠的重試空間，而不是直接放棄：

```
ACTION=="add|change", KERNEL=="sd[a-z]", SUBSYSTEMS=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="9210", \
  RUN+="/bin/sh -c 'echo 180 > /sys/block/%k/device/timeout; echo 60 > /sys/block/%k/device/eh_timeout'"
```

確認生效的訊息：

```
usb 2-1: UAS is ignored for this device, using usb-storage instead
usb-storage 2-1:1.0: Quirks match for vid 0bda pid 9210: 800000
```

而且 `U1 failed` 那行不再出現。代價：沒有 command queuing 之後，循序讀取掉到約 153 MB/s。
對純資料碟來說這個交換很划算，而且仍然是 SD 卡的好幾倍。

> **順序很重要。** USB quirks 一定要等 root 已經搬離 SSD 之後才套用。萬一 bulk-only transport
> 剛好搞垮你那顆橋接器，而 root 還在上面，機器就開不起來了 —— 而你可能不在現場。

## 三個「真的動手測才會發現」的 bug

這些在你真的把碟拔掉之前都不會出現。在 bus 層模擬：

```
echo 2-1 > /sys/bus/usb/drivers/usb/unbind    # 拔
echo 2-1 > /sys/bus/usb/drivers/usb/bind      # 插回去
```

**Bug 1 — 橋接器自己回不來。** rebind 之後它會重新列舉（`lsusb` 看得到、`usb-storage` 有掛上、
SCSI host 有建立），然後**永遠不會出現 block device**。它會卡在：

```
usb 2-1: reset SuperSpeed USB device number 2 using xhci_hcd
```

SCSI host rescan（`echo "- - -" > /sys/class/scsi_host/host0/scan`）**沒有用**。真正有效、
而且每次第一發就成功的是：

```
echo 0 > /sys/bus/usb/devices/2-1/authorized
sleep 4
echo 1 > /sys/bus/usb/devices/2-1/authorized
```

取消授權會強迫它做一次**真正的重新列舉**，而不是卡在半初始化的 reset 迴圈裡。
這是這份文件裡最有用的一件事。

**Bug 2 — udev 規則永遠不可能觸發。** 最直覺的觸發條件是 block device：

```udev
ACTION=="add", KERNEL=="sda1", ...        # 錯的
```

但 `sda1` 正是復原程序**要製造出來的東西**。雞生蛋蛋生雞：規則永遠在等它自己該產生的東西。
要改綁在 USB 橋接器上 —— 而且除了 `add` 還要匹配 `bind`，因為 driver 層的 rebind 發的是 `bind`：

```udev
ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="9210", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="ssd-recover.service"
```

**Bug 3 — systemd 的啟動速率限制，偏偏在最需要的時候扯後腿。** 預設是 10 秒內 5 次。接觸不良
造成的抖動會直接衝破這個上限，然後 systemd **拒絕**再啟動復原 unit。要設
`StartLimitIntervalSec=0`，並且在腳本裡拿 `flock -n`，讓重疊觸發的那幾個自己讓路，而不是一起
搶同一顆裝置。

## 復原階梯

[`scripts/ssd-recover.sh`](scripts/ssd-recover.sh)，由 udev 與 60 秒的 backstop timer 觸發：

1. 快速路徑 —— 已經掛好而且可寫，什麼都不做。
2. 裝置已消失但掛載還在 → 先停掉唯一持有 handle 的那個服務，再 `umount -l`。
   **不要**用 `fuser -k -m`，那會把 Docker 和其他所有東西一起殺掉。
3. 最多 4 輪：SCSI rescan → `authorized` toggle → `usb-storage` unbind/rebind。
4. 掛載，然後**確認沒有掛成唯讀**並通過寫入實測。只有在這一步失敗時才跑 `e2fsck -p`；
   回傳值 ≥ 2 就拒絕掛載並發出警報。**絕不對健康的碟自動 fsck，也絕不對半連接的碟憑感覺 fsck。**
5. 重新 bind 資料掛載點，重啟相依的服務。

實際從一次真實斷線量到的結果，全程無人介入：

```
20:07:20  --- trigger=udev ---
20:07:26  authorized toggle on /sys/bus/usb/devices/2-1
20:07:42  sda1 present after 1 attempt(s)
20:07:42  mounted /mnt/ssd rw -> service restarted -> recovery complete
```

22 秒。而在整個斷線期間，OS 連眨都沒眨一下：root 可寫，Docker、Home Assistant、Tailscale、SSH
與探針全部存活，systemd 乾淨地卸載了那顆死掉的碟、沒有殘留殭屍掛載，資料服務也自己停了下來，
而不是對著一個空目錄繼續跑。

## 另外兩件值得抄走的事

**沒驗證過的 watchdog 等於沒有 watchdog。** BCM2835 硬體 watchdog 上限是 15 秒 ——
`cat /sys/class/watchdog/watchdog0/timeout`。你要求 10 秒，systemd 會回報 15 秒；你要求 30 秒，
它默默還是給你 15 秒。請照真實的上限規劃。

**任何由機器自己發出的警報，都會跟著機器一起死。** 透過跑在**那台機器上**的服務送出的通知，
對於斷電、卡片掛掉、kernel 卡死這些狀況什麼也告訴不了你。要加一個對外的 heartbeat，讓**沉默本身**
成為警報。[`cf-heartbeat/`](cf-heartbeat/) 就是做這件事的一個小 Cloudflare Worker：KV 記錄
last-seen、Cron Trigger 負責察覺沉默、Email Routing 負責寄信。

## 軟體修不了的部分

觸發原因幾乎可以確定是接頭實體鬆動，這裡沒有任何東西能修好它。改變的是**後果**：以前碰一下就
無限期地整台掛掉，現在的代價是一個服務停 22 秒。**接頭還是要去修。**
