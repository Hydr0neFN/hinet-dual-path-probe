# 固定 IP 真的能讓遊戲 ping 變低嗎？

**繁體中文** · [English](README.en.md)

同一條線路上，兩種 ISP 帳號型態的**同步 A/B 對照**，全部從一台 Raspberry Pi 量測 —— 而且量的是
**Source 2 遊戲真正在走的 UDP 路徑**，不是隨便 ping 一個附近的 DNS。

給沒耐心的人的結論：**對遊戲路徑而言，沒有。對 Cloudflare 後面的東西而言，差非常多。**
下面的數據由仍在運行的探針每小時自動更新。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="data/chart-dark.svg">
  <img alt="兩條 ISP 路徑同時量測的延遲與封包遺失時序圖" src="data/chart-light.svg">
</picture>

完整數字（隨時更新）：**[data/stats.md](data/stats.md)** · 原始樣本：
[data/paired-scrubbed.csv](data/paired-scrubbed.csv)

---

## 為什麼做這件事

CS2 在一條沒有其他負載的線路上，ping 會突然衝到 200 ms。常見的嫌疑犯 —— server picker、DNS、
Wi-Fi —— 查完全都不是。最後 traceroute 抓到 ICMP `type 11 time-exceeded`，是 HiNet（AS3462）與
Cloudflare（AS13335）之間的一個 routing loop：流量沒有在本地對接，而是繞去國外。

中華電信提供從浮動制免費換成固定制。於是問題很自然：**換了之後，路由真的會改變嗎？**

這個問題出乎意料地難誠實回答。網路上絕大多數的說法，都是拿今天的測速結果，去比對自己對上週的印象。

## 這份量測跟一般做法差在哪

**天真的 A/B 有兩個致命問題，以下是各自的解法。**

### 問題一：先後測量根本沒有意義

換帳號型態、重測一次、比較結果 —— 這量到的是**你何時測**，不是**你改了什麼**。ISP 的暫時性
故障本來就會自己好，然後功勞就記在你最後做的那件事上。

這個實驗的早期版本就是這樣做的，也因此得出了一個很有信心的結論。**那個結論是錯的**，隔天的
數據就打臉了。

解法：讓**同一台主機同時持有兩種帳號型態**。第一條是 router 原本的連線；第二條是 Pi 自己撥的
PPPoE session，加上 `nodefaultroute`，讓它永遠不會變成系統預設路由，只能透過 policy routing
規則抵達。每一輪迴圈**同時**量測兩條路徑，所以任何打到線路上的暫時性干擾會同時打到兩邊，在比較
中互相抵銷。

> **更正，也是給要照抄的人的警告。** `probe.sh` 的第一版是**先後**量測兩條路徑 —— 分別耗時
> 8.6 秒與 10.4 秒 —— 卻把兩列都蓋上迴圈開始時的時間戳。CSV **看起來**是同步的，實際相隔約 9 秒。
> `2026-08-27 21:02` 之前的樣本都帶著這個偏移。這個偏移遠不足以解釋 Cloudflare 的結果（持續數
> 小時的 20 倍差距），但它確實是誇大的說法 —— 而共用時間戳這一欄，是非常容易騙到自己的做法。

```sh
# /etc/ppp/peers/<name>
nodefaultroute          # 量測用的 session 絕對不能變成系統預設路由

# /etc/ppp/ip-up.d/50measure   （$1=介面 $4=本地 IP $6=ipparam）
[ "$6" = "measure" ] || exit 0
ip route replace default dev "$1" table 200      # <- 少了這行，上面那條規則什麼也不會做
ip rule del priority 200 2>/dev/null
ip rule add from "$4" lookup 200 priority 200
```

**兩半缺一不可**：`ip rule` 負責把「來源是第二條 session」的流量送進 table 200，而 `ip route`
才是讓 table 200 知道要往哪送。只有 rule 沒有 route，查表會落回 main table，於是你會**在毫無察
覺的情況下，把同一條路徑量了兩次** —— 這正是這個實驗第一次嘗試失敗、數據完全作廢的原因。

