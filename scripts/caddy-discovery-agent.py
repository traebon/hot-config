#!/usr/bin/env python3
"""
caddy-discovery-agent.py — parses the Caddyfile and pushes route candidates to
PrivateNexus /api/discovery/ingest.

Runs on Gateway VPS via cron.  Uses the static discovery_agent_token.
"""
import json
import re
import urllib.request
import urllib.error
import sys
import os
from pathlib import Path

CADDYFILE      = os.getenv("CADDYFILE", "/opt/stacks/caddy/Caddyfile")
INGEST_URL     = os.getenv("INGEST_URL",  "https://privatenexus.net/api/discovery/ingest")
TOKEN_FILE     = os.getenv("TOKEN_FILE",  "/opt/hot-config/scripts/discovery_agent_token.txt")
HOST_LABEL     = "gateway-vps"
SOURCE_LABEL   = "caddy"

def read_token():
    path = Path(TOKEN_FILE)
    if path.exists():
        return path.read_text().strip()
    # Fallback: env var
    return os.getenv("DISCOVERY_AGENT_TOKEN", "")

def to_slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

def parse_caddyfile(caddyfile_path: str) -> list[dict]:
    """Extract all site blocks and their hostnames from the Caddyfile."""
    with open(caddyfile_path) as f:
        content = f.read()

    candidates = []
    # Match site address lines (before the opening brace)
    # A site block starts at column 0 with one or more host names
    pattern = re.compile(r'^([^#{}\s][^\n{]*?)\s*\{', re.MULTILINE)

    for match in pattern.finditer(content):
        raw_hosts_str = match.group(1).strip()
        # Split on comma to handle multiple hosts: domain.com, www.domain.com
        raw_hosts = [h.strip() for h in raw_hosts_str.split(",") if h.strip()]

        for raw_host in raw_hosts:
            # Skip snippets (surrounded by parens) and global options block
            if raw_host.startswith("(") or not raw_host:
                continue
            # Strip optional port and protocol prefix for slug generation
            clean = re.sub(r"^https?://", "", raw_host)
            clean = re.sub(r":\d+$", "", clean)
            # Skip non-hostname looking values
            if not re.search(r"\.", clean):
                continue

            slug = to_slug(clean.replace(".", "-"))
            if not slug:
                continue

            candidates.append({
                "source":                SOURCE_LABEL,
                "host":                  HOST_LABEL,
                "raw_name":              raw_host,
                "raw_image":             None,
                "suggested_slug":        slug,
                "suggested_name":        clean,
                "suggested_description": f"Caddy route for {clean}",
                "suggested_category":    "app",
                "suggested_access_mode": "public",
                "suggested_runtime":     "caddy-route",
                "suggested_health_ep":   f"https://{clean}/",
                "raw_data":              {"host": raw_host, "source_file": caddyfile_path},
            })

    # Deduplicate by slug
    seen = set()
    unique = []
    for c in candidates:
        if c["suggested_slug"] not in seen:
            seen.add(c["suggested_slug"])
            unique.append(c)
    return unique

def ingest(candidates: list[dict], token: str) -> dict:
    payload  = json.dumps({"candidates": candidates}).encode()
    req      = urllib.request.Request(
        INGEST_URL,
        data    = payload,
        headers = {
            "Content-Type":  "application/json",
            "Authorization": f"Bearer {token}",
        },
        method  = "POST",
    )
    # Allow self-signed / internal certs if needed
    import ssl
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {body}")

def main():
    token = read_token()
    if not token:
        print("[caddy-agent] ERROR: no agent token found", file=sys.stderr)
        sys.exit(1)

    try:
        candidates = parse_caddyfile(CADDYFILE)
    except FileNotFoundError:
        print(f"[caddy-agent] ERROR: Caddyfile not found at {CADDYFILE}", file=sys.stderr)
        sys.exit(1)

    if not candidates:
        print("[caddy-agent] no route candidates found in Caddyfile")
        return

    # Batch in groups of 100
    total_inserted = 0
    total_skipped  = 0
    batch_size     = 50

    for i in range(0, len(candidates), batch_size):
        batch  = candidates[i : i + batch_size]
        result = ingest(batch, token)
        total_inserted += result.get("inserted", 0)
        total_skipped  += result.get("skipped",  0)

    print(f"[caddy-agent] pushed {len(candidates)} candidates — inserted: {total_inserted}, skipped: {total_skipped}")

if __name__ == "__main__":
    main()
