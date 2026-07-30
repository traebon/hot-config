---
name: fleet-health-check-2026-07-30
description: "Full-fleet live health check across all 11 hosts (2026-07-30) — stale SSH aliases identified, hot-bm-nl memory usage explained, logrotate bug found and fixed on Gateway + hot-erp"
metadata: 
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-30T08:19:48.379Z
---

Ran a full wide system check (uptime/load, mem, disk, `systemctl --failed`, UFW, docker container status, LUKS) across all 11 SSH-reachable hosts: Gateway, proxmox, sn-infra, sn-business, sn-web, sn-personal, sn-monitor, pn-test, sn-security, hot-bm-nl, hot-erp, hot-pn.

**8 hosts reachable and healthy:** Gateway, sn-infra, sn-web, sn-monitor, sn-security, hot-bm-nl, hot-erp, hot-pn. All containers Up, disk/mem/load nominal, UFW active, LUKS/crypt present on the 3 rebuilt bare-metal VMs as expected.

**3 SSH aliases timed out — confirmed stale, not an outage:** `proxmox` (10.10.0.2), `sn-business` (10.10.20.101), `sn-personal` (10.10.40.103), and `pn-test` (10.10.60.105) all route to IPs that only existed behind the old wg0 tunnel to the now permanently-decommissioned original bare-metal host (EPYC 3151, server 145990). sn-business/sn-personal's roles moved permanently to hot-erp/hot-pn; pn-test's fate is still undecided (see [[hostkey_server_replacement]]). These aliases in `/root/.ssh/config` will never reconnect — candidates for pruning, not urgent.
**Why:** avoids re-investigating these as a fresh incident on the next sweep.
**How to apply:** don't chase these as new outages; if pn-test's fate ever gets decided, that alias may become reachable again via a different IP/tunnel.

**hot-bm-nl memory usage (25GB/31GB, 81%) — investigated, normal:** traced to real guest RSS via `ps aux --sort=-rss`: sn-security's KVM process 7.7GB, sn-monitor 3.5GB, sn-infra 2.1GB, sn-web 2.1GB (~15.4GB combined) plus host/Proxmox overhead. This is expected KVM behavior (guest RAM shows as host qemu process RSS) — load average (1.33/8 cores) is fine, only 1.1GB swap in use. CLAUDE.md's hardware table still says "actual RSS ~7 GB across all VMs" — that figure is stale/understated; not corrected in CLAUDE.md as of 2026-07-30 (only saved here).
**Why:** so a future memory check doesn't re-alarm on hot-bm-nl's host-level memory percentage without re-deriving this breakdown.
**How to apply:** if hot-bm-nl's used memory keeps climbing well past ~25GB or swap usage grows substantially, that's worth a fresh look — this snapshot is the current-normal baseline, not a permanent ceiling.

**⚠ logrotate.service found failing on Gateway + hot-erp, fixed 2026-07-30:** both `systemctl --failed` showed logrotate dead since ~00:15-00:20 local time that night. Root cause: Ubuntu's `cloud-init` and `cloud-init-base` packages (both v26.1-0ubuntu2 on both hosts) ship byte-for-byte identical `/etc/logrotate.d/cloud-init*` conffiles matching the same glob (`/var/log/cloud-init*.log`) — logrotate detects the duplicate log-file definition and aborts the **entire run**, not just the cloud-init stanza, meaning no logs were rotating on either host at all until fixed. Fixed by deleting the `cloud-init` (non-base) package's conffile on both hosts — `/etc/logrotate.d/cloud-init` — keeping `cloud-init-base`'s copy, then verified with a manual `logrotate /etc/logrotate.conf` run (clean exit, no errors) and `systemctl reset-failed logrotate.service` on each.
**Why:** distro packaging bug, not a config drift or a manual edit gone wrong — matters for judging whether to expect it to recur.
**How to apply:** the other 6 checked hosts (sn-infra, sn-web, sn-monitor, sn-security, hot-bm-nl, hot-pn) showed no `systemctl --failed` logrotate entry at check time, but this is a package-version-triggered bug (same `cloud-init`/`cloud-init-base` split), not host-specific — if any of them are ever running the same or a similar cloud-init package split, check `dpkg -l | grep cloud-init` + `diff /etc/logrotate.d/cloud-init /etc/logrotate.d/cloud-init-base` and apply the same fix (delete the `cloud-init` non-base conffile) if they match. Since `/etc/logrotate.d/cloud-init` is dpkg-owned, a future `cloud-init` package upgrade could re-add it — re-check after any cloud-init package update on any host.
