# 固定 IP 真的能讓遊戲 ping 變低嗎？

**繁體中文** · [English](README.en.md)

在同一條實體線路上，直接用一台 Raspberry Pi 對兩種 ISP 連線型態做**同步 A/B 測試**（而且量的是 **Source 2 遊戲實際走的 UDP 路徑**，不是隨便 ping 個附近的 DNS 敷衍了事）。

先說結論（給不想看長文的人）：**對遊戲路徑來說：完全沒有。但對 Cloudflare 背後的服務來說：差非常多。**
底下的數據由跑在 Pi 上的探針每小時自動更新。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="data/chart-dark.svg">
  <img alt="兩條 ISP 路徑同時量測的延遲與封包遺失時序圖" src="data/chart-light.svg">
</picture>

完整數字（隨時更新）：**[data/stats.md](data/stats.md)** · 原始樣本：
[data/paired-scrubbed.csv](data/paired-scrubbed.csv)

### 每天的變化

上面那張圖只畫最近 48 小時，所以安靜的一天看起來跟前一天一模一樣。下面這張是**每日彙整**，
一天一個點，探針跑多久就長多長：

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="data/history-dark.svg">
  <img alt="兩條 ISP 路徑逐日彙整的遊戲路徑 p95 與 Cloudflare 中位數" src="data/history-light.svg">
</picture>

逐日數字：**[data/history.csv](data/history.csv)**（一天一列，可以直接看 commit diff）。
最後一天還在累積中，數值會隨當天樣本變動。

---

## 為什麼做這件事

明明線路完全沒其他人用，打 CS2 ping 卻會無預警飆到 200 ms。把常見的可能原因（server picker、DNS、Wi-Fi）全排查過一輪，發現都不是。最後用 traceroute 抓到 ICMP `type 11 time-exceeded`，才抓出是 HiNet（AS3462）跟 Cloudflare（AS13335）之間的 routing loop：流量根本沒在台灣本地互連，反而繞去國外轉了一圈。

剛好 HiNet 的非固定制可以線上申請配發一組固定 IP，撥號帳號後綴改成 `@ip.hinet.net` 就生效，本身不用另外加錢（這跟企業用的固定制專線是兩回事）。問題就來了：**改用固定 IP 之後，路由真的會變好嗎？**

這問題要認真驗證其實出乎意料地難。網路上大部分的心得文，基本上都是拿今天測出來的數字，去跟自己上週憑感覺的印象做比較。

## 這份量測跟一般做法差在哪

**直覺想到的 A/B 測試有兩個致命盲點，以下是我的解法：**

### 問題一：先後測量根本沒有意義

換個連線模式、重測一次、比對前後數據（這量到的其實是**你在什麼時間點測**，而不是**你到底改了什麼**）。ISP 偶發的線路異常本來就會自己恢復，大家卻很容易把改善的功勞歸給自己最後動的那項設定。

這個實驗一開始我也是這樣搞，當下還信心滿滿地下了結論。**結果那個結論根本是錯的**，隔天數據直接狠狠打臉。

解法：**讓同一台主機同時拿到兩種連線**。第一條走 router 原本的對外連線；第二條由 Pi 自己透過 PPPoE 撥號建立第二個 session，並加上 `nodefaultroute`，確保它絕對不會變成系統的預設 gateway，只能透過 policy routing 規則轉發。每一輪測試**同時**對兩條路徑發包，這樣一來，外在網路的任何突發干擾都會同時影響兩邊，在對照比較時就能直接抵銷掉。

> **勘誤，順便提醒想照抄這套架構的人：** `probe.sh` 最初的版本其實是**一前一後**測量兩條路徑（分別跑了 8.6 秒與 10.4 秒），結果兩筆資料都直接蓋上迴圈剛開始的時間戳。這讓 CSV **看起來**像是同時採樣，實際上卻差了約 9 秒。在 `2026-08-27 21:02` 之前的數據都有這個時間差。雖然 9 秒的誤差遠遠不足以解釋 Cloudflare 的現象（動輒持續數小時、高達 20 倍的延遲差距），但硬說這是嚴格同步確實算誇大了說法——在 log 裡偷懶共用 timestamp，真的很常自己騙自己。

```sh
# /etc/ppp/peers/<name>
nodefaultroute          # 量測用的 session 絕對不能變成系統預設路由

# /etc/ppp/ip-up.d/50measure   （$1=介面 $4=本地 IP $6=ipparam）
[ "$6" = "measure" ] || exit 0
ip route replace default dev "$1" table 200      # <- 少了這行，上面那條規則什麼也不會做
ip rule del priority 200 2>/dev/null
ip rule add from "$4" lookup 200 priority 200
```

