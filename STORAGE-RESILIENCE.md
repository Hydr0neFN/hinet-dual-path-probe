# 在 Raspberry Pi 4 上跟一顆接觸不良的 USB SSD 共存

**繁體中文** · [English](STORAGE-RESILIENCE.en.md)

探針主機只要桌子被晃一下就直接當機。以下是問題的**真正原因**，以及在驗證解法的過程中抓到的三個 bug（其中兩個會讓機器直接死透，而且遠端完全救不回來）。

硬體配備：RPi 4、DietPi on Debian 13，外接 USB SSD 晶片是 **Realtek RTL9210B-CG**（`0bda:9210`），系統 root 檔案系統就裝在那顆 SSD 上。

## 四個問題，只有第一個是明顯的

**1. 把 root 放在可插拔的磁碟上。** USB 接頭瞬間接觸不良，代價應該只是掉一個掛載點，不應該直接搞死整個 kernel。但只要 root 放在 SSD 上，每一次閃斷都是致命的。

**2. 外接盒直接吃了 `uas` 驅動。** 路徑在 `/sys/bus/usb/drivers/uas/2-1:1.0`，而且完全沒有設定任何 quirk。RPi 4 + RTL9210 + UAS 是一組出了名容易卡死（stall）的組合。

**3. USB3 link power management 每次開機都協商失敗：**

```
usb 2-1: enable of device-initiated U1 failed
```

LPM 協商失敗是造成假性離線的經典元凶，而且平常極容易被忽略——因為裝置**看起來還是能用**。

**4. 系統完全沒留下證據，而且這是結構性的問題。** persistent journal 是從 **SSD 上**的目錄 bind mount 過來的，而 `/var/log` 又是只有 50 MB 的 tmpfs（DietPi ramlog）。所以磁碟一斷線，記錄「磁碟斷線」的那份 log 也跟著蒸發。`journalctl --list-boots` 永遠只看得到最後一次開機。當機當了好幾個月，**半筆鑑識資料都沒留下來**。

> 如果你正在追一個偶發性的儲存問題，**第一步務必先確認你的 log 到底寫在哪裡**。在把 log 存放位置搞定之前，其他所有動作都只是在瞎猜。

## 修法

**把角色對調。** root 改回放 SD 卡；SSD 降級成帶有 `nofail` 參數的資料掛載點。

```
# /etc/fstab
PARTUUID=<ssd>  /mnt/ssd  ext4  nofail,noatime,x-systemd.device-timeout=10,x-systemd.mount-timeout=20  0 0
/mnt/ssd/var/lib/<app>  /var/lib/<app>  none  bind,nofail,x-systemd.requires=/mnt/ssd  0 0
```

再加上對應服務的 `RequiresMountsFor=`，這樣它就不可能在掛載點是空的狀態下啟動，然後默默把自己的狀態寫壞。

**設定外接盒 quirks 強化穩定度**，直接寫在 kernel command line：

```
usb-storage.quirks=0bda:9210:u    # IGNORE_UAS -> 強制走 bulk-only transport
usbcore.quirks=0bda:9210:k        # NO_LPM -> 關掉一直協商失敗的 U1/U2
usbcore.autosuspend=-1
```

並且透過 udev 給 SCSI 層足夠的重試空間，避免稍微卡住就直接放棄：

```
ACTION=="add|change", KERNEL=="sd[a-z]", SUBSYSTEMS=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="9210", \
  RUN+="/bin/sh -c 'echo 180 > /sys/block/%k/device/timeout; echo 60 > /sys/block/%k/device/eh_timeout'"
```

重開後確認生效的訊息：

```
usb 2-1: UAS is ignored for this device, using usb-storage instead
usb-storage 2-1:1.0: Quirks match for vid 0bda pid 9210: 800000
```

此時 `U1 failed` 那行錯誤也不再出現了。唯一代價：關閉 command queuing 之後，循序讀取掉到約 153 MB/s。對純資料碟來說這個交換非常划算，而且讀寫依然是 SD 卡的好幾倍。

> **操作順序很重要。** USB quirks 一定要等 root 已經完全搬離 SSD 之後才能套用。萬一 bulk-only transport 剛好搞垮你那顆外接盒，而 root 還在上面，機器就會直接開不起來——而你人可能不在現場。

## 三個「真的動手測才會發現」的 bug

這些問題在你真的手動把硬碟拔掉之前都不會現形。我們可以直接在 bus 層模擬斷線與重連：

```
echo 2-1 > /sys/bus/usb/drivers/usb/unbind    # 拔
echo 2-1 > /sys/bus/usb/drivers/usb/bind      # 插回去
```

**Bug 1——晶片重新插拔後自己醒不過來。** rebind 之後系統雖然看得到它（`lsusb` 有抓到、`usb-storage` 有掛上、SCSI host 有建立），但 `/dev` 底下**永遠長不出 block device**。dmesg 會一直卡在：

