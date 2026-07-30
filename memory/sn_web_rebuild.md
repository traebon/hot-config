---
name: sn-web-rebuild
description: "sn-web rebuilt as VM 102 on hot-bm-nl (2026-07-27), same pattern as sn-infra — 6 client \"Coming Soon\" sites, all live, Watchtower added"
metadata: 
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-28T04:56:03.073Z
---

**2026-07-27 — sn-web rebuilt as VM 102 on hot-bm-nl**, following the exact pattern established
for sn-infra (VM 100, see [[sn_infra_rebuild]]). Much lower-stakes than sn-infra — no secrets, no
OIDC, no real user data, just 6 nginx:alpine "Coming Soon" placeholder sites.

**VM creation process (first time actually building a fresh VM from scratch this session — VM 100
was inherited already-defined from 2026-07-24):** reused the Debian 12 genericcloud qcow2 already
cached at `/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2` on hot-bm-nl (left over
from VM 100's original creation) rather than re-downloading. `qm create` → `qm importdisk` →
attach as `scsi0` → `qm resize scsi0 250G` (cloud images are small by default, always need
growing) → cloud-init via `--ipconfig0`/`--ciuser root`/`--sshkeys` → start. Matches VM 100's
config almost exactly (2 vCPU here per CLAUDE.md's sn-web spec, vs sn-infra's 1). This is the
reusable recipe for sn-monitor/sn-security next.

**Base VM setup identical to sn-infra**: Docker CE + compose plugin, `ufw`/`qemu-guest-agent`
installed, default-allow-incoming UFW (matches fleet convention), SSH alias already existed and
worked once the old host-key entry (same IP, original decommissioned VM) was purged. The 3
host-level network fixes from the sn-infra rebuild (VLAN forward rules, NAT egress, wg0 loopback
route) were already in place fleet-wide — confirmed `apt-get update` and PowerDNS API reachability
both worked immediately with zero extra fixes needed this time.

**Site content: never actually lost, because it was never committed in the first place.** Checked
`hot-config`'s `sn-web/*/` dirs before assuming another backup-recovery situation — each only ever
had a `docker-compose.yml`, no `html/` directory, no `.gitignore` exclusion either. These
placeholder pages apparently only ever lived on the original decommissioned VM's disk, not synced
to git at all (unlike the secrets-must-not-be-committed pattern elsewhere, this looks like a plain
gap, not a deliberate exclusion). Wrote fresh minimal "Coming Soon" pages (dark theme, just the
entity name + "Coming soon.") for all 6 — no fabricated marketing copy, just a clean placeholder
matching what these apparently already were.

**Caddy blocks and DNS were already fully correct** — unlike ntfy's cross-host bug on sn-infra, all
6 `stratus-digital.com`/`discreet-elite.uk`/`emerald-markets.net`/`rubyosiris.com`/
`evilrabbitart.com`/`dickson-supplies.com` blocks (+ `www.` variants) already pointed at
`10.10.30.102:800N` correctly, no fixes needed. Verified all 12 (6 apex + 6 www) return `200` live,
TLS certs all valid/unexpired, and a DNSSEC sanity sweep (same method as the namevault.co.uk fix)
came back clean (`NOERROR` via 8.8.8.8) on all 6.

Watchtower added (`hot-config` commit `e410b61`), same v1.5.3/monitor-only pattern, reused SMTP
password. Port bindings tightened to the specific-IP pattern (`10.10.30.102:800N:80`) matching the
rest of the fleet, previously unscoped.

**How to apply:** sn-web is fully done, no open items on either side (no secrets, no
Mr.-Byrne-blocked steps like sn-infra had). Next in the rebuild order per
[[hostkey_server_replacement]] is sn-security (Wazuh) or sn-monitor — check with Mr. Byrne on
order/priority before starting either.

**⚠ This "fully done" status went stale the same day, 2026-07-28 — worth remembering when trusting
any "no open items" memory after further work touches the same VM.** The LUKS2+Tang encrypted
rebuild ([[sn_web_luks_pilot_fix]], done later 2026-07-27) did a full fresh Debian install on VM
102 to prove the encryption pipeline — which wiped Docker and all 6 sites again, and they were
never redeployed afterward since that pilot's goal was just proving LUKS+Tang worked, not service
continuity. Caught during a routine health check the next day: `docker: command not found`, zero
containers running, sites presumably 502ing (not confirmed before the fix — moved straight to
fixing it). Re-deployed clean: `curl -fsSL https://get.docker.com | sh`, copied all 9 stack dirs
(6 sites + promtail/node-exporter/watchtower) from `hot-config` (nothing lost, no site had any
real data, just compose+html), `docker compose up -d` each. Also installed and enabled UFW at the
same time (missing entirely — see [[sn_web_luks_pilot_fix]] finding 5, fresh netboot+preseed
installs don't include it). Verified all 6 domains return real `200`s through Caddy afterward.
**Lesson: any VM that gets its disk-encryption pipeline retrofitted via a full fresh install needs
its actual services re-verified/re-deployed as a real step, not assumed to carry over — "install
succeeded" and "services are back" are two different, separately-checkable facts.**
