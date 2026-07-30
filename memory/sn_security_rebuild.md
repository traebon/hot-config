---
name: sn-security-rebuild
description: sn-security rebuilt as VM 106 on hot-bm-nl — Wazuh SIEM + Forgejo runner live; initial LUKS2+GRUB host-chroot attempt failed and was abandoned (2026-07-27), but the LUKS2+Tang retrofit was later completed successfully (2026-07-28) via the proven netboot+preseed recipe — sn-security is now genuinely encrypted, running at cores=2 (not the documented 4) due to a real hot-bm-nl SMP hang
metadata: 
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-30T00:11:32.710Z
---

**⚠ UPDATE 2026-07-28 — superseded: the LUKS2+Tang retrofit that this file originally documented as
"abandoned, deferred fleet-wide" was subsequently completed successfully.** Using the proven
netboot+preseed recipe developed on sn-web (see [[sn_web_luks_pilot_fix]]), sn-security was rebuilt a
second time from scratch with real LUKS2 encryption and Tang auto-unlock, this time working. Two new
bugs specific to this rebuild (missing `console=ttyS0` on the installer's own kernel `-append` line;
a real SMP bring-up hang on hot-bm-nl above 2 vCPUs) are documented in full in
[[sn_web_luks_pilot_fix]]'s final sections — summary: **sn-security now runs at `cores=2` instead of
the originally-planned 4 vCPUs.** Root-caused and resolved 2026-07-28 — see [[sn_web_luks_pilot_fix]]
for the full investigation; Mr. Byrne decided to keep `cores=2` permanently, CLAUDE.md updated to
match. Wazuh SIEM, Wazuh's `.env`-based credentials (recreated from CLAUDE.md's documented
values after a real ~2-hour authentication outage caused by this file missing from the pre-rebuild
backup — also detailed in [[sn_web_luks_pilot_fix]]), and the Forgejo runner were all restored and
verified working with real historical data (indexer indices include pre-rebuild dates, not a fresh
empty install) — both locally and externally through Caddy. The narrative below (steps 1-5 of the
"failed" attempt) is kept as-is for the historical record of what NOT to repeat (host-chroot
`grub-install` against a raw zvol), but no longer reflects the current state of this VM.

---

**2026-07-27 — sn-security rebuilt as VM 106 on hot-bm-nl.** This is the last of the 4 VMs in the
rebuild order (after sn-infra/sn-web/sn-monitor — see [[sn_infra_rebuild]], [[sn_web_rebuild]],
[[sn_monitor_rebuild]]). 4 vCPU/8GB/250GB, VLAN 70, `10.10.70.106`, matching CLAUDE.md's spec.

