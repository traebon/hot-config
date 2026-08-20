#!/usr/bin/env python3
"""
Compares each hot-pn PrivateNexus Catalogue-deployed stack's live container port
bindings against the port bindings actually approved via the propose -> review ->
approve governance flow (action_requests.params.generated_compose, most recent
status='executed' row per slug). Prints one line per service with a mismatch:

  slug|container_name|approved_host_ip:approved_host_port|live_host_ip:live_host_port

Either side prints as "NONE" if that container has no published binding there -- on the
approved side, "NONE" means the compose never gave it a `ports:` entry at all (meant to
stay internal-only); on the live side, it means the container currently isn't published
anywhere. Prints nothing if everything matches.

Deliberately a regex-based compose parser, not a real YAML parser -- these templates
are hand-authored (see app/backend/src/catalogue/templates/) and consistently
2-space-indented with at most one `ports:` entry per service; this matches the same
level of parsing rigor the executor itself applies to port strings
(routes/actions.js's portBindingsFor()), not general YAML compliance.

Scoped in docs/HoT_Automation_Self_Healing_Scope.md Section 8 (2026-08-20) after
hot-pn's `nextcloud` container was found silently rebound outside the governance flow
entirely -- see pn_nextcloud_binding_and_personal_cleanup_2026_08_20 memory.

Run locally on hot-pn (invoked over SSH by the Gateway's fleet-health-sweep.sh).
"""
import subprocess
import json
import re

# json_agg, not a raw text/base64 column -- Postgres's encode(...,'base64') inserts a line
# break every 76 chars, which silently truncated every compose blob when read line-by-line
# (found live, first test run 2026-08-20: every slug came back with zero approved bindings).
# JSON output escapes embedded newlines as "\n" instead of emitting them raw, so the whole
# result set round-trips as ordinary JSON with no row-boundary ambiguity.
SQL = (
    "SELECT json_agg(x) FROM ("
    "  SELECT DISTINCT ON (slug) slug, gc AS generated_compose"
    "  FROM ("
    "    SELECT params->>'slug' AS slug, params->>'generated_compose' AS gc, executed_at"
    "    FROM action_requests"
    "    WHERE action_type='service.provision_from_catalogue' AND status='executed'"
    "  ) t ORDER BY slug, executed_at DESC"
    ") x;"
)


def run(cmd_list):
    return subprocess.run(cmd_list, capture_output=True, text=True).stdout


def approved_bindings(compose_text):
    """container_name -> 'host_ip:host_port', or None if the approved compose never gave that
    service a `ports:` entry at all (i.e. it was meant to stay internal-only, unpublished).

    Every container_name in the compose is a key -- not just ones with a declared port -- so a
    service that goes from "no ports:" to actually being published later is caught too. This is
    the more severe half of what this check exists for: found live 2026-08-20 on hot-pn's
    notesnook stack, `notesnook-s3`/`notesnook-identity`/`notesnook-sse` are all published to
    10.10.2.2 on their container-native ports despite having no `ports:` line in the approved
    compose at all -- a strictly-narrower `approved_bindings()` that only tracked services with a
    declared port would have missed all three.
    """
    bindings = {}
    current = None
    in_ports = False
    for raw in compose_text.splitlines():
        m = re.match(r"^\s*container_name:\s*(\S+)", raw)
        if m:
            current = m.group(1)
            bindings.setdefault(current, None)
            in_ports = False
            continue
        if re.match(r"^\s*ports:\s*$", raw):
            in_ports = True
            continue
        if in_ports:
            pm = re.match(r'^\s*-\s*"([^"]+)"', raw)
            if pm and current:
                parts = pm.group(1).split(":")
                bindings[current] = ":".join(parts[:-1])
            in_ports = False
    return bindings


def live_binding(container_name):
    out = run(
        [
            "docker",
            "inspect",
            container_name,
            "--format",
            "{{range $p,$b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}:{{.HostPort}}{{end}}{{end}}",
        ]
    ).strip()
    return out or None


def main():
    raw = run(
        [
            "docker",
            "exec",
            "privatenexus-db",
            "psql",
            "-U",
            "privatenexus",
            "-d",
            "privatenexus",
            "-t",
            "-A",
            "-c",
            SQL,
        ]
    ).strip()
    rows = json.loads(raw) if raw and raw != "null" else []
    for row in rows:
        slug = row["slug"]
        compose_text = row["generated_compose"] or ""
        for container, approved in approved_bindings(compose_text).items():
            live = live_binding(container)
            if approved != live:
                print(f"{slug}|{container}|{approved or 'NONE'}|{live or 'NONE'}")


if __name__ == "__main__":
    main()
