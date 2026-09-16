## Network Topology

```
Internet
    │
    ▼
Gateway VPS — 151.241.217.91 (Hostkey B.V., Zürich)
    │  wg4 (ChaCha20-Poly1305)  10.10.3.1 → 10.10.3.2
    ▼
hot-bm-nl (Hostkey NL, server 22272, oVirt VPS — bare-metal replacement) — PVE 9.2.5
    │  VLAN routing via vmbr0 (VLAN-aware Linux bridge, no physical port — purely
    │  internal, matches the original architecture since these VLANs never touch
    │  the WAN; wg4 carries all Gateway↔VLAN traffic instead of a switch trunk)
    ├── VLAN 10 → sn-infra    (10.10.10.100) — rebuilt 2026-07-27 as VM 100 — LUKS2+Tang retrofit complete 2026-07-28
    ├── VLAN 30 → sn-web      (10.10.30.102) — rebuilt 2026-07-27 as VM 102 — LUKS2+Tang retrofit complete 2026-07-27 (pilot)
    ├── VLAN 50 → sn-monitor  (10.10.50.104) — rebuilt 2026-07-27 as VM 104 — LUKS2+Tang retrofit complete 2026-07-28
    └── VLAN 70 → sn-security (10.10.70.106) — rebuilt 2026-07-27 as VM 106 — LUKS2+Tang retrofit complete 2026-07-28 (cores=2 permanent, see sn-security section below)

    VLAN 20 (sn-business) and VLAN 40 (sn-personal) are NOT being rebuilt here — those
    roles permanently moved to hot-erp/hot-pn (see PERMANENT decision, 2026-07-24).
    VLAN 40 (sn-personal) and VLAN 60 (pn-test) are both settled: **retired outright, Mr. Byrne's
    decision** (pn-test 2026-08-03, sn-personal 2026-08-09) — no rebuild planned for either, ever.
    Any future Phase 4 "HoT Sync" work will need a different landing spot — see the sn-personal
    section below and hostkey_server_replacement memory.

    ⚠ The ORIGINAL bare-metal host (AMD EPYC 3151, Switzerland DC, server 145990) is
    PERMANENTLY DECOMMISSIONED — unfixable NIC fault, refunded, replaced by hot-bm-nl.
    Its wg0 tunnel (10.10.0.1 → 10.10.0.2) was disabled 2026-07-24 (`wg-quick down` +
    `systemctl disable wg-quick@wg0`) after its stale routes for the VLAN subnets above
    blocked wg4 from claiming them — don't re-enable it, that server no longer exists.

Tailscale overlay (admin access ONLY — never production traffic):
    Gateway VPS:         100.106.41.10
    hot-bm-nl:           100.90.156.88 (added 2026-07-27 — Proxmox web UI access, port 8006 only, UFW-scoped to the tailscale0 interface)
    sn-infra:            100.99.52.12 (re-registered 2026-07-30 — Tailscale was never installed on the
                         hot-bm-nl rebuild of this VM at all; the VM Clone Checklist never included a
                         Tailscale step. New IP, replacing the stale/dead entry left over from the
                         original decommissioned bare-metal VM.)
    sn-web:              100.91.130.53 (re-registered 2026-07-30, same gap/fix as sn-infra above)
    sn-monitor:          100.109.177.48 (re-registered 2026-07-30, same gap/fix as sn-infra above)
    sn-security:         100.118.146.83 (re-registered 2026-07-30, same gap/fix as sn-infra above)
    Ubuntu workstation:  100.116.130.37
    Windows (latitude):  100.106.225.126
    Windows (traebake):  100.127.229.35
    Tailscale suffix:    spangled-atlas.ts.net

**Removed 2026-07-30**: `sn-business` (100.83.114.127), `sn-personal` (100.118.105.9), `pn-test`
(100.64.178.97) — same class of stale dead entry as the sn-infra/sn-web/sn-monitor/sn-security ones
above (all last seen 2026-07-01, the original decommissioned bare-metal VMs), removed via the
Tailscale API once Mr. Byrne confirmed. Matches the SSH alias cleanup done the same day — see
Network Topology above and the SSH Access table for why these VLANs aren't coming back as-is.

Other WireGuard interfaces on the Gateway VPS (separate from the wg0 bare-metal tunnel above):
    wg1 — Mr. Byrne's personal road-warrior VPN. 10.10.90.0/24 (Gateway 10.10.90.1), port 51821.
          Client configs: phone/windows/laptop.conf in /root/hot/wireguard-clients/. Predates this
          doc; discovered 2026-07-06 when a new tunnel was almost given the same interface name —
          check `wg show` before reusing wg<N>/ports on this box.
    wg2 — **REMOVED 2026-08-03.** Was the tunnel to the OLD hot-erp box (Hostinger,
          46.202.129.86, formerly named erp-temp), superseded 2026-08-01 when ERPNext's real
          permanent home became hot-erp-nl over `wg5` (see below). Kept running-but-idle as a
          safety net until Mr. Byrne confirmed the Hostinger account was set to close — confirmed
          2026-08-03, so the tunnel was torn down (`wg-quick down wg2` + `systemctl disable
          wg-quick@wg2`) and the account is being cancelled. Old addressing for reference only:
          Gateway 10.10.1.1 / old hot-erp 10.10.1.2, port 51822. See
          hot_erp_hostkey_ch_migration_scope memory for the migration and the hot-erp section
          below.
    wg3 — tunnel to hot-pn (151.241.217.140, formerly named pn-vps — renamed 2026-07-24, ssh alias
          `pn-vps` still works as a transitional alias), PrivateNexus's permanent home (Mr. Byrne's personal
          use + PrivateNexus product development; ERPNext/erp-temp is earmarked for hosting client
          companies' backend software later — not started, no timeline). Originally stood up as a
          bare-metal-outage stand-in for pn-test/sn-personal; **made permanent 2026-07-24** for the
          same reason as wg2 above. Gateway 10.10.2.1 / pn-vps 10.10.2.2, port 51823. See
          hostkey_server_replacement memory and the pn-vps section below. hot-pn's own peer
          `AllowedIPs` widened 2026-08-08 to add `10.10.70.106/32` (sn-security only, for Wazuh
          agent enrollment — see the sn-security section above), widened again 2026-08-09 to add
          `10.10.3.2/32` (hot-bm-nl itself, port 8006 only, for PrivateNexus's own Proxmox health
          check — see the PN Proxmox Health Endpoint Fix note under the hot-pn section below), and
          widened again the same day to add `10.10.50.104/32` (sn-monitor — the `AllowedIPs` entry
          itself is IP-level, not port-level; actual port scoping is enforced by two separate
          Gateway `ufw route allow` forward rules, ports 9090 and 3100, plus matching sn-monitor-side
          UFW rules, so PN's Fleet widget and log viewer can reach the real central Prometheus/Loki
          instead of hot-pn's own local stand-in — see the Monitoring (temp) note under the hot-pn
          section below) — still not widened to the full VLAN mesh, each addition is narrowly scoped
          to one host and specific ports for a specific real purpose.
    wg4 — tunnel to hot-bm-nl (server 22272, Hostkey NL, 31.207.47.146) — the bare-metal
          *replacement* candidate itself (server 145990 was decommissioned; NL not CH, see
          hostkey_server_replacement memory), NOT a temporary stand-in like wg2/wg3. Gateway
          10.10.3.1 / hot-bm-nl 10.10.3.2 (interface name wg0 on that host), port 51824. Enabled
          via systemd on both ends. Fleet migration architecture is now live — see the 4-VM VLAN
          topology above. hot-bm-nl's own peer `AllowedIPs` (for this tunnel, `wg0.conf` on that
          host) widened 2026-08-08 to add `10.10.2.2/32` + `10.10.4.2/32` (hot-pn/hot-erp-nl) so it
          accepts forwarded packets carrying their real source IPs — see the Wazuh agent
          enrollment note under sn-security above for why.
    wg5 — tunnel to hot-erp-nl (server 41614, Hostkey NL, 151.243.173.46) — ERPNext's new
          permanent home as of the 2026-08-01 migration off Hostinger, see the hot-erp section
          below and hot_erp_hostkey_ch_migration_scope memory. Gateway 10.10.4.1 / hot-erp-nl
          10.10.4.2 (interface name wg0 on that host), port 51825. Enabled via systemd on both
          ends. hot-erp-nl's own peer `AllowedIPs` widened 2026-08-08, same reason/scope as wg3
          above (`10.10.70.106/32` only).
    wg6 — tunnel to `pbs` (Proxmox Backup Server, **local hardware on Mr. Byrne's own home
          network**, now `192.168.86.250/24` behind a home NAT — not a rented VPS like every other
          host in this fleet). Built 2026-08-22, dedicated WireGuard chosen deliberately over Tailscale
          for this (Mr. Byrne's call — Tailscale = admin only, nightly backup transfer is
          production traffic). PBS dials out road-warrior style (like wg1), since it has no public
          IP of its own — Gateway 10.10.5.1 / PBS 10.10.5.2, port 51826. Extended so hot-bm-nl can
          reach PBS through the Gateway as a relay (hot-bm-nl's own wg0.conf + PBS's wg6.conf
          `AllowedIPs` both widened, one narrowly-scoped `ufw route allow in on wg4 out on wg6`
          rule, port 8007 only) — same relay pattern as the Wazuh agent enrollment widening above.
          See `pbs_backup_integration_scope_2026_08_22` memory and
          `docs/HoT_PBS_Backup_Integration_Scope.md` for the full build (single-disk datastore
          risk accepted via SMART alerting rather than RAID, real pilot backup run on VM 104,
          and an unexplained pre-existing protected `vm/100` backup from 2026-02-18 still flagged
          for Mr. Byrne, not yet resolved).

          **⚠ Found dead 2026-09-04: last real handshake was 9 days, 14 hours earlier — 100%
          packet loss, entirely PBS-side** (Gateway's own wg6 interface/service confirmed healthy
          throughout, up since 22 Aug with zero errors). Real production impact: sn-web/sn-monitor/
          sn-security's nightly backups (routed to PBS since 25 Aug) all failed silently for the
          full outage — see `alerting-backups.md`'s Backup Architecture section and
          `docs/HoT_PBS_Backup_Integration_Scope.md` Section 6 for the full incident, the interim
          fix (reverted those 3 VMs' backups to `local-zfs`), and the separate mail-relay bug found
          alongside it. PBS reachability needs Mr. Byrne to check the box itself — nothing on the
          Gateway/hot-bm-nl side of this tunnel can diagnose a dead peer.

          **✅ Back 2026-09-06.** Mr. Byrne reported PBS's local address changed to
          `192.168.86.250` (was `192.168.0.35`) — a different `/24` entirely, gateway now
          `192.168.86.1`, consistent with the home router itself being replaced/reset rather than
          just a DHCP renewal, and lines up with the ~25 Aug last-handshake timing (see the 2026-09-04
          note above). Confirmed live from both ends: `wg6` handshake current on the Gateway (peer
          endpoint now `148.252.145.134:<port>` — new WAN IP too) and on PBS itself (SSH via the
          `pbs` Tailscale alias), and `pbs-hot` shows `active` again on hot-bm-nl (`pvesm status`).
          `daily-fleet-backup-pbs` is still deliberately left on the `local-backup-zfs` interim
          fallback pending Mr. Byrne's go-ahead to revert per the 2026-09-04 fix — see
          `docs/HoT_PBS_Backup_Integration_Scope.md` Section 7.

    wg7 — tunnel to `hot-edge-ch` (server ID TBD, Hostkey CH, `82.38.64.63`) — the second edge VPS,
          built 2026-09-15 per `docs/HoT_Edge_Load_Balancing_Scope.md` §6-7 (Option A, Mr. Byrne's
          explicit call: a duplicate of the Gateway's own spec, in Switzerland — "opportunistic
          hardening," not protection against a specific facility-level failure mode). Gateway
          `10.10.6.1` / hot-edge-ch `10.10.6.2` (interface name `wg0` on that host, matching every
          other remote host's own-tunnel-is-always-wg0 convention), port 51827. `AllowedIPs`
          widened both directions to include `10.10.0.1/32` (the Gateway's PowerDNS bind) so
          hot-edge-ch's own Caddy can do DNS-01 cert issuance — no new Gateway UFW rule needed, the
          existing PowerDNS API rule already covers all of `10.10.0.0/16`.

          hot-edge-ch also runs two of its own dedicated tunnels, direct to hot-pn and hot-erp-nl
          (deliberately NOT routed through the Gateway — that defeats the point of a failover path):
          `wg1` (hot-edge-ch, `10.10.7.1`) ↔ `wg1` (hot-pn, `10.10.7.2`), port 51828; `wg2`
          (hot-edge-ch, `10.10.8.1`) ↔ `wg1` (hot-erp-nl, `10.10.8.2`), port 51829. Both hot-pn's
          frontend and hot-erp-nl's backend needed a second specific-IP port binding added
          (alongside their existing Gateway-tunnel bind, not replacing it) to actually accept
          traffic arriving via these new local IPs — see the scope doc for why.

          `AllowedIPs` widened again same night to add `10.10.70.106/32` (sn-security, for a planned
          hot-edge-ch Wazuh agent enrollment) — **this caused a real ~46-minute sn-security outage,
          self-inflicted, see the routing gotcha in `operational-rules.md`.** The manual
          `ip route add 10.10.70.106/32 dev wg7` that normally accompanies an `AllowedIPs` widening
          (since `wg syncconf` doesn't install routes on its own) was wrong here — sn-security was
          already reachable via the broader `10.10.70.0/24 dev wg4` route (its real VLAN, through
          hot-bm-nl), and the new `/32` route via `wg7` is more specific, so the kernel silently
          preferred it — routing all Gateway→sn-security traffic to hot-edge-ch instead of
          hot-bm-nl, where nothing was listening for it. Fixed by removing that one route
          (`ip route del 10.10.70.106 dev wg7`) — the `/24 dev wg4` route took back over immediately,
          confirmed via a clean ping. The `AllowedIPs` entry itself is still correct and needed (for
          the Gateway to *forward* wg7↔wg4 traffic to hot-edge-ch's own Wazuh agent) — only the local
          host route was the mistake.

          **Wazuh agent enrolled 2026-09-15 (ID 008, Active)** — see `services-fleet.md`'s enrollment
          note. Hit the mirror-image of the routing bug above: the forward SYN path worked fine, but
          hot-bm-nl's own `wg0.conf` had `10.10.6.2/32` in `AllowedIPs` with no matching kernel route
          ever installed, so sn-security's SYN-ACK had nowhere to go once it reached hot-bm-nl. Fixed
          with `ip route add 10.10.6.2/32 dev wg0` on hot-bm-nl.

          Caddy + an independent CrowdSec instance run on hot-edge-ch itself, covering exactly
          `privatenexus.net` and `erp.dickson-supplies.com` (not a full Gateway replica — Vaultwarden/
          mail/Keycloak/the other ~30 site blocks are a separate, unmade decision). Verified live:
          both domains serve real app content with genuine Let's Encrypt certs through this edge.
          **Live ingress since the same night (2026-09-15)** — both domains are now PowerDNS `LUA`
          records (`ifurlup()`, health-checked, 60s TTL) actively load-balanced across the Gateway
          and this host, not just standby — see `identity-dns-email.md`'s PowerDNS section and
          `docs/HoT_Edge_Load_Balancing_Scope.md` §8. SSH: tunnel + Tailscale only
          (`100.90.107.32`), password auth disabled, public port 22 confirmed unreachable — same
          hardening pattern as every other fleet host. Monitoring parity (fleet-health-sweep, Gatus,
          node-exporter/Prometheus) was closed out the same session. **UptimeRobot added
          2026-09-16** ("HoT-edge-ch", ID `804006343`, Port monitor on `82.38.64.63:443`, not
          HTTP(S) — Caddy's SNI-only routing means an HTTPS check against the bare IP fails cert
          validation even on a healthy host, same class of bug as the Gatus check earlier; a raw
          TCP port check sidesteps it). **Real correction to the earlier "needs a write-capable API
          key" assumption**: the existing key already had write access the whole time (`editMonitor`
          worked immediately) — the actual blocker was that UptimeRobot's free plan specifically
          disallows monitor *creation* via the API (`newMonitor` → `access_denied` regardless of
          parameters), not a key-scope problem. Mr. Byrne created the monitor manually in the
          dashboard; managed via the API from here on.

          **CrowdSec→Ntfy alerting wired 2026-09-16**, closing the last open item from this build.
          Mirrors the Gateway's own `hot-alerts` topic/token, but posts to the public
          `https://ntfy.house-of-trae.com/hot-alerts` URL rather than the Gateway's internal
          `http://ntfy:80/...` hostname (hot-edge-ch has no access to that Docker network) — message
          carries a `[hot-edge-ch]` prefix to stay distinguishable from the Gateway's own alerts in
          the same topic. **Real gotcha**: this instance's `profiles.yaml` ships with the entire
          `notifications:` key commented out by default, not just the list entries under it —
          uncommenting only `- http_default` without uncommenting the parent key leaves it a
          dangling, unparented YAML node. Verified end-to-end with a real disposable test ban
          (reserved TEST-NET-3 IP, 1-minute duration) — confirmed the real Ntfy message arrived,
          then removed. Config lives in a named Docker volume, not bind-mounted — mirrored to
          `hot-config/hot-edge-ch/crowdsec/` for tracking, same pattern as the Gateway's own CrowdSec
          whitelist file.