**⚠ Real, time-boxed attempt at LUKS2-encrypted root failed at the GRUB level — abandoned for a
plain cloud-init build, matching sn-infra/sn-web/sn-monitor.** Mr. Byrne asked specifically for
real LUKS2+Tang encryption on this VM (the SIEM box), unlike the other 3 which were built
unencrypted for speed. Attempted a genuine from-scratch encrypted install:
1. First tried a fully-unattended Debian preseed install (netinst kernel/initrd booted directly
   via `qm set --args` with `-kernel`/`-initrd`/`-append`, preseed served over HTTP from a
   temporary `python3 -m http.server` bound to `10.10.70.1` — hot-bm-nl's own VLAN 70 gateway IP).
   This got genuinely stuck (confirmed via ZFS-dataset-level `zfs list` showing only 56K actually
   written after several minutes, ruling out "just slow") — never diagnosed why, abandoned in favor
   of a more scriptable approach.
2. Switched to building the encrypted disk directly from the hot-bm-nl host: `parted` (GPT,
   1MiB bios_grub + 512MiB /boot ext4 + LUKS2 root on the rest, matching the documented `/dev/sda3`
   convention), `cryptsetup luksFormat --type luks2`, `debootstrap bookworm`, chroot to install
   kernel/grub-pc/cryptsetup-initramfs/ssh, `grub-install`+`update-grub`. Got a real, working base
   system all the way through — verified via a temporary keyfile-in-initramfs bootstrap (see below)
   that unlocking would work automatically.
3. **The actual failure: GRUB couldn't read the disk's own GPT partition table at boot at all.**
   Confirmed conclusively via QEMU's `screendump` monitor command (piped through `pnmtopng`/PIL
   since no viewer was available) — `grub rescue>` prompt, `ls` showed only `(hd0)` with zero
   partitions enumerated, and `ls (hd0,gpt2)` explicitly returned `error: no such partition`, even
   though `parted /dev/zd96 print` from the host confirmed the GPT table was completely valid.
   Root cause is almost certainly that `grub-install` was run from a **host-side chroot** against
   the raw zvol device path (`/dev/zd96`), which can embed incorrect disk geometry/BIOS-drive
   assumptions relative to how the guest's own BIOS will actually enumerate the disk — this is a
   known class of pitfall for building VM disk images via host-chroot rather than from within an
   actual guest boot environment. (Ruled out the ZFS zvol's 16K volblocksize as the cause first —
   confirmed VM 100's disk uses the identical 16K blocksize and boots fine via its cloud-init-built
   GRUB, so block size wasn't the differentiator.)
4. Tried pivoting to Debian's installer "rescue mode" (`rescue/enable=true` kernel param) to reinstall
   GRUB from within a real guest boot context instead — this got stuck at "Probing EDD" with zero
   further console output for several minutes, less clearly diagnosable than the first attempt, and
   is where the decision was made to stop rather than keep debugging blind.
5. **Also built, along the way, a real fix for a genuine SSH-hostkey-reuse gotcha**: the same IP
   was previously used by the original decommissioned sn-security VM, so `ssh-keygen -R` was needed
   before either build attempt could connect cleanly — not unique to this VM, same pattern hit on
   every rebuilt VM this session.

Asked Mr. Byrne directly rather than keep burning time; he chose to fall back to the proven
cloud-init recipe (same as the other 3) and revisit encryption as a **dedicated, research-first
follow-up task for all 4 rebuilt VMs together** — not something to retry as a quick side-quest.
Cleanly destroyed the failed build first (`qm destroy 106 --purge`, confirmed the zvol was gone via
`zfs list`) before rebuilding.

**How to apply, if the LUKS retrofit is picked up later:** don't repeat the host-chroot
`grub-install` approach — either (a) build the disk via an actual guest boot (attach the install
media to a running VM and do the partition/LUKS/debootstrap/grub work from within that guest's own
BIOS/QEMU context, not from the hypervisor host), or (b) research Proxmox's own documented pattern
for pre-seeded/automated Debian+LUKS installs (community wiki likely has a known-working recipe
that avoids this exact pitfall) before attempting again blind. The temporary-keyfile-in-initramfs
bootstrap technique used in step 2 (add a keyfile as an extra LUKS keyslot, set
`KEYFILE_PATTERN="/etc/cryptsetup-keys.d/*.key"` in `/etc/cryptsetup-initramfs/conf-hook` **without**
also setting `keyscript=` in crypttab — that combination disables the automatic keyfile-embedding
logic entirely, a real bug hit and fixed mid-attempt — then remove the keyfile slot once real
Tang binding is confirmed working) is still valid and worth reusing whenever this is retried.

---

**Base VM setup (cloud-init, same recipe as the other 3):** Debian 12 genericcloud image, Docker CE
+ compose plugin, `ufw`/`qemu-guest-agent`, default-allow-incoming UFW. No new host-level network
bugs this time — all 3 fixes from the sn-infra/sn-monitor builds (VLAN forward rules, NAT egress,
cross-VLAN forward rules for `vmbr0.70`↔`vmbr0.50`) were already in place fleet-wide.

**Wazuh SIEM deployed — official `wazuh/wazuh-docker` v4.14.5 single-node** (matches CLAUDE.md's
pinned version exactly, confirmed via the upstream repo's own `docker-compose.yml`). Cloned the
tagged release directly from GitHub, generated real SSL certs via `generate-indexer-certs.yml`
(needs Docker — this is why hot-bm-nl itself was deliberately kept Docker-free, this ran on
sn-security instead), generated real bcrypt hashes for `internal_users.yml`'s `admin`/`kibanaserver`
entries via `docker run wazuh/wazuh-indexer:4.14.5 bash .../hash.sh -p '<password>'`, wired in the
**already-documented CLAUDE.md credentials** (admin/wazuh-wui/kibanaserver — all pre-existing,
reused unchanged, not regenerated) into the compose + `wazuh.yml` (fixing the exact documented
`MyS3cr37P450r.*-` placeholder gotcha). Verified genuinely healthy, not just "containers running":
`_cluster/health` → `green` (100% active shards), a real `wazuh-wui` JWT auth token issued via the
manager's own API, dashboard 302-redirecting correctly through Caddy, and dashboard logs showing
real Wazuh index/template creation (proof the 3 services are actually talking to each other
correctly, not just each independently up).

**⚠ RAM was genuinely tight during deploy — 1.7GB free / 3.0GB "available" on hot-bm-nl right
before starting Wazuh** (host has 31GB total; 3 other VMs already running consumed a lot, plus ZFS
ARC was holding 11.6GB). Checked whether this was real pressure or reclaimable cache before
proceeding: ARC's `size` (11.6GB) vs `c_max` (32GB, default ~50% of RAM) confirmed it's genuinely
reclaimable, and available memory measurably improved once Wazuh actually started (ARC shrank as
predicted). No OOM/crash-loop occurred, matching the CLAUDE.md warning's "below 6GB causes
problems" threshold — this deploy got real headroom despite the scary `free -h` topline. Worth
re-checking `free -h` before any future memory-heavy deploy on this box, now that it's running 4
VMs — 20GB is allocated (out of 31GB physical) and this margin will only get tighter.

**Docker-secrets follow-up requested by Mr. Byrne, done properly (2026-07-27):** the upstream
compose hardcodes `INDEXER_PASSWORD`/`API_PASSWORD`/`DASHBOARD_PASSWORD` as plain env var values —
checked (don't assume) whether the images support the fleet's usual `_FILE` Docker-secrets
convention before either forcing it or dismissing it. Read the actual `wazuh-indexer` entrypoint
source (`/usr/share/wazuh-indexer/bin/opensearch-env-from-file`, fetched from the real upstream repo,
not guessed): the `_FILE` mechanism genuinely exists in these images, but it's hardcoded to exactly
two variables (`OPENSEARCH_PASSWORD_FILE`, `KEYSTORE_PASSWORD_FILE`) — **not** a generic mechanism
despite a misleadingly generic-sounding comment above the loop. None of the 3 passwords actually
used here are in that list, confirming Docker secrets genuinely can't be used for them without
risking silently broken auth (the container would read the literal file path string as the
password). Real fix applied instead: converted all 5 occurrences across the compose to
`${WAZUH_INDEXER_PASSWORD}`/`${WAZUH_API_PASSWORD}`/`${WAZUH_DASHBOARD_PASSWORD}` variable
references, real values moved to a root-only `/opt/stacks/wazuh/.env` (chmod 600, not committed) —
same pattern already used fleet-wide for Watchtower's SMTP password. Verified the substitution
actually took effect at the Docker level (`docker inspect`'s resolved `Config.Env`, not just
trusting `docker compose up` reported no changes), and re-verified full stack health
(`_cluster/health` → `green`) after the container recreate.

**Also rotated the Wazuh cluster key** (`<key>` in `wazuh_manager.conf`, used for inter-node
auth in a real multi-node cluster — inert on this single-node deployment, but was still the
upstream repo's own well-known public default value, confirmed by diffing against the pristine
clone). Not a real secret exposure risk here specifically, but bad hygiene to commit a public
default into a *security* tool's own config. Generated a fresh random value
(`openssl rand -hex 16`), applied it directly to the live `ossec.conf` inside the running
container (the mounted `wazuh_manager.conf` only seeds `ossec.conf` on first-ever volume creation,
**not** on every container restart — had to `docker exec ... sed` the live file directly rather
than just editing the mount and restarting).

**`hot-config` now has a real `sn-security/wazuh/` directory** — compose (safe, credentials
externalized), `README.md` explaining exactly what's excluded and why (`.env`,
`internal_users.yml`, the real `wazuh.yml`, the generated SSL certs — all genuinely sensitive,
kept off git deliberately, matching the pattern for every other service's `secrets/` directory in
this repo), and `.env.example` showing the expected shape without real values.

**Forgejo runner: switched from an undocumented custom image to the official one.** The original
compose referenced `hot-forgejo-runner:latest` — no Dockerfile or build source for this image
existed anywhere in `hot-config`, meaning it was built ad-hoc directly on the original
(decommissioned) VM and is genuinely unrecoverable. The `entrypoint.sh`/`config.yaml` files that
DID survive are self-contained and don't actually require anything custom — switched the image to
`code.forgejo.org/forgejo/runner:6` (the official upstream tag) with zero other changes needed.
Also fixed `group_add` (hardcoded `988` from the original box's docker.sock GID — this box's is
`994`, confirmed via `stat -c '%g' /var/run/docker.sock` per the documented gotcha). Registered
successfully against `git.securenexus.net` on first try (`Runner registered successfully`, poller
launched) — verified via the runner's own logs since Forgejo's admin API doesn't expose a
`/api/v1/admin/runners` listing endpoint in this version (404, wrong path — not investigated
further, the runner's own registration success is sufficient proof).

**Fleet-wide monitoring wired up**: node-exporter + Promtail (same pattern as sn-infra/sn-web),
Watchtower (monitor-only, reused SMTP password), added to Prometheus's scrape targets
(`sn-security-node` job) and the blackbox probe list (`wazuh.house-of-trae.com`) — verified live via
`/api/v1/targets` showing `up` and Loki's `label/host/values` including `sn-security` with real
Forgejo/Wazuh log lines flowing.

**This closes the full 4-VM rebuild** (sn-infra, sn-web, sn-monitor, sn-security) started once
nested virtualization was confirmed working on hot-bm-nl. Remaining follow-ups, none blocking:
LUKS2+Tang retrofit for all 4 VMs (deliberately deferred, needs real research first), and whatever
Mr. Byrne decides about the sn-personal/pn-test VLANs (40/60) that were explicitly excluded from
this rebuild per the 2026-07-24 decision.

**⚠ Wazuh's vulnerability-detection feed update is a genuinely heavy, hours-long first-run
operation — starves the rest of hot-bm-nl for CPU while it runs.** Discovered 2026-07-27 while
debugging why the sn-web LUKS-pilot installer (see below) kept stalling with zero progress despite
looking fine moments earlier. `docker stats` showed `wazuh-wazuh.manager-1` sustained at ~92% CPU
with 31.9GB read / 58.1GB block I/O; manager logs confirmed
`wazuh-modulesd:vulnerability-scanner: INFO: Initiating update feed process` started at 01:17 and
was *still running* at 04:05 (~3 hours in) — this is Wazuh downloading and indexing CVE feeds for
multiple OS distros on its very first start, not a bug or misconfiguration. Host load average
(2.49 on 4 physical vCPUs) confirmed genuine contention, not just this one VM being slow. Disk
space is fine (11% used) — this is a CPU/IO story, not a capacity one.

**How to apply:** if any future install/deploy on hot-bm-nl behaves inconsistently or "stalls" for
no clear reason, check `docker stats` on sn-security and `docker logs wazuh-wazuh.manager-1` for
this exact feed-update message before assuming the *other* thing being built is broken — this cost
real time misdiagnosing the sn-web installer as stuck when the installer itself was fine, just
starved. The feed update should be one-time (subsequent runs use `feed-update-interval: 60m`
incremental updates per the compose config, not a full re-download) — if it's still running on a
future check, that's worth a fresh look, but don't assume that from this entry alone without
re-checking live.
