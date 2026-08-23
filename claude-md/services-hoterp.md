### hot-erp (ssh hot-erp-nl — Hostkey NL, server 41614, public VPS, not a Proxmox VM) — PERMANENT
**Migrated 2026-08-01 from Hostinger (46.202.129.86, the original `hot-erp`/`erp-temp` box, item 26
in [[open_items_2026_07_27]]) to a fresh Hostkey NL `vm.v2-nano` (2 vCPU / 4 GB RAM / 60 GB NVMe,
$7.74/mo).** CH was found to be blocked for new `vm.v2-*` orders at migration time (confirmed live
against the invapi — `vm.v2-nano`/`-mini`/`-medium` all rejected for CH even though hot-pn's
existing `vm.v2-medium` CH rental keeps renewing fine), so this landed in NL instead, same region
as hot-bm-nl — see [[hot_erp_hostkey_ch_migration_scope]] for the full ordering investigation.
Reached from the Gateway VPS over the dedicated `wg5` tunnel (10.10.4.1 ↔ 10.10.4.2, port 51825).
Public SSH closed (UFW deny-by-default, matching the hot-pn pattern) — admin access is tunnel-only.
The old Hostinger box had been retained running as a safety net, no longer receiving traffic.
**Mr. Byrne confirmed 2026-08-03 the Hostinger account is set to close** — the now-redundant `wg2`
tunnel to it was torn down the same day (`wg-quick down wg2` + `systemctl disable wg-quick@wg2`,
see Network Topology above), and its `hot-erp`/`erp-temp` SSH aliases were removed from
`/root/.ssh/config` the same day. The account itself is in the process of being cancelled on
Hostinger's side.

Data migration: real DB (`mysqldump` of the site's own DB user, not a full-instance dump — the
MariaDB root password on the old box had drifted from what's in its own secrets file, a real,
still-unresolved discrepancy worth investigating separately) + `sites-data`/`assets-data` volume
rsync while the old box stayed live, re-synced immediately before cutover to minimize staleness.
Verified via matching table/row counts (747 tables, 35 Items, 6 Users, identical on both boxes) and
a real `frappe.db.count` query post-migration, not just a file-copy assumption.

**Original 2026-07-06/07-09 history (Hostinger box, now superseded but kept for context):** stood
up as a stand-in for sn-business's ERPNext while the original bare-metal host was down (see
[[hostkey_server_replacement]]); historical data restored 2026-07-09 from the 2026-06-29 Hetzner
vzdump backup (see [[rclone_crypt_password_vaultwarden]]); made ERPNext's permanent home (off bare
metal entirely, deliberately, same reasoning as the Vaultwarden Gateway placement) 2026-07-24.
Earmarked later (no timeline) to also host client companies' backend software — not started.

| Service     | Path                | Notes                                                          |
|-------------|---------------------|------------------------------------------------------------------|
| ERPNext v16 | /opt/stacks/dickson/ | erp.dickson-supplies.com (Caddy repointed to `10.10.4.2:8000` 2026-08-01). Config synced to `/opt/hot-config/hot-erp/dickson/` (README there has full rebuild notes/gotchas — reconstructed Dockerfile, posawesome source, several one-time setup steps never captured in docker-compose.yml originally; still accurate post-migration since the volume/DB content was migrated as-is, not rebuilt from scratch). |
| node-exporter | /opt/stacks/node-exporter/ | Deployed 2026-08-08 (was previously the one host with zero memory/host metrics — investigating an SMS alert storm surfaced this gap, see `sms_alert_storm_investigation_2026_08_08` memory). Standard host-network compose, port 9100, not exposed publicly (no UFW rule). |
| Prometheus (local) | /opt/stacks/prometheus-local/ | Deployed 2026-08-08, same day as node-exporter — a self-contained local stand-in, same pattern as hot-pn's `monitoring-temp`, **deliberately not wired into sn-monitor's central Prometheus**: hot-erp-nl sits behind its own `wg5` tunnel with no routing to sn-monitor's `wg4`/VLAN mesh (confirmed live: neither host can ping the other), and bridging that would connect two currently-isolated trust zones (a public-facing VPS and the host running all 4 production VMs incl. Wazuh) just for monitoring — decided against that. Runs on `network_mode: host` (a bridge-network + `host.docker.internal` setup was tried first and hung — the special hostname resolved to the *default* docker0 bridge gateway, not this stack's own custom-network gateway, so scrapes had no route; host networking sidesteps the whole class of issue) with Prometheus's own listener pinned to `--web.listen-address=127.0.0.1:9090`, so it's not network-reachable even locally. 15d retention, matching hot-pn. Query via `ssh hot-erp-nl curl localhost:9090/api/v1/query?query=...` — no Grafana front-end, this is API-only like hot-pn's. |

Caddy's `erp.dickson-supplies.com` block (and the Tor onion mirror block) both point at
`10.10.4.2:8000` as of the 2026-08-01 cutover — verified live via a real public HTTPS request
(`frappe.ping` → `pong`) and a local Host-header test against the onion block's site key itself
(`Host: <onion-address>`, not the public domain — the two are separate Caddy site blocks and using
the wrong Host header silently hits the other one), confirmed `200`/`pong`.

**Re-checked 2026-08-03, correcting a prior mischaracterization:** a direct SOCKS5 request through
the Gateway's own local Tor proxy (`127.0.0.1:9050`) to the onion address fails with `curl: (97)`,
and the Tor daemon's own logs show why: `"Fail to decrypt descriptor for requested onion address.
It is likely requiring client authorization."` This was previously logged as the test being
"uncompletable — egress-restricted, not a config problem" — that diagnosis was wrong. The request
genuinely reaches Tor and gets a real protocol-level response; it fails only because this session
doesn't hold the client-auth private key (`authorized_clients/tristian.auth` is pubkey-only, see
the Tor Hidden Services section above) — the service is correctly refusing to decrypt its
descriptor for an unauthorized client, which is the access-control feature working as designed, not
a sandbox/network limitation. Separately, the Tor daemon itself is confirmed healthy: bootstrapped
100%, 15-23 circuits open continuously, and its heartbeat logs show real `INTRODUCE2` cells being
received periodically — i.e., genuine inbound requests are reaching the hidden service from the
live Tor network.

**Not yet done, follow-up needed:** investigate why the old box's MariaDB root password no longer
matched its own secrets file (worked around via the site's own DB user, not blocking, and likely
moot now the box is being decommissioned). Root password + wg5 keys were already saved to
Vaultwarden 2026-08-01 ("hot-erp-nl root password (Hostkey NL VPS)" / "hot-erp-nl wg5 WireGuard
tunnel keys", House of Trae — Gateway VPS folder) — verified still present 2026-08-03. Hostinger
account cancellation confirmed by Mr. Byrne 2026-08-03 — see the note above and Network Topology's
wg2 entry.

---

