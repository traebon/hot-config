#!/usr/bin/env python3
# PrivateNexus Lockdown Mode -- Wazuh active-response webhook forwarder.
#
# Wazuh invokes this script with a single-line JSON message on stdin in the
# standard active-response v1 envelope:
#   {"version":1,"origin":{...},"command":"add","parameters":{"alert":{...},...}}
# We only care about "add" (a real alert firing) and about the full "alert"
# object inside parameters -- that's what carries rule.level/rule.id/srcip.
#
# This script does no tier logic itself -- it just forwards the alert to
# PrivateNexus's webhook, which decides Alert/Soft/Hard from rule.level (see
# ALERT_LEVEL/SOFT_LEVEL/HARD_LEVEL in app/backend/src/routes/lockdown.js).
# Bound to <level>10</level> in ossec.conf so this only fires at all for
# alerts that could plausibly matter (below-threshold alerts still hit the
# webhook currently since the AR block is level-gated at the Wazuh side
# already; the app-side threshold check is a second, authoritative gate).
#
# Token file lives alongside this script in the same active-response/bin
# volume (persistent across container recreates, unlike the rest of the
# container filesystem) -- root-only (600), read once per invocation.

import json
import sys
import os
import urllib.request
import urllib.error

TOKEN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".pn_lockdown_token")
WEBHOOK_URL = "https://privatenexus.net/api/lockdown/webhook/wazuh"
LOG_FILE = "/var/ossec/logs/active-responses.log"


def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write("%s pn-lockdown-webhook.py: %s\n" % (__import__("datetime").datetime.now().isoformat(), msg))
    except Exception:
        pass


def main():
    raw = sys.stdin.read()
    try:
        msg = json.loads(raw)
    except Exception as e:
        log("failed to parse stdin JSON: %s" % e)
        return 1

    # "delete" fires if a timeout is configured on the command -- ours isn't
    # (timeout_allowed=no in ossec.conf), so this should never happen, but
    # skip cleanly rather than forward a bogus alert if it ever does.
    if msg.get("command") != "add":
        return 0

    alert = (msg.get("parameters") or {}).get("alert")
    if not alert:
        log("no alert object in active-response message, skipping")
        return 0

    try:
        with open(TOKEN_FILE) as f:
            token = f.read().strip()
    except Exception as e:
        log("could not read token file: %s" % e)
        return 1

    body = json.dumps({"alert": alert}).encode("utf-8")
    req = urllib.request.Request(
        WEBHOOK_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer %s" % token,
            "User-Agent": "wazuh-pn-lockdown-webhook/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            log("webhook ok: HTTP %s %s" % (resp.status, resp.read().decode("utf-8", "replace")[:300]))
    except urllib.error.HTTPError as e:
        log("webhook HTTP error %s: %s" % (e.code, e.read().decode("utf-8", "replace")[:300]))
    except Exception as e:
        log("webhook call failed: %s" % e)

    return 0


if __name__ == "__main__":
    sys.exit(main())
