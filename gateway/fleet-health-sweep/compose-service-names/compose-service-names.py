#!/usr/bin/env python3
"""
Resolves every service in a plain `docker compose`-deployed stack to its real, live
container name -- whether the compose file declares `container_name:` explicitly or
relies on Compose's own default naming.

Built 2026-08-20 as the missing piece for docs/HoT_Automation_Self_Healing_Scope.md
Section 9 (fleet-wide compose-vs-live drift check): a container-name-keyed parser (the
approach that works fine for hot-pn's Catalogue templates, which always set
`container_name:`) has ZERO coverage of any stack that doesn't -- confirmed live: Wazuh
on sn-security declares no `container_name:` across all 3 of its services
(wazuh.manager/wazuh.indexer/wazuh.dashboard), so a naive parser would silently skip
Wazuh entirely.

Rather than reimplementing Compose's default-naming algorithm (`<project>-<service>-<n>`,
with Compose's own directory-name sanitization rules), this asks the Docker daemon
directly: every container `docker compose` creates carries `com.docker.compose.project`
and `com.docker.compose.service` labels regardless of whether `container_name:` was set.
Matching on those labels is ground truth and needs no naming-scheme guesswork -- it works
identically whether a service is explicitly named or not, so there's really only one code
path here, not a "normal case + a fallback."

Usage: compose-service-names.py /opt/stacks/<service>
Output: one JSON object per line to stdout, one line per service key found in the
compose file's `services:` block:
  {"service": "wazuh.manager", "declared_container_name": null,
   "resolved_container_name": "wazuh-wazuh.manager-1", "source": "compose-default",
   "ports": ["1514:1514", "1515:1515", "514:514/udp", "55000:55000"]}
`resolved_container_name` is null if no live container matches -- the stack may be
stopped, or the compose project label may not match the directory name (rare, only if
someone deployed with an explicit `-p <name>` overriding Compose's default project
naming; flagged via `source: "no-live-match"` rather than silently guessed).
"""
import json
import re
import subprocess
import sys
from pathlib import Path

COMPOSE_FILENAMES = ["docker-compose.yml", "compose.yml", "compose.yaml"]


def run(cmd_list):
    return subprocess.run(cmd_list, capture_output=True, text=True).stdout


def find_compose_file(stack_dir: Path):
    for name in COMPOSE_FILENAMES:
        candidate = stack_dir / name
        if candidate.is_file():
            return candidate
    return None


def parse_services(compose_text):
    """Returns {service_key: {"container_name": str|None, "ports": [str, ...]}},
    scoped strictly to the `services:` top-level block -- stops at the next
    0-indent top-level key (volumes:/networks:/etc.), since a top-level `volumes:`
    block can itself contain 2-space-indented keys that look identical to a service
    key at a glance (found live: wazuh/docker-compose.yml has 13 top-level volume
    names sitting right after its 3 real services, same indent level)."""
    services = {}
    in_services = False
    current = None
    in_ports = False
    for raw in compose_text.splitlines():
        if re.match(r"^services:\s*$", raw):
            in_services = True
            continue
        if in_services and re.match(r"^[A-Za-z]", raw):
            # a new 0-indent top-level key (volumes:, networks:, ...) ends the block
            break
        if not in_services:
            continue
        m = re.match(r"^  ([A-Za-z0-9_.-]+):\s*$", raw)
        if m:
            current = m.group(1)
            services[current] = {"container_name": None, "ports": []}
            in_ports = False
            continue
        if current is None:
            continue
        cn = re.match(r"^\s*container_name:\s*(\S+)", raw)
        if cn:
            services[current]["container_name"] = cn.group(1)
            continue
        if re.match(r"^\s*ports:\s*$", raw):
            in_ports = True
            continue
        if in_ports:
            # Port list items are valid YAML either quoted ("443:5601") or bare (443:5601) --
            # found live 2026-08-25: Wazuh's own compose file uses the bare form throughout,
            # which the quote-only version of this regex silently skipped entirely, making
            # every one of its ports look undeclared. Strip optional matching quotes either way.
            #
            # Also strip trailing inline comments before matching -- found live the same day,
            # once tested against the wider fleet: caddy/mailserver/unbound/pdns-admin all
            # annotate their port lines ("0.0.0.0:443:443/udp # HTTP/3 QUIC" etc.), and an
            # end-of-line anchor without this strip silently drops every commented port line,
            # exactly the same failure shape as the quoting gap above. Port strings never
            # contain '#' themselves, so a naive split is safe here.
            no_comment = raw.split("#", 1)[0]
            pm = re.match(r"^\s*-\s*['\"]?([^'\"\s]+)['\"]?\s*$", no_comment)
            if pm:
                services[current]["ports"].append(pm.group(1))
                continue
            else:
                in_ports = False
    return services


def live_container_map(project):
    """service label -> real container name, for every container Docker itself
    attributes to this compose project -- ground truth, no naming-scheme guessing."""
    names = run(
        [
            "docker",
            "ps",
            "-a",
            "--filter",
            f"label=com.docker.compose.project={project}",
            "--format",
            "{{.Names}}",
        ]
    ).split()
    mapping = {}
    for name in names:
        service = run(
            [
                "docker",
                "inspect",
                name,
                "--format",
                '{{index .Config.Labels "com.docker.compose.service"}}',
            ]
        ).strip()
        if service:
            mapping[service] = name
    return mapping


def main():
    if len(sys.argv) != 2:
        print("usage: compose-service-names.py /opt/stacks/<service>", file=sys.stderr)
        sys.exit(2)
    stack_dir = Path(sys.argv[1])
    compose_file = find_compose_file(stack_dir)
    if compose_file is None:
        print(f"no compose file found in {stack_dir} (tried {COMPOSE_FILENAMES})", file=sys.stderr)
        sys.exit(1)

    services = parse_services(compose_file.read_text())
    project = stack_dir.name
    live = live_container_map(project)

    for service_key, info in services.items():
        declared = info["container_name"]
        live_name = live.get(service_key)
        if declared and live_name:
            source = "declared"
            resolved = live_name  # live docker inspect is still ground truth over the file
        elif live_name:
            source = "compose-default"
            resolved = live_name
        elif declared:
            source = "declared-not-running"
            resolved = None
        else:
            source = "no-live-match"
            resolved = None
        print(
            json.dumps(
                {
                    "service": service_key,
                    "declared_container_name": declared,
                    "resolved_container_name": resolved,
                    "source": source,
                    "ports": info["ports"],
                }
            )
        )


if __name__ == "__main__":
    main()
