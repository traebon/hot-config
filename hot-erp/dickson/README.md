# hot-erp — ERPNext

**Migrated 2026-08-01 to hot-erp-nl (Hostkey NL, server 41614, wg5 tunnel) — hot-erp-nl is
PERMANENT, not a stand-in.** See `hot_erp_hostkey_ch_migration_scope` memory and CLAUDE.md's
hot-erp section for the full story (CH was blocked for new orders at migration time, landed in NL
instead). Everything below this line describes the *original* Hostinger deployment
(2026-07-06/07-09) — still accurate for how this stack is built and what's non-standard about it
(reconstructed Dockerfile, posawesome source, etc.), since the migration moved the existing
volumes/DB as-is rather than rebuilding. **Corrected 2026-08-23**: the Hostinger box is not
"retained idle pending go-ahead" — Mr. Byrne confirmed cancellation 2026-08-03, the old `wg2`
tunnel was torn down the same day, and the account is in the process of closing. The "Revert plan"
and "Networking" sections further down still describe the old Hostinger/wg2/sn-business setup as
if it were current or reversible — both corrected in place below rather than left to mislead.

---

Status: **superseded, originally deployed 2026-07-06**. Bare metal (sn-business, 10.10.20.101) has been
unreachable since 2026-07-02 (Hostkey ticket CS-471548 — recurring NIC/PCIe fault, full server
replacement in progress, see `hostkey_server_replacement` memory). This is a fresh ERPNext v16 +
posawesome deployment on a separate VPS (46.202.129.86), standing in for the real sn-business
instance until bare metal is restored.

## Data restore (2026-07-09)

**Historical ERPNext data has been restored.** The 2026-07-06 "fresh site" decision assumed the
rclone crypt password for the Hetzner vzdump backups lived only on Proxmox (unreachable during
the outage) — that assumption was wrong; the password had already been recovered to Vaultwarden
on 2026-07-04, just mislabeled (see `rclone_crypt_password_vaultwarden` memory). Once found, a
full restore was done from `vzdump-qemu-101-2026_06_29-02_19_44.vma.zst` (the last sn-business
backup before the 2026-07-02 outage):

1. Downloaded the backup from Hetzner. rclone's own SFTP client stalled deterministically at the
   same byte offset (~8.4GB/25%) on two separate attempts — a client-side bug, not a network
   issue. Worked around it with the plain OpenSSH `sftp` client using password auth (the SFTP
   account's key is registered SFTP-subsystem-only; a bare `ssh <host> <cmd>` test confirmed exec
   access is rejected, ruling out `rsync` too) — completed cleanly this way.
2. Decrypted the raw file locally: a temporary rclone `crypt` remote pointing at a local directory
   (same password/salt as `hetzner-crypt`, so no network involved) turned the downloaded blob back
   into the real `.vma.zst` — this sidesteps the SFTP stall entirely for future restores, since only
   the download needs the network.
3. Decompressed with `zstd -d --rm` (36GB compressed → 36GB decompressed — the VMA container format
   already strips zero blocks, so it isn't sparse-inflated like the original 300GB disk).
4. Extracted with Proxmox's `vma` tool (built standalone via `dpkg-deb -x` on the missing
   `libproxmox-backup-qemu`/`librbd`/`librados` .debs, no system package install) — produced a
   300GB-apparent, ~34GB-actual sparse raw disk image.
5. Attached via `losetup -fP`, unlocked `/dev/loop0p3` (LUKS2) with `clevis luks unlock` — same
   dual-Tang binding as every other HoT VM. erp-temp has no route to the Gateway's `wg0`-bound Tang
   (`10.10.0.1:7500`), so a temporary bridge (`ssh -R 127.0.0.1:7500:10.10.0.1:7500` + an `iptables`
   `OUTPUT` NAT redirect on erp-temp) stood in for it — torn down after use, no persistent routing
   changes.
6. Activated the LV, mounted it, and copied the real `dickson_dickson-db-data`,
   `dickson_dickson-sites-data`, and `dickson_dickson-assets-data` volume contents over erp-temp's
   fresh ones (originals kept as `_data.fresh-backup` alongside each volume, ~730MB total, not yet
   deleted). Patched `common_site_config.json`'s `redis_cache`/`redis_queue`/`redis_socketio`
   entries to erp-temp's actual redis passwords — the recovered site's own credentials for those
   were sn-business-specific and don't apply here; DB name/password and encryption keys were left
   as recovered since they matched the copied database's own grants.
7. Verified: `frappe.ping` returns `pong` through erp.dickson-supplies.com (public HTTPS, through
   Caddy), and a direct query against `tabItem` with the site's own DB credentials shows real
   inventory data dated back to February/March 2026 — not the fresh site's empty schema.

**Known gap:** anything entered into the fresh site between 2026-07-06 and 2026-07-09 is *not*
merged into the restored data — it only exists in the `.fresh-backup` volume copies on erp-temp.
Per Mr. Byrne (2026-07-06), erp-temp had been sitting unused, so this is expected to be nothing,
but hasn't been independently verified against the fresh-backup contents.

## What's different from the real sn-business/dickson stack

