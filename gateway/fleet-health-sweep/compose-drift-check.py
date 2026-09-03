#!/usr/bin/env python3
"""
Fleet-wide compose-vs-live port-binding drift check — every /opt/stacks/<service> on
this host, not just hot-pn's Catalogue-governed deploys (that's catalogue-drift-check.py,
a separate, streak-based check — see its own docstring for why the two are deliberately
different report types).

Scoped in docs/HoT_Automation_Self_Healing_Scope.md Section 9 (2026-08-20), built
2026-08-25. Reuses compose-service-names.py (already deployed to every STACK_HOST) for
the container-name-resolution piece rather than re-parsing compose files itself — that
script already solves the real problem found in Wazuh (zero declared `container_name:`
across all 3 services) via Docker's own com.docker.compose.project/.service labels as
ground truth, no naming-scheme guesswork.

For every stack directory with a compose file, for every service compose-service-names.py
resolves to a live container, compares the container's real `docker inspect`
HostConfig.PortBindings against what the compose file on disk declares. Prints one line
per mismatched container_port/proto:

  stack|service|container_name|container_port/proto|declared_host_ip:host_port|live_host_ip:host_port

Either side prints as NONE if that port has no binding there — on the declared side,
NONE means the compose file's `ports:` block never mentions that container port at all;
on the live side, NONE means nothing is actually published for it right now. The NONE-
on-declared/real-binding-on-live case is the more severe direction (an internal-only
service quietly published) — this is exactly the shape of drift Section 8's checker
found on hot-pn's `notesnook` stack, and there's no reason to expect it's confined to
hot-pn. Prints nothing if everything matches.

Deliberately only compares ports:/PortBindings — never touches `environment:` or
`docker inspect`'s Config.Env, which (unlike the compose file) holds fully-resolved real
secret values once a container is running. See Section 9's "secrets concern" note for
the full reasoning already worked out before this was built.

Run locally on each STACK_HOST (invoked over SSH by the Gateway's fleet-health-sweep.sh).
"""
import json
import subprocess
from pathlib import Path

STACKS_ROOT = Path("/opt/stacks")
NAME_RESOLVER = "/usr/local/bin/compose-service-names.py"


def run(cmd_list):
    return subprocess.run(cmd_list, capture_output=True, text=True).stdout


def parse_port_string(s):
    """'1514:1514' / '514:514/udp' / '0.0.0.0:53:53/tcp' / '127.0.0.1:28142:80'
    -> ((container_port, proto), (host_ip, host_port)), or None if unparseable."""
    proto = "tcp"
    if "/" in s:
        s, proto = s.rsplit("/", 1)
    parts = s.split(":")
    if len(parts) == 2:
        host_ip, host_port, container_port = "0.0.0.0", parts[0], parts[1]
    elif len(parts) == 3:
        host_ip, host_port, container_port = parts[0], parts[1], parts[2]
    else:
        return None
    return (container_port, proto), (host_ip, host_port)


def declared_bindings(port_strings):
    bindings = {}
    for s in port_strings:
        parsed = parse_port_string(s)
        if parsed:
            key, val = parsed
            bindings[key] = val
    return bindings


def live_bindings(container_name):
    raw = run(
        ["docker", "inspect", container_name, "--format", "{{json .HostConfig.PortBindings}}"]
    ).strip()
    if not raw or raw == "null":
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    bindings = {}
    for port_proto, entries in (data or {}).items():
        if not entries:
            continue
        container_port, _, proto = port_proto.partition("/")
        entry = entries[0]
        host_ip = entry.get("HostIp") or "0.0.0.0"
        host_port = entry.get("HostPort") or ""
        bindings[(container_port, proto or "tcp")] = (host_ip, host_port)
    return bindings


def check_stack(stack_dir: Path):
    out = run(["python3", NAME_RESOLVER, str(stack_dir)])
    if not out.strip():
        return
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            svc = json.loads(line)
        except json.JSONDecodeError:
            continue
        container = svc.get("resolved_container_name")
        if not container:
            continue  # stack not running / project-name mismatch -- nothing live to compare
        declared = declared_bindings(svc.get("ports") or [])
        live = live_bindings(container)
        for key in set(declared) | set(live):
            d = declared.get(key)
            live_binding = live.get(key)
            if d != live_binding:
                cport, proto = key
                d_str = f"{d[0]}:{d[1]}" if d else "NONE"
                l_str = f"{live_binding[0]}:{live_binding[1]}" if live_binding else "NONE"
                print(f"{stack_dir.name}|{svc['service']}|{container}|{cport}/{proto}|{d_str}|{l_str}")


def main():
    if not STACKS_ROOT.is_dir():
        return
    for stack_dir in sorted(STACKS_ROOT.iterdir()):
        if stack_dir.is_dir():
            check_stack(stack_dir)


if __name__ == "__main__":
    main()
