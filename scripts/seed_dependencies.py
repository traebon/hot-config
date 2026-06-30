#!/usr/bin/env python3
"""
seed_dependencies.py — seeds HoT estate service dependency graph into PrivateNexus.
Run on pn-test as root.  Idempotent (POST uses ON CONFLICT DO UPDATE).
"""
import json, urllib.request, urllib.error, ssl, sys

API_BASE = "http://127.0.0.1:3001"
SLUG_TO_ID = {
    "ntfy-house-of-trae-com": "1992475d-6073-4ace-8a8b-ac7d4bf8ba7a",
    "erpnext":                 "8eaf8520-ca6d-4f47-97f7-b1b2ce397d28",
    "caddy":                   "0ff37777-8a28-4ec6-b427-d831f8896995",
    "crowdsec":                "73b5e541-953a-405a-a226-e04c9b56ee80",
    "docker-mailserver":       "ec20c593-a5be-4218-9fb5-afac59b4c198",
    "forgejo":                 "c159fb2d-c924-49e4-94d2-02cf93bac6f7",
    "forgejo-runner":          "0300f9a1-6c24-4462-9c37-9c4b10dfaba1",
    "keycloak":                "38816bb0-7413-4105-b196-c3f2a16406f8",
    "namevault":               "7e5fc2dd-40cc-4243-a802-8bc57bed6760",
    "powerdns":                "2812c0a1-f5b7-43a3-9bb0-eed100f2babb",
    "powerdns-admin":          "78988419-d194-4bb5-8c28-501b42e8a091",
    "privatenexus":            "f869cf09-e0aa-44bb-9ebc-13ed5986b36f",
    "privatenexus-staging":    "668b31f3-65b7-4e7f-b24a-7c429a5b1c3a",
    "proxmox":                 "4df7b3c1-7ebe-4a77-8cf6-64341b89ce4a",
    "roundcube":               "2cddf7e8-4ab1-416d-8fc4-e19f074f3103",
    "unbound":                 "f70ceab2-6a73-4160-a627-7cd6a43290e3",
    "wazuh":                   "27304ca8-b709-4266-8947-7a3c81409bb3",
    "wireguard":               "d5ccdb09-093d-4da6-b12e-26a2dc184fb3",
    "grafana":                 "7a1c41dd-cc33-46fa-8085-62c51211fc0f",
    "loki":                    "27ce82b0-9f57-4297-b5d1-5c01857b41a2",
    "prometheus":              "95b9cf69-7290-4b9d-98a8-b73252e57ea4",
    "uptime-kuma":             "17c7c1d1-ce9d-4c0e-b6e8-bb73e26e35ca",
}

