#!/usr/bin/env python3
"""
UptimeRobot MCP server for JARVIS (Claude Code on the Gateway VPS).

Read-only. Exposes the external-monitoring status of Gateway/hot-pn/hot-erp-nl (the 3 monitors
set up 2026-08-23, see docs/HoT_Gateway_External_Monitoring_Scope.md) so a Claude Code session can
check external uptime status directly instead of hand-rolling curl calls against the UptimeRobot
API each time. API key read from a local file, not embedded — see UPTIMEROBOT_API_KEY_FILE below.
Canonical copy of the key lives in Vaultwarden ("UptimeRobot Main API Key
(Gateway/hot-pn/hot-erp-nl external monitoring)", House of Trae — Gateway VPS folder).
"""
import json
import os
import urllib.request
import urllib.parse

from mcp.server import MCPServer

API_KEY_FILE = os.environ.get("UPTIMEROBOT_API_KEY_FILE", "/etc/uptimerobot-mcp/api_key.txt")
API_BASE = "https://api.uptimerobot.com/v2"

STATUS_NAMES = {
    0: "paused",
    1: "not checked yet",
    2: "up",
    8: "seems down",
    9: "down",
}


def _api_key() -> str:
    with open(API_KEY_FILE) as f:
        return f.read().strip()


def _call(action: str, extra_params: dict | None = None) -> dict:
    params = {"api_key": _api_key(), "format": "json"}
    if extra_params:
        params.update(extra_params)
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(f"{API_BASE}/{action}", data=data, method="POST")
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


mcp = MCPServer("uptimerobot")


@mcp.tool()
def get_monitors() -> str:
    """List all UptimeRobot monitors (currently: house-of-trae.com / Gateway,
    privatenexus.net / hot-pn, erp.dickson-supplies.com / hot-erp-nl) with their current
    status, response time, and check interval. Use this to check whether any HoT edge host
    is currently reported down by the independent external monitor."""
    result = _call("getMonitors", {"response_times": "1", "response_times_limit": "1"})
    if result.get("stat") != "ok":
        return f"UptimeRobot API error: {json.dumps(result)}"
    lines = []
    for m in result.get("monitors", []):
        status_code = m.get("status")
        status = STATUS_NAMES.get(status_code, f"unknown({status_code})")
        rt = m.get("response_times", [])
        latency = f"{rt[0]['value']}ms" if rt else "n/a"
        lines.append(
            f"- {m.get('friendly_name')} [{m.get('url')}] — status: {status}, "
            f"latency: {latency}, interval: {m.get('interval')}s, id: {m.get('id')}"
        )
    return "\n".join(lines) if lines else "No monitors found."


@mcp.tool()
def get_account_summary() -> str:
    """Get UptimeRobot account-level summary: counts of up/down/paused monitors, plan
    limits, and remaining SMS credits. Use this for a quick overall health check of the
    external monitoring setup itself (e.g. confirming nothing has silently gone paused)."""
    result = _call("getAccountDetails")
    if result.get("stat") != "ok":
        return f"UptimeRobot API error: {json.dumps(result)}"
    a = result.get("account", {})
    return (
        f"Account: {a.get('email')}\n"
        f"Monitors: {a.get('up_monitors')} up, {a.get('down_monitors')} down, "
        f"{a.get('paused_monitors')} paused (of {a.get('total_monitors_count')} total, "
        f"limit {a.get('monitor_limit')})\n"
        f"SMS credits remaining: {a.get('sms_credits')}"
    )


if __name__ == "__main__":
    mcp.run(transport="stdio")
