#!/usr/bin/env python3
"""
docker-discovery-agent.py — discovers running Docker containers and pushes candidates
to PrivateNexus /api/discovery/ingest.

Deploy to each VM that has Docker containers to be discovered.
Configure via environment variables or edit the constants below.
"""
import json
import re
import subprocess
import urllib.request
import urllib.error
import urllib.parse
import sys
import os
from pathlib import Path

INGEST_URL   = os.getenv("INGEST_URL",   "https://privatenexus.net/api/discovery/ingest")
TOKEN_FILE   = os.getenv("TOKEN_FILE",   "/opt/discovery/agent_token.txt")
HOST_LABEL   = os.getenv("AGENT_HOST",   "unknown-host")
SOURCE_LABEL = "docker_agent"

def read_token():
    path = Path(TOKEN_FILE)
    if path.exists():
        return path.read_text().strip()
    return os.getenv("DISCOVERY_AGENT_TOKEN", "")

def to_slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

def infer_category(image: str) -> str:
    img = image.lower()
    if re.search(r"postgres|mariadb|mysql|redis|mongo", img):   return "database"
    if re.search(r"nginx|caddy|traefik|apache|haproxy", img):   return "proxy"
    if re.search(r"grafana|prometheus|loki|uptime", img):       return "monitoring"
    if re.search(r"keycloak|vault|authelia|wazuh", img):        return "security"
    if re.search(r"forgejo|gitea|gitlab", img):                 return "vcs"
    if re.search(r"nextcloud|immich|vaultwarden", img):         return "personal"
    if re.search(r"erpnext|frappe", img):                       return "business"
    return "app"

def get_containers() -> list[dict]:
    """Return a list of running container dicts via docker inspect."""
    try:
        ids_out = subprocess.check_output(
            ["docker", "ps", "-q"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"docker ps failed: {e}")

    if not ids_out:
        return []

    ids = ids_out.split("\n")
    inspect_out = subprocess.check_output(
        ["docker", "inspect"] + ids, text=True, stderr=subprocess.DEVNULL
    )
    return json.loads(inspect_out)

def container_to_candidate(c: dict) -> dict | None:
    name   = (c.get("Name") or "").lstrip("/")
    image  = (c.get("Config", {}).get("Image") or "")
    labels = c.get("Config", {}).get("Labels") or {}
    ports  = c.get("NetworkSettings", {}).get("Ports") or {}
    state  = c.get("State", {})

    if not name or state.get("Status") != "running":
        return None

    slug = to_slug(labels.get("pn.slug") or name)
    if not slug:
        return None

    # Infer health endpoint from label or first exposed HTTP port
    health_ep = labels.get("pn.health_endpoint")
    if not health_ep:
        http_ports = [443, 8443, 80, 8080, 8000, 3000, 3001, 9090, 9191, 2019]
        for p in http_ports:
            key = f"{p}/tcp"
            bindings = ports.get(key) or []
            for b in bindings:
                host_port = b.get("HostPort")
                if host_port:
                    scheme = "https" if p in (443, 8443) else "http"
                    health_ep = f"{scheme}://localhost:{host_port}/"
                    break
            if health_ep:
                break

    return {
        "source":                SOURCE_LABEL,
        "host":                  HOST_LABEL,
        "raw_name":              name,
        "raw_image":             image,
        "suggested_slug":        slug,
        "suggested_name":        labels.get("pn.name") or name,
        "suggested_description": labels.get("pn.description") or None,
        "suggested_workspace_id": None,
        "suggested_category":    labels.get("pn.category") or infer_category(image),
        "suggested_access_mode": labels.get("pn.access_mode") or "internal",
        "suggested_runtime":     "docker",
        "suggested_health_ep":   health_ep,
        "raw_data": {
            "id":     c.get("Id", "")[:12],
            "image":  image,
            "state":  state.get("Status"),
            "labels": {k: v for k, v in labels.items() if not k.startswith("org.opencontainers")},
        },
    }

def ingest(candidates: list[dict], token: str) -> dict:
    payload = json.dumps({"candidates": candidates}).encode()
    req     = urllib.request.Request(
        INGEST_URL,
        data    = payload,
        headers = {
            "Content-Type":  "application/json",
            "Authorization": f"Bearer {token}",
        },
        method  = "POST",
    )
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
        print("[docker-agent] ERROR: no agent token configured", file=sys.stderr)
        sys.exit(1)

    try:
        containers = get_containers()
    except RuntimeError as e:
        print(f"[docker-agent] ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    candidates = [c for c in (container_to_candidate(ct) for ct in containers) if c]
    if not candidates:
        print("[docker-agent] no running containers found")
        return

    batch_size     = 50
    total_inserted = 0
    total_skipped  = 0

    for i in range(0, len(candidates), batch_size):
        batch  = candidates[i : i + batch_size]
        result = ingest(batch, token)
        total_inserted += result.get("inserted", 0)
        total_skipped  += result.get("skipped",  0)

    print(f"[docker-agent] {HOST_LABEL}: pushed {len(candidates)} containers — inserted: {total_inserted}, skipped: {total_skipped}")

if __name__ == "__main__":
    main()
