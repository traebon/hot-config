## New VM Clone Checklist

1. Set UFW input policy to ACCEPT (template defaults to DROP)
2. Correct /etc/resolv.conf nameserver
3. Apply UFW rule: allow from 10.10.0.0/16
4. If new VLAN: update WireGuard AllowedIPs on Gateway VPS AND bare metal; wg-quick down/up
5. Add new VM alias to /root/.ssh/config on this Gateway
6. Install qemu-guest-agent (`apt-get install -y qemu-guest-agent && systemctl start qemu-guest-agent`); confirm `agent: enabled=1` in the VM's Proxmox config and verify from host with `qm agent <id> ping` — without it `qm reboot`/`qm shutdown` time out and need a forced power-cycle
7. Install node-exporter and Promtail, configure to ship to 10.10.50.104:3100
8. Add to Prometheus scrape targets on sn-monitor
9. Add to Uptime Kuma monitors
10. Add Watchtower v1.5.3 on the new VM
11. Install Tailscale for admin-access redundancy (`curl -fsSL https://tailscale.com/install.sh | sh`, then `tailscale up --hostname=<vm-name>`) — **missed entirely during the 2026-07-27 hot-bm-nl 4-VM rebuild** (sn-infra/sn-web/sn-monitor/sn-security all went 3 days with no Tailscale at all, fixed 2026-07-30, see fleet_health_check/tailscale memory). If the same hostname was previously registered by a now-dead VM, delete the stale device first (`api.tailscale.com/api/v2/device/<id>`, DELETE) to avoid a `-1` suffix on the new registration.

---

## New Service Deployment Checklist

1.  Check RAM and disk headroom on target VM before proceeding
2.  Verify image is Zen1/cpuv1 compatible if running on bare metal VMs
3.  Create /opt/stacks/<service>/docker-compose.yml
4.  Use Docker secrets for all credentials (chmod 644 secret files)
5.  Add Caddy block in /opt/stacks/caddy/Caddyfile
6.  Add PowerDNS A record (via API or PowerDNS-Admin)
7.  Reload Caddy: cd /opt/stacks/caddy && docker compose restart caddy
8.  Add UFW rule: allow from 10.10.0.0/16 to any port <service-port>
9.  Verify TLS certificate provisioned
10. Add to Uptime Kuma monitors
11. Add Prometheus scrape target if service exposes metrics
12. Configure SMTP (notifications@house-of-trae.com) if service sends notifications
13. **SSO is default, not optional.** Gate the app behind Keycloak: if the app has a native OIDC option, wire it to the appropriate realm directly; otherwise `import sso` in its Caddy block (see below) to gate it with the shared oauth2-proxy instance. Only skip this for services that can't sensibly support a browser login gate (e.g. raw SMTP/IMAP ports, API-only backends called machine-to-machine) — note the exception inline in the Caddy block if so.

### SSO via oauth2-proxy (default pattern for new web apps)

Gateway runs a shared `oauth2-proxy` (`/opt/stacks/oauth2-proxy/`) as an OIDC client (`oauth2-proxy` in the `securenexus` Keycloak realm), configured with **two** `--cookie-domain` flags (`.house-of-trae.com` and `.securenexus.net` — oauth2-proxy picks whichever matches the requesting host) and a fixed `--redirect-url=https://ds.house-of-trae.com/oauth2/callback` (must stay the sole Keycloak-registered redirect URI regardless of which app initiated login — oauth2-proxy carries the original app URL through the OAuth `state` param and 302s back to it after auth).

The Caddyfile has an `(sso)` snippet (global snippets section) that wires this up correctly — including the path-matcher fix needed so `/oauth2/*` callback requests don't get caught by their own auth check (`forward_auth` has no path scoping by default, so without a `not path /oauth2/*` matcher it loops on itself). To gate a new app, just add `import sso` alongside `import crowdsec` in its site block:
```
newapp.house-of-trae.com {
    import crowdsec
    import compress
    import sso
    reverse_proxy newapp:PORT
}
```
First deployed for `webmail.house-of-trae.com` (Roundcube) — Roundcube's own IMAP/SMTP login still runs after the gate (this is a pre-auth wall using centralized identity, not a skip-login IMAP OAUTH2 integration). True passwordless SSO into Roundcube would require enabling Docker Mailserver's OAUTH2/XOAUTH2 support against Keycloak plus the Roundcube `oauth2` plugin — bigger scope, not yet done, evaluate only if the pre-auth wall proves insufficient.

**⚠ `import sso` only works for apps under `house-of-trae.com` itself — found+fixed 2026-08-09.**
Despite `--cookie-domain` covering both `.house-of-trae.com` and `.securenexus.net`, the SSO gate is
structurally broken for any `securenexus.net` app: the CSRF cookie set during `/oauth2/start` is
scoped to whichever domain initiated the request (correct, dynamic per-host behavior), but the
callback always completes at the single fixed `ds.house-of-trae.com` URL above — a
`.securenexus.net`-scoped cookie can never be sent to a `house-of-trae.com` request, so the callback
can never find it. Real, reproducible symptom: "Login Failed: Unable to find a valid CSRF token."
every single time, not fixable by clearing cookies/retrying. Confirmed live on the old
`monitor.securenexus.net`. **Real fix applied: moved both affected apps off `securenexus.net`
entirely** — `monitor.securenexus.net` → **`monitor.house-of-trae.com`**,
`prometheus.securenexus.net` → **`prometheus.house-of-trae.com`** (new `A` records via PowerDNS,
`import sso` restored and verified actually working — `Set-Cookie` now shows
`Domain=house-of-trae.com`, matching the callback). Old `securenexus.net` URLs kept as permanent
301 redirects to the new ones, matching the existing `mail.house-of-trae.com` →
`webmail.house-of-trae.com` pattern. An IP-allowlist workaround (matching
`gatus.securenexus.net`/`rspamd.securenexus.net`'s pattern) was applied first, then superseded by
this domain move the same day — see `caddy_sso_domain_mismatch_2026_08_09` memory for the full
history. **Before adding `import sso` to any future site block, confirm the domain is under
`house-of-trae.com`** — if not, either put it there or use IP allowlisting instead, or this bug
recurs.

---