- `docker-compose.yml`: identical service layout, but `dickson-backend`'s port mapping is bound
  to `10.10.1.2:8000:8000` (the wg2 tunnel address) instead of `0.0.0.0:8000:8000` — this host is
  a public VPS, not a VLAN-isolated bare-metal VM, so the port must not be reachable from the
  public internet directly. UFW also has a belt-and-suspenders rule limiting :8000 to the tunnel
  peer, though the interface binding is what actually enforces it (Docker's own iptables rules
  bypass UFW's INPUT chain for published ports).
- `docker/Dockerfile` and `regen_assets.py`: **reconstructed, not recovered.** The real
  sn-business stack's actual Dockerfile/regen_assets.py were never captured by `sync.sh` (only
  `docker-compose.yml` was ever synced to `hot-config` — see `sn-business/dickson/`) and
  sn-business itself is unreachable, so the originals could not be recovered. This is a
  best-effort recreation using the standard frappe_docker custom-image pattern:
  - `posawesome` source is `https://github.com/yrestom/POS-Awesome.git` (branch `develop` — no
    versioned v15/v16 branch exists upstream, only up to `version-14`)
  - Installed via direct `git clone` + `pip install --no-build-isolation` rather than
    `bench get-app`, because `bench get-app`'s own installer uses `uv` with build isolation,
    which breaks on posawesome's `setup.py` (`import frappe` at build time)
  - `bench build` (full, unscoped) rather than `bench build --app posawesome` — a scoped build
    doesn't regenerate the consolidated `assets.json` manifest that `bundled_asset()` needs at
    runtime, causing every page to 500
  - Image bakes a dereferenced copy of `sites/assets` (`cp -aL`, not `cp -a` — the assets dir is
    full of symlinks from `bench build`'s linking step, and `regen_assets.py`'s `copytree` can't
    handle nested symlinks target-side) to `/opt/assets-image-baked`, which `regen_assets.py`
    restores over the persistent `sites/assets` volume on every container start (that volume is
    a named volume, not an image layer, so it goes stale on every image rebuild otherwise)
  - `sites/wsgi.py` (`from frappe.app import application`) had to be created manually in the
    persistent sites volume — CLAUDE.md documents the gunicorn command
    (`wsgi:application` from `sites/`) but the file itself was never backed up anywhere
  - `redis_cache`/`redis_queue`/`redis_socketio` needed both per-site (`bench set-config`) AND
    bench-wide (`bench set-config -g`, for `dickson-socketio`'s `realtime/index.js`) entries with
    the redis containers' auth passwords embedded in the URL — none of this one-time setup was
    captured in `docker-compose.yml` either, since it's a one-time `bench` step, not a compose
    concern

## Networking

**Historical (Hostinger/erp-temp era, superseded 2026-08-01) — kept for context, not current.**
Connected to the Gateway VPS over a dedicated WireGuard tunnel, `wg2` (10.10.1.1 Gateway /
10.10.1.2 erp-temp, port 51822) — deliberately a new interface name/subnet, since `wg1` on the
Gateway VPS was already in use for Mr. Byrne's personal road-warrior VPN (`10.10.90.0/24`). Caddy's
`erp.dickson-supplies.com` block was pointed at `10.10.1.2:8000`.

**Current (hot-erp-nl, permanent since 2026-08-01):** connects over `wg5` (10.10.4.1 Gateway /
10.10.4.2 hot-erp-nl, port 51825). Caddy's `erp.dickson-supplies.com` block points at
`10.10.4.2:8000`. `wg2` itself was torn down 2026-08-03 once the Hostinger account cancellation
was confirmed — it no longer exists on either end. The Tor hidden service mirror needed no
separate change either time, since it routes through the same Caddy site block.

## Custom branding placeholders (2026-07-15)

`dickson-theme.css` and `inject_dickson_theme.js` (referenced by the login page via Website
Settings' custom CSS/JS fields) were lost on 2026-07-09 when the historical data restore
overwrote the `sites/assets` volume with the real backup's own (near-empty) assets content --
neither file was ever captured in any backup or build process available here. Recreated as
minimal placeholders (`docker/custom-assets/`), baked into the image so `regen_assets.py`
restores them on every container start. Real branding, if recoverable at all, only exists on
bare metal itself.

Same investigation also found `dickson-backend` hadn't restarted since the 2026-07-09 restore,
so `regen_assets.py` had never re-run against the swapped-in volume -- most core frappe/erpnext
assets were 404ing (broken login page) independent of the branding-file issue. Fixed by rebuilding
all four `dickson-*` images and restarting them, then flushing the `dickson-redis-cache` DB to
clear stale cached asset-hash references from before the rebuild (a `bench build` re-run changes
the content-hash suffix on bundle filenames; deleting the `assets_json` key alone wasn't enough --
some other cached page/doctype content was still serving the old hashes).

## Revert plan — MOOT, corrected 2026-08-23

This section originally planned a revert back to sn-business "once bare metal is restored." That
premise no longer applies: sn-business will never be rebuilt (its role moved permanently to
hot-erp-nl/hot-pn, Mr. Byrne's decision), and hot-erp-nl itself was made ERPNext's *permanent* home
2026-08-01 — this isn't a stand-in awaiting a revert. Steps 1-2 and 4 (revert Caddy to sn-business,
tear down the temporary VPS) never happened and never will. Step 3's open question (data entered
during the 2026-07-06→07-09 fresh-site window, preserved in `_data.fresh-backup` volume copies, not
merged) is still genuinely unresolved — worth Mr. Byrne's input on whether that's still worth
reconciling at this point, independent of any revert. Step 5 (remove stale erp-temp references) is
this same cleanup pass, done here and in the top-level `hot-erp/README.md`.
