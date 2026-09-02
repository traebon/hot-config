#!/usr/bin/env python3
"""Builds Discovery candidates for one fleet host and POSTs them to PN's ingest
endpoint. Invoked by fleet-discovery-push.sh once per host, not run directly.

Reads host facts as KEY=VALUE lines on stdin, container list as newline-delimited
JSON (docker ps --format '{{json .}}' output, unmodified) via the DOCKER_JSON env
var, and PN_TOKEN/PN_INGEST_URL/HOST_NAME/RUNTIME_TYPE via env vars. See
fleet-discovery-push.sh's header comment for why suggested_slug is host-qualified
and suggested_runtime is always "external" for docker-sourced candidates.
"""
import json
import os
import re
import sys
import urllib.request


def slugify(s):
    return re.sub(r"^-|-$", "", re.sub(r"[^a-z0-9]+", "-", s.lower()))


def parse_labels(labels_str):
    """docker ps --format json's Labels field is a flat "k=v,k2=v2" string, not
    a real object — a value containing a literal comma will split wrong, a known
    limitation of this format, not worth a real Docker API call just to avoid.
    """
    labels = {}
    for pair in (labels_str or "").split(","):
        if "=" in pair:
            k, _, v = pair.partition("=")
            if k:
                labels[k] = v
    return labels


def describe(labels, image):
    """Best-effort suggested_description from what docker ps actually exposes —
    was previously always None (completeness_score's -15 for missing description,
    on top of -10 for the labels that were being collected into raw_data but never
    parsed). Honors PN's own pn.description label convention first, matching
    scanLocalDocker's own inference for hot-pn's local containers, so a service
    that already self-describes gets the same result whether it's discovered
    locally or pushed here from another host.
    """
    if labels.get("pn.description"):
        return labels["pn.description"]
    project = labels.get("com.docker.compose.project")
    service = labels.get("com.docker.compose.service")
    if project and service:
        return f"Compose service '{service}' in project '{project}' ({image})"
    return f"Docker container running {image}" if image else None


def main():
    facts = {}
    for line in sys.stdin:
        if "=" in line:
            k, _, v = line.rstrip("\n").partition("=")
            facts[k] = v

    host = os.environ["HOST_NAME"]
    runtime_type = os.environ.get("RUNTIME_TYPE", "vps")
    token = os.environ["PN_TOKEN"]
    ingest_url = os.environ["PN_INGEST_URL"]
    docker_raw = os.environ.get("DOCKER_JSON", "")

    host_candidate = {
        "source": "system_info",
        "host": host,
        "raw_name": host,
        "suggested_slug": slugify(host),
        "suggested_name": f"{host} (House of Trae fleet)",
        "suggested_description": (
            "Fleet host, pushed by the Gateway's fleet-discovery-push "
            "(consolidated, not this host's own agent) — see "
            "docs/HoT_Automation_Self_Healing_Scope.md Option B2."
        ),
        "suggested_category": "infra",
        "suggested_access_mode": "vpn_only",
        "suggested_runtime": runtime_type,
        "suggested_health_ep": None,
        "raw_data": {
            "os": facts.get("OS_PRETTY"),
            "kernel": facts.get("KERNEL"),
            "uptime": facts.get("UPTIME_H"),
            "cpu_cores": facts.get("CPU_CORES"),
            "mem_total_mb": facts.get("MEM_TOTAL_MB"),
            "mem_used_mb": facts.get("MEM_USED_MB"),
            "disk_total": facts.get("DISK_TOTAL"),
            "disk_used": facts.get("DISK_USED"),
            "disk_pct": facts.get("DISK_PCT"),
        },
    }

    # Matches discovery-agent.sh's own exclusion — a container that's always
    # ephemeral one-shot tooling, never a real long-running service.
    EPHEMERAL_PROBE_IMAGE_PREFIXES = ("curlimages/curl",)

    candidates = [host_candidate]
    for line in docker_raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            c = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = c.get("Names", "")
        if not name:
            continue
        image = c.get("Image", "")
        if image.startswith(EPHEMERAL_PROBE_IMAGE_PREFIXES):
            continue
        labels = parse_labels(c.get("Labels"))
        candidates.append({
            "source": "docker",
            "host": host,
            "raw_name": name,
            "raw_image": image,
            "suggested_slug": f"{host}-{slugify(name)}",
            "suggested_name": labels.get("pn.name") or f"{name} ({host})",
            "suggested_description": describe(labels, image),
            "suggested_category": labels.get("pn.category") or "app",
            "suggested_access_mode": "internal",
            "suggested_runtime": "external",  # never "docker" — see script header
            # Deliberately still None, not inferred from Ports here even though the
            # data exists — unlike scanLocalDocker's own inferHealthEndpoint (which
            # this mirrors for description/category above), a URL built from this
            # container's own network/port has no guarantee PN's backend on hot-pn
            # can actually route to it; every real cross-host reach in this project
            # is a narrowly UFW-scoped exception, not a blanket allow. Synthesizing
            # an endpoint PN can't reach would be actively misleading for a human
            # reviewer, not just incomplete. Real fix here is a routing decision,
            # not a metadata one — matching "external" runtime's whole point (PN
            # can see this, not act on it).
            "suggested_health_ep": None,
            "raw_data": {
                "status": c.get("Status"),
                "ports": c.get("Ports"),
                "created_at": c.get("CreatedAt"),
                "source_host": host,
                "labels": labels,
            },
        })

    payload = json.dumps({"candidates": candidates}).encode()
    req = urllib.request.Request(
        ingest_url,
        data=payload,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            print(resp.read().decode())
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
