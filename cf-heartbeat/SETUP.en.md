# Pi dead-man switch on Cloudflare — setup

**English** · [繁體中文](SETUP.md)

Why this exists: every alert the Pi can raise goes through Home Assistant, so a total
failure (power cut, dead SD card, kernel wedge, network gone) raises nothing at all.
This Worker is the one alert that does not live on the machine it is watching.

Cost: zero. Workers free tier covers 100k requests/day; this uses ~288.

## What you run

Everything below runs in this terminal. Prefix each with `!` so the output lands in the
session, e.g. `! npx wrangler login`.

```
cd <this directory>

# 1. Authenticate (opens a browser once)
npx wrangler login

# 2. Create the KV namespace, then paste the printed id into wrangler.toml
npx wrangler kv namespace create HB

# 3. Set the shared secret the Pi will present. Pick a long random string and keep it.
npx wrangler secret put BEAT_TOKEN

# 4. Edit wrangler.toml: FROM_ADDRESS domain + the KV id from step 2

# 5. Deploy
npx wrangler deploy
```

## Cloudflare dashboard prerequisites

Email Routing must be able to send on your behalf:

1. Email → Email Routing → enable it on the domain you used in `FROM_ADDRESS`.
2. Email Routing → Destination addresses → add `you@example.com` and click the
   verification link Cloudflare emails you. **The Worker cannot send until this is verified.**
   (`you-alt@example.com` can be added as a second destination; change `TO_ADDRESS` and
   `destination_address` if you would rather it went there.)

## Then point the Pi at it

`wrangler deploy` prints the Worker URL. On the Pi:

```
# on the probe host
echo 'https://pi-heartbeat.<your-subdomain>.workers.dev/beat?token=<BEAT_TOKEN>' > /etc/heartbeat.url
chmod 600 /etc/heartbeat.url
/usr/local/sbin/heartbeat.sh && echo sent
```

**`/etc/heartbeat.url` takes one URL per line.** Extra lines are failover — they are equivalent endpoints for the same Worker, and the first one that accepts the ping wins. That way a DNS problem, an expired domain or a network that blanket-blocks one hostname cannot silence the alarm. Two is a sensible minimum: one `*.workers.dev`, one on your own domain.

`heartbeat.timer` is already installed and enabled on the Pi and fires every 5 minutes.
Until `/etc/heartbeat.url` exists the script exits 0 and does nothing, so nothing breaks
if you never finish this.

## Verify end to end

```
curl "https://pi-heartbeat.<your-subdomain>.workers.dev/status?token=<BEAT_TOKEN>"
```

Should print the last-seen time and the Pi health line. To prove the alert path works,
stop the timer on the Pi (`systemctl stop heartbeat.timer`), wait 15 minutes, and confirm
the email arrives — then start it again. Verify the alert path while you can still walk
over to the machine; an untested dead-man switch is not a dead-man switch.

## What the emails say

- **"RPi4 has gone silent (…)"** — no heartbeat past the threshold. Sent once per outage.
  Includes the last health line received, so you know what state it was in when it died.
- **"RPi4 is back online"** — sent when heartbeats resume, with how long it was gone.
- **"RPi4 reports a problem"** — the Pi is alive but self-reporting degradation
  (a failed systemd unit, HA not answering on 8123, or root filesystem ≥90% full).
  Edge-triggered, so it does not repeat every five minutes.

## Note on the threshold vs. reboots

A watchdog reboot takes well under 15 minutes, so a single self-healing reboot will not
email you. That is deliberate: you want to hear about outages you have to act on, not
about the machine fixing itself.

## Alerts for named jobs (`/alert`)

The heartbeat is a dead-man switch: one slot, overwritten by `heartbeat.sh` every five
minutes, answering exactly one question — is the box still there. Named jobs that run on
their own schedule — a daily push, a weekly backup — do not fit that slot, and forcing them
into it breaks three things at once: the message is overwritten within five minutes, a
healthy box reads as degraded, and — because `/beat/fail` is edge-triggered — once a job has
parked the state at degraded, **a later genuine hardware fault produces no change in the
signal and therefore no mail**.

So named jobs take a separate path, with their own KV key each, never touching the
heartbeat slot:

```
POST /alert?token=<BEAT_TOKEN>&source=<name>        # this job is failing
POST /alert/clear?token=<BEAT_TOKEN>&source=<name>  # this job is healthy again
```

Each `source` is edge-triggered on its own: the first failure mails, repeats stay silent,
recovery mails once. `/status` lists every outstanding named alert. A `source` must match
`^[a-z0-9][a-z0-9._-]{0,63}$` — KV keys are built by concatenation, so the name is
constrained rather than trusted.

On the machine, `scripts/job-alert.sh` wraps this so nothing has to assemble URLs:

```
job-alert.sh <source> fail      "message"   # deterministic failure -> mail at once
job-alert.sh <source> soft-fail "message"   # transient -> mail on the 2nd in a row
job-alert.sh <source> ok                    # healthy -> clears the alert
```

`soft-fail` exists for a standing rule: **a failure that was automatically repaired is a
non-event.** One lost fetch on an hourly timer is noise; two in a row is an outage. The
endpoints come from `/etc/heartbeat.url`, so this inherits the same multi-endpoint failover.

The success path must call `ok`, and **"nothing to do this run" counts as success** —
otherwise one bad day stays outstanding until the data happens to change again.
