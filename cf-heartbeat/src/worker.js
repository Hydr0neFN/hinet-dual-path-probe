// Dead-man switch for the RPi4, hosted on Cloudflare.
//
// The Pi pings this Worker every few minutes. A Cron Trigger checks how long it has
// been since the last ping and emails when the Pi goes quiet. The direction matters:
// every alert the Pi can raise itself dies with the Pi, so the alert that says "the
// machine is gone" has to come from somewhere that is not the machine.
//
// Endpoints
//   POST/GET  /beat        ?token=<TOKEN>   -> record a healthy heartbeat
//   POST/GET  /beat/fail   ?token=<TOKEN>   -> record a heartbeat that reports degradation
//   GET       /status      ?token=<TOKEN>   -> human-readable current state
//
// The request body (if any) is stored verbatim and included in the alert email, so the
// mail says what was wrong at the last contact, not just that contact stopped.

import { EmailMessage } from "cloudflare:email";

const KEY_LAST = "last";     // JSON: { ts, state, body }
const KEY_ALERT = "alerted"; // "1" while an outage alert is outstanding

function buildMime({ from, to, subject, text }) {
  const domain = from.split("@")[1];
  return [
    `From: Pi Watchdog <${from}>`,
    `To: <${to}>`,
    `Subject: ${subject}`,
    `Message-ID: <${crypto.randomUUID()}@${domain}>`,
    `Date: ${new Date().toUTCString()}`,
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="utf-8"',
    "",
    text,
  ].join("\r\n");
}

async function sendMail(env, subject, text) {
  const from = env.FROM_ADDRESS;
  const to = env.TO_ADDRESS;
  const msg = new EmailMessage(from, to, buildMime({ from, to, subject, text }));
  await env.MAILER.send(msg);
}

function authorised(url, env) {
  const t = url.searchParams.get("token");
  return Boolean(env.BEAT_TOKEN) && t === env.BEAT_TOKEN;
}

function fmtAge(sec) {
  if (sec < 90) return `${Math.round(sec)}s`;
  if (sec < 5400) return `${Math.round(sec / 60)} min`;
  return `${(sec / 3600).toFixed(1)} h`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (!authorised(url, env)) {
      return new Response("forbidden\n", { status: 403 });
    }

    if (url.pathname === "/status") {
      const raw = await env.HB.get(KEY_LAST);
      if (!raw) return new Response("no heartbeat recorded yet\n", { status: 200 });
      const last = JSON.parse(raw);
      const age = (Date.now() - last.ts) / 1000;
      const alerting = (await env.HB.get(KEY_ALERT)) === "1";
      return new Response(
        `last seen : ${new Date(last.ts).toISOString()} (${fmtAge(age)} ago)\n` +
          `state     : ${last.state}\n` +
          `alerting  : ${alerting}\n` +
          `report    : ${last.body || "(none)"}\n`,
        { status: 200 },
      );
    }

    if (url.pathname === "/beat" || url.pathname === "/beat/fail") {
      const state = url.pathname.endsWith("/fail") ? "degraded" : "ok";
      let body = "";
      try {
        body = (await request.text()).slice(0, 2000);
      } catch {
        body = "";
      }
      const prevRaw = await env.HB.get(KEY_LAST);
      const prev = prevRaw ? JSON.parse(prevRaw) : null;

      await env.HB.put(KEY_LAST, JSON.stringify({ ts: Date.now(), state, body }));

      // Recovery mail: only when an outage alert was actually outstanding.
      if ((await env.HB.get(KEY_ALERT)) === "1") {
        await env.HB.delete(KEY_ALERT);
        const downFor = prev ? fmtAge((Date.now() - prev.ts) / 1000) : "unknown";
        await sendMail(
          env,
          "RPi4 is back online",
          `The Pi is reporting again.\n\nSilent for: ${downFor}\nState: ${state}\n\n${body}\n`,
        );
      } else if (state === "degraded" && (!prev || prev.state !== "degraded")) {
        // Edge-triggered: mail once when it first goes degraded, not every 5 minutes.
        await sendMail(
          env,
          "RPi4 reports a problem",
          `The Pi is alive but reporting a degraded state.\n\n${body}\n`,
        );
      }
      return new Response("ok\n", { status: 200 });
    }

    return new Response("not found\n", { status: 404 });
  },

  async scheduled(event, env, ctx) {
    const limit = Number(env.ALERT_AFTER_SECONDS || 900);
    const raw = await env.HB.get(KEY_LAST);
    if (!raw) return; // never heard from it at all; nothing to compare against yet

    const last = JSON.parse(raw);
    const age = (Date.now() - last.ts) / 1000;
    if (age <= limit) return;

    if ((await env.HB.get(KEY_ALERT)) === "1") return; // already told them

    await env.HB.put(KEY_ALERT, "1");
    await sendMail(
      env,
      `RPi4 has gone silent (${fmtAge(age)})`,
      `No heartbeat from the Pi for ${fmtAge(age)} (threshold ${fmtAge(limit)}).\n\n` +
        `Last contact : ${new Date(last.ts).toISOString()}\n` +
        `Last state   : ${last.state}\n` +
        `Last report  : ${last.body || "(none)"}\n\n` +
        `Likely causes: power cut, network down, SD card failure, or a kernel wedge that\n` +
        `the 15s hardware watchdog could not clear.\n\n` +
        `Remote checks worth trying: your VPN/overlay network, then the service it hosts.\n`,
    );
  },
};