**兩邊缺一不可**：`ip rule` 負責把「來源 IP 是第二個 session」的封包導進 table 200，而 `ip route` 才是告訴 table 200 封包要往哪個介面丟。如果只有 rule 卻沒設 route，Linux 查表找不到路就會 fallback 回 main table，結果就是**不知不覺中把同一條路徑連續測了兩次**——這就是我第一次嘗試失敗、整批數據直接報廢的原因。

這台 Pi **不是** router，平常也不跑家裡的日常流量。它單純只是多掛一個 PPPoE session，讓我們能在同一個基準點公平對照兩條路徑。

### 問題二：ping 1.1.1.1 量到的不是你遊戲在走的路

跑在 Valve **Steam Datagram Relay（SDR）** 架構上的遊戲，傳輸走的是**往 relay 發送的 UDP 封包**，而不是往 DNS resolver 送的 ICMP。這兩者在骨幹網路上走的實體路徑很可能完全不同（router 算 ECMP 是針對 5-tuple 做 hash，連兩條不同的 UDP flow 都可能分流走不同線路）。ping Cloudflare 頂多只能反映連到 Cloudflare 的品質，對遊戲連線狀況沒有任何代表性。

**實用小技巧：SDR relay 其實會回應隨便打進遊戲 port 的 UDP 垃圾封包。** 只要對 relay 的 `27015–27060` 送 32 bytes 隨機 payload，它就會回傳：

```
Invalid/unknown MsgID 0
```

這樣就完成了一次完整的 round trip，而且走的是**遊戲實際採用的傳輸通道**。只要開個一般的 socket 就能發送，完全不需要打開遊戲，也不用引進任何 client library。[`scripts/sdrping.py`](scripts/sdrping.py) 就是用這個原理寫的，會輸出 `avg_rtt,loss`。

**重要限制：RTT 數據可靠，但 packet loss 不具參考價值。** SDR relay 會靜默丟棄部分無效封包——不管我把發送間隔設成 0.12 秒、0.35 秒還是 0.8 秒，都有 16–33% 的封包收不到回應，但同時間 RTT 卻始終穩穩落在 33.2–33.5 ms。值得注意的是，三種間隔的未回應比例差不多，所以這比較像是 relay 本來就不保證回應垃圾封包，而不是單純的 rate limiting。**因此這個工具只能用來測延遲（RTT），絕對不能拿來當作封包遺失率的指標。**

relay 清單可以直接從 Valve 官方的 endpoint 抓取：

```
https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=730
```

## 數據說了什麼

即時數字見 [data/stats.md](data/stats.md)。統計出來的結果如下：

| | 固定制（Static IP） | 浮動制（Dynamic IP） |
|---|---|---|
| **遊戲路徑**（Tokyo SDR relay, UDP） | 中位數 ~34 ms | 中位數 ~34 ms — **配對差值 ≈ 0 ms** |
| 遊戲路徑 p95 | 穩定走平，幾乎貼齊中位數 | 在 38–52 ms 之間浮動 |
| **Cloudflare 1.1.1.1** | 3 ms，極度穩定 | 平常 24 ms，**傍晚尖峰滿載時飆破 200 ms 且伴隨封包遺失** |

結論：

- **固定制不會讓遊戲 ping 變低。** 在實際的遊戲 transport 上，兩者的中位數差距就是 0。坊間那些「換固定 IP ping 會變低」的說法，顯然量到的都不是遊戲走的路徑。
- **但它確實大幅消除了延遲抖動（jitter）。** 固定制的 p95 延遲可以連續好幾個小時直接貼齊中位數，浮動制就做不到這點。對射擊遊戲來說，ping 穩不穩定，比帳面上的平均值好不好看更有感。
- **Cloudflare 繞路問題只發生在浮動 IP。** 不論背後的 routing 故障到底是什麼原因，中華電信對這兩個 IP pool 的路由政策顯然不同，只有浮動制會被繞去國外。

### 這份數據**不能**證明什麼

- relay 到遊戲伺服器這一段是量不到的。在遊戲內看到的約 82 ms 當中，探針只能監控到前半段往 relay 的約 33 ms。如果哪天玩起來很卡但探針數據完全正常，問題就出在後半段。
- 這是單一線路、單一 ISP、單一城市的測試結果。這代表的是一套**大家可以自己拿去跑的測試方法**，不能直接當作固定 IP 的通則結論。
- 撰寫當下只累積了兩個晚上的尖峰數據，其中一晚還因為無關的硬體故障整段遺失（詳見後述）。Cloudflare 的對比結果非常明確；至於抖動改善的部分，建議先當作**趨勢性**的參考。


## 為什麼 Valorant 不受這個問題影響

在同一條網路線上、同一個時段，CS2 ping 飆高的時候 Valorant 往往完全正常。這不是玄學，純粹是兩家公司把流量送上網際網路的架構完全不同。