# (upstream, downstream, dep_type, notes)
EDGES = [
    # ── Infrastructure / hosting layer ───────────────────────────────────────
    ("wireguard",      "proxmox",             "network", "Bare metal only reachable via WireGuard tunnel from Gateway VPS"),
    ("proxmox",        "forgejo",             "hard",    "Forgejo runs on sn-infra VM (VLAN 10)"),
    ("proxmox",        "powerdns-admin",      "hard",    "PowerDNS-Admin runs on sn-infra VM (VLAN 10)"),
    ("proxmox",        "namevault",           "hard",    "Namevault runs on sn-infra VM (VLAN 10)"),
    ("proxmox",        "ntfy-house-of-trae-com", "hard", "Ntfy runs on sn-infra VM (VLAN 10)"),
    ("proxmox",        "erpnext",             "hard",    "ERPNext runs on sn-business VM (VLAN 20)"),
    ("proxmox",        "grafana",             "hard",    "Grafana runs on sn-monitor VM (VLAN 50)"),
    ("proxmox",        "prometheus",          "hard",    "Prometheus runs on sn-monitor VM (VLAN 50)"),
    ("proxmox",        "loki",                "hard",    "Loki runs on sn-monitor VM (VLAN 50)"),
    ("proxmox",        "uptime-kuma",         "hard",    "Uptime Kuma runs on sn-monitor VM (VLAN 50)"),
    ("proxmox",        "privatenexus",        "hard",    "PrivateNexus runs on pn-test VM (VLAN 60)"),
    ("proxmox",        "privatenexus-staging","hard",    "PN staging runs on pn-test VM (VLAN 60)"),
    ("proxmox",        "wazuh",               "hard",    "Wazuh SIEM runs on sn-security VM (VLAN 70)"),
    ("proxmox",        "forgejo-runner",      "hard",    "Forgejo Runner runs on sn-security VM (VLAN 70)"),
    # ── DNS layer ────────────────────────────────────────────────────────────
    ("powerdns",       "unbound",             "hard",    "Unbound is the recursive resolver; PowerDNS is authoritative"),
    ("powerdns",       "caddy",               "hard",    "Caddy uses PowerDNS API (port 8081) for ACME DNS-01 challenges"),
    ("powerdns",       "docker-mailserver",   "hard",    "Mailserver MX, SPF, DKIM, DMARC records all in PowerDNS"),
    ("powerdns",       "keycloak",            "hard",    "Keycloak TLS cert provisioned via acme_dns + PowerDNS API"),
    ("powerdns",       "powerdns-admin",      "hard",    "PowerDNS-Admin manages and depends on the PowerDNS instance"),
    # ── Gateway reverse proxy ────────────────────────────────────────────────
    ("caddy",          "crowdsec",            "hard",    "CrowdSec runs as Caddy forward-auth bouncer; Caddy calls LAPI on each request"),
    # ── Identity / SSO ───────────────────────────────────────────────────────
    ("keycloak",       "forgejo",             "auth",    "Forgejo OIDC SSO via securenexus realm"),
    ("keycloak",       "powerdns-admin",      "auth",    "PowerDNS-Admin OIDC SSO via securenexus realm"),
    ("keycloak",       "grafana",             "auth",    "Grafana OIDC SSO via securenexus realm"),
    ("keycloak",       "privatenexus",        "auth",    "PrivateNexus OIDC identity provider via privatenexus realm"),
    ("keycloak",       "privatenexus-staging","auth",    "PN staging OIDC identity provider via privatenexus realm"),
    # ── Internal DNS resolver ────────────────────────────────────────────────
    ("unbound",        "keycloak",            "soft",    "Keycloak uses Unbound for internal DNS resolution"),
    # ── Mail ─────────────────────────────────────────────────────────────────
    ("docker-mailserver", "roundcube",        "hard",    "Roundcube webmail uses Docker Mailserver IMAP/SMTP"),
    ("docker-mailserver", "keycloak",         "soft",    "Keycloak sends verification/notification emails via Docker Mailserver"),
    # ── Monitoring ───────────────────────────────────────────────────────────
    ("prometheus",     "grafana",             "data",    "Grafana primary data source is Prometheus"),
    ("loki",           "grafana",             "data",    "Grafana log data source is Loki"),
    # ── CI/CD ────────────────────────────────────────────────────────────────
    ("forgejo",        "forgejo-runner",      "hard",    "Forgejo Runner is a Forgejo Actions CI/CD runner"),
    ("forgejo",        "privatenexus",        "data",    "PrivateNexus codebase hosted on Forgejo; CI/CD pipelines run here"),
    ("forgejo",        "privatenexus-staging","data",    "PN staging CI/CD pipelines run on Forgejo"),
]

def get_mcp_token():
    import subprocess
    return subprocess.check_output(
        ["docker", "exec", "privatenexus-backend", "cat", "/run/secrets/mcp_token"],
        text=True
    ).strip()

def create_dep(token, upstream_id, downstream_id, dep_type, notes):
    payload = json.dumps({
        "upstream_id":   upstream_id,
        "downstream_id": downstream_id,
        "dep_type":      dep_type,
        "notes":         notes,
    }).encode()
    req = urllib.request.Request(
        f"{API_BASE}/api/dependencies",
        data=payload,
        headers={"Content-Type": "application/json", "x-mcp-internal": token},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()), None
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {e.read().decode()}"

def main():
    token = get_mcp_token()
    print(f"Seeding {len(EDGES)} dependency edges...")
    ok = err = 0
    for upstream_slug, downstream_slug, dep_type, notes in EDGES:
        uid = SLUG_TO_ID.get(upstream_slug)
        did = SLUG_TO_ID.get(downstream_slug)
        if not uid or not did:
            print(f"  SKIP  {upstream_slug} → {downstream_slug} (slug not found)")
            continue
        result, error = create_dep(token, uid, did, dep_type, notes)
        if error:
            print(f"  ERROR {upstream_slug} → {downstream_slug}: {error}")
            err += 1
        else:
            dep = result.get("dependency", {})
            print(f"  OK    {upstream_slug:25} → {downstream_slug:25} [{dep_type}]")
            ok += 1
    print(f"\nDone — {ok} created/updated, {err} errors")

if __name__ == "__main__":
    main()
