---
name: proxmox-bare-metal-fixes
description: "Hard-won fixes for Proxmox bare metal crashes (Jun 26–28 2026) — NIC PCIe fix, boot tool gotcha, backup window collision, balloon settings"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8ee3b24b-6e99-4b8a-865c-70f3ba29d2d5
  modified: 2026-07-27T02:56:02.373Z
---

## NIC PCIe fix — pcie_aspm=off

Proxmox uses `proxmox-boot-tool` (systemd-boot/UEFI) — NOT GRUB. Writing to `/etc/default/grub` has zero effect. The correct path:
1. Edit `/etc/kernel/cmdline` on the Proxmox host
2. Run `proxmox-boot-tool refresh` (but this does NOT update existing ESP entries — only creates entries for new kernels)
3. To patch existing boot entries: mount both ESPs and sed the `.conf` files directly

ESPs: `/dev/sda2` (UUID `E2CE-E591`) and `/dev/sdb2` (UUID `E2D3-6EF8`)

Fix is LIVE as of Jun 28 18:55 boot on kernel 7.0.12-1-pve.

**Why:** Intel I350 NIC (`igb 0000:03:00.0`) PCIe link loss events on Jun 26 08:47 and Jun 27 03:13 caused complete outages. Physical NIC reseat via Hostkey ticket still pending.

## Backup window collision (root cause of nightly crashes)

vzdump runs **3 hours** (02:00–05:00). Old schedule had rclone jobs at 02:45 (Hetzner) and 04:00 (B2) — all reading/writing the same ZFS spinning HDDs concurrently.

**Fixed schedule (Jun 29 2026):**
- 01:00 — config sync (lightweight)
- 02:00 — vzdump (finishes ~05:00)
- 06:00 — rclone to Hetzner (`hetzner-crypt:` remote)
- 07:30 — rclone to B2 (`b2-hot-crypt:` remote via `backup-vms-b2.sh`)

The `backup-vms-b2.sh` script is at `/opt/hot-config/backup-vms-b2.sh`.

**Note:** CLAUDE.md previously said B2 at 03:00 and Wasabi at 04:00 — both wrong. Actual destination is Hetzner (not Wasabi). CLAUDE.md updated.

## KVM balloon targets (all 7 VMs)

Set to prevent host OOM during backup window. These persist in VM config:

| VM  | Name         | Max RAM | Balloon Min |
|-----|--------------|---------|-------------|
| 100 | sn-infra     | 4096 MB | 2560 MB     |
| 101 | sn-business  | 8192 MB | 5120 MB     |
| 102 | sn-web       | 4096 MB | 2048 MB     |
| 103 | sn-personal  | 8192 MB | 3072 MB     |
| 104 | sn-monitor   | 4096 MB | 3072 MB     |
| 105 | pn-test      | 4096 MB | 3072 MB     |
| 106 | sn-security  | 8192 MB | 7168 MB     |

VM 106 (Wazuh) must not drop below 6 GB — OpenSearch peaks at 3–4 GB RSS on startup.

## pve-ha-lrm gotcha on single-node

On a single-node Proxmox, `pve-ha-lrm.service` can get stuck in "deactivating" indefinitely (no quorum). If apt/dpkg hangs for 15+ minutes during a package postinst, check if `pve-ha-lrm` is the blocker. Fix: `systemctl kill --kill-whom=all -s SIGKILL pve-ha-lrm.service`. Service will be in "failed" state but will recover cleanly on reboot.

## Config backup

`/opt/hot-config/sync-configs.sh` backs up `/etc/pve/` and root crontab (`proxmox/root-crontab`) to Forgejo at 01:00 daily.

## Balloon targets applied to the rebuilt fleet (2026-07-27)

The 4 VMs rebuilt on hot-bm-nl (100/102/104/106) initially had no `balloon:` config at all — this
table's original targets (same specs) were reapplied: sn-infra 2560, sn-web 2048, sn-monitor 3072,
sn-security 7168 (maxes 4096/4096/4096/8192, matching this table's original values exactly since
the rebuilt VMs use identical resource allocations). Verified live via `qm monitor <id> info
balloon` — Proxmox's balloon daemon applies targets gradually, not instantly. See
[[sn_security_rebuild]] and [[open_items_2026_07_27]] for context (sn-security was found using
~7.6GB of its 8GB during Wazuh's first-run vulnerability feed build — genuine need, not a
misconfiguration; the new floor just protects it from being squeezed below 6GB under host
pressure going forward, matching this file's own original warning).
