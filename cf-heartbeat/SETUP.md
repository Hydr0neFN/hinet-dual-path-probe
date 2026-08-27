# Pi 的 dead-man switch，架在 Cloudflare 上

**繁體中文** · [English](SETUP.en.md)

為什麼需要這個：這台機器能發出的每一種警報，都是透過跑在它自己身上的 Home Assistant 送出去的。
也就是說，**當它徹底掛掉時（斷電、SD 卡壞掉、kernel 卡死、網路斷線），你不會收到任何通知**。

這個 Worker 是唯一一個**不住在被監控機器上**的警報。

費用：零。Workers 免費方案是每天 10 萬次請求，這個大概用 288 次。

## 你要執行的指令

以下全部在終端機執行。每一行前面加 `!`，輸出就會留在對話裡，例如 `! npx wrangler login`。

```
cd <這個目錄>

# 1. authenticate（會開一次瀏覽器）
npx wrangler login

# 2. 建立 KV namespace，然後把印出來的 id 貼進 wrangler.toml
npx wrangler kv namespace create HB

# 3. 設定 Pi 要出示的共用密鑰。挑一串夠長的隨機字串，記下來。
npx wrangler secret put BEAT_TOKEN

# 4. 編輯 wrangler.toml：FROM_ADDRESS 的網域，以及第 2 步拿到的 KV id

# 5. 部署
npx wrangler deploy
```

## Cloudflare 後台的前置設定

Email Routing 必須被授權代你寄信：

1. Email → Email Routing → 在 `FROM_ADDRESS` 用的那個網域上啟用。
2. Email Routing → Destination addresses → 加入你的收件信箱，並點擊 Cloudflare 寄給你的驗證信。
   **在驗證完成之前，Worker 是寄不出信的。**

## 然後把 Pi 指過去

`wrangler deploy` 會印出 Worker 的 URL。在探針主機上：

```
echo 'https://pi-heartbeat.<你的子網域>.workers.dev/beat?token=<BEAT_TOKEN>' > /etc/heartbeat.url
chmod 600 /etc/heartbeat.url
/usr/local/sbin/heartbeat.sh && echo sent
```

**`/etc/heartbeat.url` 一行放一個 URL。** 多寫幾行就是備援 —— 它們是同一個 Worker 的等價端點，第一個成功送出的就算數。這樣一來，某個主機名被 DNS 問題、網域到期或企業防火牆擋掉時，警報不會跟著消失。建議至少放兩個：`*.workers.dev` 一個，自己網域一個。

`heartbeat.timer` 已經安裝並啟用，每 5 分鐘觸發一次。在 `/etc/heartbeat.url` 出現之前，腳本會直接
以 rc=0 結束、什麼也不做 —— 所以就算你一直沒設定完，也不會有任何東西壞掉。

## 端到端驗證

```
curl "https://pi-heartbeat.<你的子網域>.workers.dev/status?token=<BEAT_TOKEN>"
```

應該會印出最後一次回報的時間與 Pi 的健康摘要。

要證明**警報路徑**真的會動，就把 Pi 上的 timer 停掉（`systemctl stop heartbeat.timer`），等 15 分鐘，
確認信有寄到，然後再啟動。**趁你還走得到那台機器的時候驗證** —— 沒測過的 dead-man switch 不算
dead-man switch。

## 信件內容

- **「RPi4 has gone silent (…)」** —— 超過門檻沒收到心跳。每次故障只寄一封，內含最後一次收到的
  健康摘要，讓你知道它死掉當下是什麼狀態。
- **「RPi4 is back online」** —— 心跳恢復時寄出，附上失聯了多久。
- **「RPi4 reports a problem」** —— 機器還活著，但自己回報異常（有 systemd unit 失敗、HA 的 8123
  沒回應、或 root 檔案系統用量 ≥ 90%）。這封是**邊緣觸發**，不會每五分鐘重複轟炸。

## 關於門檻與重開機

watchdog 造成的重開遠少於 15 分鐘，所以單次自我修復的重開**不會**寄信給你。這是刻意的：你要收到的
是「需要你採取行動」的故障，不是「機器自己修好了」的通知。
