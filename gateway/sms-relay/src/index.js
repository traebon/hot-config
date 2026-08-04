import { readFileSync } from "node:fs";

const NTFY_URL = process.env.NTFY_URL ?? "http://ntfy:80";
const NTFY_TOPIC = process.env.NTFY_TOPIC ?? "hot-alerts";
const TO_NUMBER = process.env.SMS_TO_NUMBER;
const FROM_NUMBER = process.env.SMS_FROM_NUMBER;
const ACCOUNT_SID = readSecret(process.env.TWILIO_ACCOUNT_SID_FILE);
const AUTH_TOKEN = readSecret(process.env.TWILIO_AUTH_TOKEN_FILE);

// Only Ntfy's max/"urgent" priority (5) triggers an SMS. CrowdSec's own ban notifications
// already publish at priority=high (4) - that's WARNING severity per the Alerting Architecture
// table, not CRITICAL, and deliberately does not trigger SMS. Whichever publisher is meant to
// carry CRITICAL-severity events (service down, cert <7d, WireGuard down, disk >95%) needs to
// set priority=5/urgent on those specific messages for SMS to fire - not yet verified which
// publishers actually do this, since the original relay's source (and its exact trigger logic)
// was lost before this rebuild. See sms_relay_migration_scope memory.
const SMS_PRIORITY_THRESHOLD = 5;

// max 1 SMS per alert group per 5 minutes, per the documented Alerting Architecture rate limit.
// "Alert group" = the message title, since that's the only stable grouping key Ntfy messages
// carry. In-memory only - resets on restart, which is an acceptable simplification for a relay
// this small.
const RATE_LIMIT_MS = 5 * 60 * 1000;
const lastSentByGroup = new Map();

function readSecret(path) {
  if (!path) return null;
  try {
    return readFileSync(path, "utf8").trim();
  } catch {
    return null;
  }
}

function isPlaceholder(value) {
  return !value || value.startsWith("REPLACE_ME");
}

async function sendSms(body) {
  if (isPlaceholder(ACCOUNT_SID) || isPlaceholder(AUTH_TOKEN) || isPlaceholder(FROM_NUMBER) || isPlaceholder(TO_NUMBER)) {
    console.log(`[sms-relay] Twilio not configured yet (placeholder credentials) - would have sent: ${body}`);
    return;
  }

  const url = `https://api.twilio.com/2010-04-01/Accounts/${ACCOUNT_SID}/Messages.json`;
  const auth = Buffer.from(`${ACCOUNT_SID}:${AUTH_TOKEN}`).toString("base64");
  const params = new URLSearchParams({ To: TO_NUMBER, From: FROM_NUMBER, Body: body });

  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Basic ${auth}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: params,
  });

  if (!res.ok) {
    const text = await res.text();
    console.error(`[sms-relay] Twilio send failed: ${res.status} ${text}`);
    return;
  }
  console.log(`[sms-relay] SMS sent: ${body}`);
}

function shouldRateLimit(group) {
  const now = Date.now();
  const last = lastSentByGroup.get(group);
  if (last && now - last < RATE_LIMIT_MS) {
    return true;
  }
  lastSentByGroup.set(group, now);
  return false;
}

// Grafana's webhook contact point always posts its fixed JSON alert-group payload as the
// Ntfy message body - there's no way to template the body via Grafana's webhook settings
// (checked: no "message"/"payload" field is honored). Detect that shape and pull out the
// real groupKey/alertname/summary instead of using the generic title/body path, which
// would otherwise: (a) rate-limit-collide across different alert types, since every
// Grafana-critical alert currently shares one static Ntfy title, and (b) show a raw JSON
// dump as the SMS text instead of anything readable.
function parseGrafanaPayload(message) {
  let payload;
  try {
    payload = JSON.parse(message);
  } catch {
    return null;
  }
  if (!payload || typeof payload !== "object" || !Array.isArray(payload.alerts) || !payload.groupKey) {
    return null;
  }
  const labels = payload.commonLabels ?? {};
  const summary = payload.commonAnnotations?.summary ?? "";
  const status = (payload.status ?? "unknown").toUpperCase();
  return {
    group: payload.groupKey,
    text: `${status}: ${labels.alertname ?? "alert"} (${labels.severity ?? "?"})${summary ? " - " + summary : ""}`,
  };
}

async function handleMessage(msg) {
  if (msg.event !== "message") return; // ignore "open"/keepalive events
  if ((msg.priority ?? 3) < SMS_PRIORITY_THRESHOLD) return;

  const grafana = parseGrafanaPayload(msg.message ?? "");
  const group = grafana?.group ?? msg.title ?? "untitled";
  if (shouldRateLimit(group)) {
    console.log(`[sms-relay] Rate-limited, skipping: ${group}`);
    return;
  }

  const text = grafana?.text ?? `${msg.title ?? "untitled"}: ${msg.message ?? ""}`;
  const body = text.slice(0, 320);
  await sendSms(body);
}

async function subscribeLoop() {
  const url = `${NTFY_URL}/${NTFY_TOPIC}/json`;
  console.log(`[sms-relay] Subscribing to ${url}`);

  try {
    const res = await fetch(url);
    if (!res.ok || !res.body) {
      throw new Error(`subscribe failed: ${res.status}`);
    }

    let buffer = "";
    for await (const chunk of res.body) {
      buffer += Buffer.from(chunk).toString("utf8");
      let newlineIndex;
      while ((newlineIndex = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newlineIndex).trim();
        buffer = buffer.slice(newlineIndex + 1);
        if (!line) continue;
        try {
          const msg = JSON.parse(line);
          await handleMessage(msg);
        } catch (e) {
          console.error(`[sms-relay] Failed to parse/handle message: ${e.message}`);
        }
      }
    }
    throw new Error("stream ended unexpectedly");
  } catch (e) {
    console.error(`[sms-relay] Subscription error: ${e.message} - reconnecting in 5s`);
    await new Promise((r) => setTimeout(r, 5000));
  }
}

console.log("[sms-relay] Starting");
if (isPlaceholder(ACCOUNT_SID) || isPlaceholder(AUTH_TOKEN) || isPlaceholder(FROM_NUMBER)) {
  console.log("[sms-relay] WARNING: Twilio credentials/from-number are still placeholders - will log instead of sending");
}
for (;;) {
  await subscribeLoop();
}