| | CS2（Valve SDR） | Valorant（Riot） |
|---|---|---|
| 傳輸網路 | Steam Datagram Relay，走公開網際網路的 transit 到 relay | **Riot Direct**（AS6507），Riot 自建的私有骨幹 |
| 在台灣的接入 | 依 relay 選擇與當下的 BGP 路由而定 | 在 **TPIX（台北網際網路交換中心）** 有 PoP 並與本地 ISP 直接對接 |
| 遊戲流量會經過 Cloudflare 嗎 | 可能（這正是本專案抓到的故障） | **不會**。Cloudflare 只可能出現在網站、登入等應用層 |
| 伺服器位置 | 依 relay 而定（本專案量東京） | 香港 / 東京 / 新加坡，經 Riot 自己的骨幹回傳 |

關鍵在於：**HiNet 跟 Cloudflare 之間缺乏良好的本地互連**，導致流量被繞到國外；但 **Riot 在台灣 TPIX 有直接落地**，封包一離開 HiNet 就直接交給 Riot Direct，之後全程走 Riot 自己的骨幹出去。（這一段是架構上的推論，本次探針並沒有量 Valorant。）CS2 會踩到那個 routing loop，Valorant 根本連碰都不會碰到。

> **先說清楚界線**：本專案的探針**沒有實際量測 Valorant**。上面這段只是從架構分析「為什麼這個故障機制在理論上碰不到 Valorant」，並不是實測數據。

順帶提個插曲：在調查過程中，Valorant 確實也出現過一次明顯的爆 ping——結果抓出來的原因是 **Steam 在背景下載遊戲把上行頻寬塞爆**，跟 ISP 路由半點關係都沒有。把下載暫停之後就秒恢復。**同樣是遊戲卡頓，背後的原因可能完全不同；先拿出數據測量，不要急著下定論。**

## 檔案結構

| 路徑 | 內容 |
|---|---|
| `scripts/probe.sh` | 採樣主迴圈：兩條路徑同時量，每約 45 秒各寫一列 CSV |
| `scripts/sdrping.py` | 測量 Steam Datagram Relay 的 UDP RTT（整個專案最核心的部分） |
| `scripts/hoptrace.sh` | 用純 `ping -t` 做逐跳追蹤，當 `mtr` 壞掉時的備用方案 |
| `scripts/udptrace.py` | UDP traceroute，利用來源埠比對回傳的 ICMP |
| `tools/gen_report.py` | 將 CSV 轉為圖表與統計數據，只用標準函式庫，直接跑在 Pi 上 |
| `tools/publish.sh` | 重新產生報表並 push，由 timer 定時觸發 |
| `cf-heartbeat/` | 部署在 Cloudflare Worker 上的 dead-man switch，用來監控探針主機 |
| `systemd/` | 機器上實際運作的 unit 檔、udev 規則與 PPPoE hook，附安裝路徑說明 |

這台機器上的 `mtr` 不管切 ICMP 還是 UDP 模式都跑不動（只能看到第一跳，後面全部是 `???`），所以我才自己手刻了幾支 trace 工具。如果你自己的環境 `mtr` 正常，直接用原本的即可。

## 中途的硬體插曲

實驗做到一半，探針主機只要桌子被稍微碰一下就直接當機。因為 root 整個放在外接 USB SSD 上，接頭只要瞬間接觸不良，整個 OS 就直接掛掉——順便蒸發了 13 小時的尖峰時段數據，圖表上那個斷層就是這樣來的。

完整的修法，以及我在驗證過程中踩到的三個 bug，另外寫在
**[STORAGE-RESILIENCE.md](STORAGE-RESILIENCE.md)**。懶人包：把 root 搬回 SD 卡，SSD 降級成
帶有 `nofail` 的資料掛載點，再加上一套自動復原機制，斷線時能在 22 秒內自動自救掛載回來，全程不需要人工介入。這套解法適用於所有把 Raspberry Pi 的 root 跑在 Realtek RTL9210 橋接器外接 SSD 上的苦主（相信遇到的人絕對不少）。

## 自己重現一次

1. 透過上面的 `GetSDRConfig` API 取得你所在區域的 relay 位址。
2. 用 `scripts/sdrping.py` 戳戳看，確認有正常收到 `Invalid/unknown MsgID 0`。
3. 如果你的 ISP 也提供第二種帳號型態，利用 `nodefaultroute` 搭配 policy route 撥號，確保它不會碰到你的預設路徑。
4. 用 systemd 跑 `scripts/probe.sh`，然後放著幾天不要管它（**務必包含晚上尖峰時段**，離峰時段的數據什麼也證明不了）。

整套工具其實就幾百行 shell script 加上只用標準函式庫的 Python，直接掛在一台平常就開著的機器上跑即可。

## 授權

MIT，見 [LICENSE](LICENSE)。
