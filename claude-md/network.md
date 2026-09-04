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
          network**, 192.168.0.35/24 behind a home NAT — not a rented VPS like every other host
          in this fleet). Built 2026-08-22, dedicated WireGuard chosen deliberately over Tailscale
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

**Key rule:** Production traffic never routes through Tailscale. Tailscale = admin SSH only.
**Key rule:** Bare metal has zero public-facing ports. All public traffic enters via the Gateway VPS.
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