**Key rule:** Production traffic never routes through Tailscale. Tailscale = admin SSH only.
**Key rule:** Bare metal has zero public-facing ports. All public traffic enters via the Gateway VPS.
**Key rule, updated 2026-09-15:** this was true until hot-edge-ch (above) — a second, independent
public entry point now genuinely exists, currently standby-only (DNS doesn't point there, no
automated failover trigger built). If that changes, this rule needs a real rewrite, not a footnote.
**Key rule:** Before creating a new WireGuard interface on the Gateway VPS, run `wg show` first — wg1 (personal VPN) is easy to collide with by guessing sequential names.

---

## SSH Access — VM Aliases

All VMs are reachable directly from this Gateway via SSH aliases.
SSH key: /root/.ssh/claude_code_key
SSH config: /root/.ssh/config

| Alias       | IP             | VLAN |
|-------------|----------------|------|
| sn-infra    | 10.10.10.100   | 10   |
| sn-web      | 10.10.30.102   | 30   |
| sn-monitor  | 10.10.50.104   | 50   |
| sn-security | 10.10.70.106   | 70   |

**Removed 2026-07-30** (confirmed dead-end via full fleet health check, see fleet_health_check_2026_07_30 memory): `proxmox` (10.10.0.2), `sn-business` (10.10.20.101), `sn-personal` (10.10.40.103), `pn-test` (10.10.60.105) — all routed to VLANs/hosts that only existed behind the old wg0 tunnel to the permanently decommissioned original bare-metal host (EPYC 3151, server 145990). sn-business's role moved permanently to hot-erp/hot-pn; sn-personal and pn-test are both retired outright (Mr. Byrne's decisions, sn-personal 2026-08-09, pn-test 2026-08-03) and will not be revived — see Network Topology above and hostkey_server_replacement memory.

---