```
usb 2-1: reset SuperSpeed USB device number 2 using xhci_hcd
```

手動對 SCSI host 做 rescan（`echo "- - -" > /sys/class/scsi_host/host0/scan`）**完全沒有用**。真正有效、而且每次試都能一發成功救回來的是：

```
echo 0 > /sys/bus/usb/devices/2-1/authorized
sleep 4
echo 1 > /sys/bus/usb/devices/2-1/authorized
```

取消授權會強迫系統做一次**真正的重新列舉**，徹底跳出卡在半初始化的 reset 迴圈。這是這份文件裡含金量最高的一招。

**Bug 2——udev 規則永遠等不到觸發。** 直覺上最容易想到的觸發條件是 block device：

```udev
ACTION=="add", KERNEL=="sda1", ...        # 錯的
```

但 `sda1` 正是復原腳本**要想辦法生出來的目標**。這就陷入了雞生蛋蛋生雞的死胡同：規則永遠在等它自己該產生的東西。所以觸發條件必須改綁在 USB 橋接器上——而且除了 `add` 之外還要匹配 `bind`，因為 driver 層做 rebind 時發出的事件是 `bind`：

```udev
ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="9210", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="ssd-recover.service"
```

**Bug 3——systemd 的啟動速率限制，偏偏在最需要的時候扯後腿。** 預設是 10 秒內最多 5 次。接觸不良產生的連續抖動會在一瞬間衝破這個上限，導致 systemd 直接**罷工拒絕**再次啟動復原 unit。解法是設定 `StartLimitIntervalSec=0` 拔掉上限，並且在腳本內拿 `flock -n` 鎖定，讓重疊觸發的行程自動讓路退出，而不是一起搶著處理同一顆裝置。

## 復原階梯

完整的復原邏輯寫在 [`scripts/ssd-recover.sh`](scripts/ssd-recover.sh)，由 udev 觸發，並掛一個 60 秒的 backstop timer 當兜底保護：

1. 快速路徑——如果硬碟本來就正常掛載且可寫入，直接退出什麼都不做。
2. 裝置已消失但掛載點還卡著 → 先停掉唯一持有 handle 的那個服務，再執行 `umount -l`。
   **千萬不要**手癢打 `fuser -k -m`，那會把 Docker 和其他所有服務無差別一起殺光。
3. 最多重試 4 輪：SCSI rescan → `authorized` toggle → `usb-storage` unbind/rebind。
4. 重新掛載，然後**實測寫入確認沒有被掛成唯讀**。只有在這一步失敗時才去跑 `e2fsck -p`；
   回傳值 ≥ 2 就直接放棄掛載並發出警報。**絕對不對正常的硬碟隨便自動 fsck，也絕不在半連線狀態下憑感覺盲目 fsck。**
5. 重新建立資料目錄的 bind mount，重啟相依的服務。

實際從一次真實斷線量到的結果，全程無人介入：

```
20:07:20  --- trigger=udev ---
20:07:26  authorized toggle on /sys/bus/usb/devices/2-1
20:07:42  sda1 present after 1 attempt(s)
20:07:42  mounted /mnt/ssd rw -> service restarted -> recovery complete
```

總共只要 22 秒。而且在整個斷線期間，主系統穩如泰山：SD 卡上的 root 始終可寫，Docker、Home Assistant、Tailscale、SSH 與探針全部活得好好的；systemd 乾淨俐落地卸載了那顆死掉的硬碟、沒有殘留殭屍掛載，資料服務也自己停了下來，而不是對著一個空目錄繼續亂寫。

## 另外兩件值得抄走的事

**沒實測驗證過的 watchdog 等於沒有 watchdog。** BCM2835 硬體 watchdog 上限是 15 秒（可以用 `cat /sys/class/watchdog/watchdog0/timeout` 驗證）。你要求 10 秒，systemd 會回報 15 秒；你要求 30 秒，硬體底層默默還是只給你 15 秒。請務必照真實的硬體上限規劃。

**任何由機器自己發出的警報，都會跟著機器一起陪葬。** 只要通知是透過跑在**那台機器本機**上的服務送出，遇到斷電、記憶卡掛掉、kernel 卡死這些狀況，你絕對收不到任何通知。必須在外部加一個 heartbeat，讓「**機器沒聲音**」這件事本身直接成為警報。[`cf-heartbeat/`](cf-heartbeat/) 就是做這件事的一個輕量 Cloudflare Worker：用 KV 記錄 last-seen、Cron Trigger 負責察覺沉默、Email Routing 負責發信。

## 軟體修不了的部分

觸發原因幾乎可以確定是接頭實體鬆動，這裡寫的任何軟體邏輯都修不好它。改變的是**故障帶來的後果**：以前碰一下就無限期整台死當，現在的代價只是一個服務暫停 22 秒。**不過實體接觸不良的接頭，有空還是要去修好。**