這台 Pi **不是** router，也不承載家裡的流量。它只是多持有一條 session，好讓兩條路徑能被公平比較。

### 問題二：ping 1.1.1.1 量到的不是你遊戲在走的路

跑在 Valve **Steam Datagram Relay（SDR）** 上的遊戲，送的是**到 relay 的 UDP**，不是到 DNS
resolver 的 ICMP。這兩者可能走在不同的實體鏈路上 —— ECMP 是對 5-tuple 做 hash，所以連兩條 UDP
flow 都可能分岔。ping Cloudflare 只能告訴你 Cloudflare 那條路的狀況，其他什麼都說明不了。

**有用的小技巧：SDR relay 會回應丟到它遊戲埠上的垃圾 UDP 封包。** 對 relay 的 `27015–27060`
送 32 個隨機位元組，它會回：

```
Invalid/unknown MsgID 0
```

這就是一次完整的 round trip，走在**遊戲實際使用的那個 transport 上**，用一個普通 socket 就能做到，
不需要開遊戲，也不需要任何 client library。[`scripts/sdrping.py`](scripts/sdrping.py) 做的就是
這件事，輸出 `avg_rtt,loss`。

**必須注意的限制：RTT 可信，loss 不可信。** relay 會默默忽略一部分垃圾封包 —— 在測過的每一種
發送間隔（0.12 秒、0.35 秒、0.8 秒）下都有 16–33% 沒有回應，而同時 RTT 穩定維持在 33.2–33.5 ms。
它在對無意義的流量做 rate limiting，這完全合理。**所以這個方法只能拿來看延遲，絕不能拿來算封包
遺失率。**

relay 位址來自 Valve 自己的 endpoint：

```
https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=730
```

## 數據說了什麼

即時數字見 [data/stats.md](data/stats.md)。結果的形狀是這樣：

| | 固定制（Static IP） | 浮動制（Dynamic IP） |
|---|---|---|
| **遊戲路徑**（Tokyo SDR relay, UDP） | 中位數 ~34 ms | 中位數 ~34 ms — **配對差值 ≈ 0 ms** |
| 遊戲路徑 p95 | 平的，幾乎等於中位數 | 在 38–52 ms 之間游移 |
| **Cloudflare 1.1.1.1** | 3 ms，紋風不動 | 基線 24 ms，**傍晚滿載時 200 ms 以上，並伴隨封包遺失** |

所以：

- **固定制不會讓遊戲 ping 變低。** 在真正的遊戲 transport 上，中位數差值是零。任何宣稱「固定 IP
  能給你更好的 ping」的說法，都沒有在量遊戲路徑。
- **但它確實消除了抖動。** 固定制的 p95 一個小時接著一個小時等於它自己的中位數；浮動制做不到。
  對一款需要瞬間反應的射擊遊戲來說，這比平均值少個幾 ms 有價值得多。
- **Cloudflare 的故障只存在於浮動制。** 不論那個 routing 問題的成因是什麼，兩個帳號池顯然沒有被
  同等對待，而且只有其中一個會繞路。

### 這份數據**不能**證明什麼

- relay 到遊戲伺服器那一段是看不到的。遊戲內觀測到的約 82 ms 裡，探針只能看到約 33 ms。如果某次
  遊戲很卡但探針全程乾淨，那就指向那一段。
- 一條線路、一家 ISP、一個城市。這是一套**你可以自己重跑的方法**，不是對固定 IP 的通則性結論。
- 撰寫當下只有兩個晚上的尖峰時段數據，其中一晚還因為一次無關的硬體故障整段遺失（見下）。
  Cloudflare 的結果是明確的；抖動的結論請當作**方向性**參考。


## 為什麼 Valorant 不受這個問題影響

同一條線路、同一個晚上，CS2 在飆 ping 的時候 Valorant 通常沒事。原因不是玄學，是兩家公司把流量
交給網際網路的方式根本不同。

| | CS2（Valve SDR） | Valorant（Riot） |
|---|---|---|
| 傳輸網路 | Steam Datagram Relay，走公開網際網路的 transit 到 relay | **Riot Direct**（AS6507），Riot 自建的私有骨幹 |
| 在台灣的接入 | 依 relay 選擇與當下的 BGP 路由而定 | 在 **TPIX（台北網際網路交換中心）** 有 PoP 並與本地 ISP 直接對接 |
| 遊戲流量會經過 Cloudflare 嗎 | 可能 —— 這正是本專案抓到的故障 | **不會**。Cloudflare 只可能出現在網站、登入等應用層 |
| 伺服器位置 | 依 relay 而定（本專案量東京） | 香港 / 東京 / 新加坡，經 Riot 自己的骨幹回傳 |

關鍵在於：**HiNet 與 Cloudflare 之間沒有良好的本地對接**，所以流量會繞去國外；而 **Riot 有在
TPIX 落地**，封包從 HiNet 出去就直接交給 Riot Direct，之後全程走 Riot 自己的線路到香港或東京。
一個踩得到那個 routing loop，另一個根本不經過。

> **講清楚界線**：本專案的探針**沒有量 Valorant**。上面說的是「為什麼這個故障機制在架構上碰不到
> Valorant」，不是量測結果。

順帶一提，這次調查過程中，Valorant 確實出現過一次明顯的不穩定 —— 追出來的原因是 **Steam 正在背景
下載遊戲把上行塞滿**，跟路由完全無關。停掉下載就正常了。**同一款遊戲卡頓，可以有完全不同的成因；
先量，再下結論。**

## 檔案結構

| 路徑 | 內容 |
|---|---|
| `scripts/probe.sh` | 取樣迴圈：兩條路徑同時量，每約 45 秒各寫一列 CSV |
| `scripts/sdrping.py` | 對 Steam Datagram Relay 的 UDP RTT —— 最有趣的部分 |
| `scripts/hoptrace.sh` | 用純 `ping -t` 做逐跳追蹤，給 `mtr` 壞掉時用 |
| `scripts/udptrace.py` | UDP traceroute，用來源埠比對回傳的 ICMP |
| `tools/gen_report.py` | CSV → 圖表與統計，只用標準函式庫，直接跑在 Pi 上 |
| `tools/publish.sh` | 重新產生並推送，由 timer 觸發 |
| `cf-heartbeat/` | 給探針主機用的 Cloudflare Worker dead-man switch |
| `systemd/` | 實際的 unit 檔、udev 規則與 PPPoE hook，附安裝路徑 |

`mtr` 在這台機器上無論 ICMP 或 UDP 模式都不能用（只出得來第一跳，之後全是 `???`），所以才會有那些
手刻的 tracer。你的能用就用你的。

## 中途的硬體插曲

做到一半，探針主機開始只要桌子被碰一下就當機。root 放在 USB SSD 上，所以一瞬間的接觸不良就會
殺掉整個 OS —— 順便帶走 13 小時的尖峰時段數據，也就是圖上那個缺口。

修法，以及在驗證過程中抓到的三個 bug，另外寫在
**[STORAGE-RESILIENCE.md](STORAGE-RESILIENCE.md)**。簡短版：root 搬到 SD 卡，SSD 降級成
`nofail` 掛載，再加一套復原階梯，能在 22 秒內自己把它救回來，全程不需要人。對任何把 Pi 的 root
放在 Realtek RTL9210 橋接器後面的 USB SSD 上的人都適用 —— 這種人不少。

## 自己重現一次

1. 從上面的 `GetSDRConfig` 取得你所在區域的 relay 位址。
2. 把 `scripts/sdrping.py` 指過去，確認你收得到 `Invalid/unknown MsgID 0`。
3. 如果你的 ISP 也提供第二種帳號型態，用 `nodefaultroute` 加 policy route 撥起來，確保它碰不到
   你的預設路徑。
4. 用 systemd 跑 `scripts/probe.sh`，然後放著幾天不要管它 —— **一定要包含晚上**，離峰時段的數據
   什麼也證明不了。

整套東西不過是幾百行 shell 加標準函式庫的 Python，跑在一台本來就開著的機器上。

## 授權

MIT，見 [LICENSE](LICENSE)。
