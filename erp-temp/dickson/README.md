# erp-temp — Temporary ERPNext stand-in

Status: **temporary, deployed 2026-07-06**. Bare metal (sn-business, 10.10.20.101) has been
unreachable since 2026-07-02 (Hostkey ticket CS-471548 — recurring NIC/PCIe fault, full server
replacement in progress, see `hostkey_server_replacement` memory). This is a fresh ERPNext v16 +
posawesome deployment on a separate VPS (46.202.129.86), standing in for the real sn-business
instance until bare metal is restored.

## This is NOT a restore

**No historical ERPNext data.** The real vzdump backups for sn-business live encrypted on the
Hetzner Storage Box (`hetzner:vzdump/`), but the rclone crypt password for those backups lives
only on Proxmox itself (bare metal), not on the Gateway VPS or anywhere else reachable during
this outage — confirmed by trying to decrypt the backup directory name and failing. Per Mr.
Byrne's explicit decision (2026-07-06), this is a fresh empty site, not a data restore.

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

Connects to the Gateway VPS over a dedicated WireGuard tunnel, **`wg2`** (10.10.1.1 Gateway /
10.10.1.2 erp-temp, port 51822) — deliberately a new interface name/subnet, since `wg1` on the
Gateway VPS was already in use for Mr. Byrne's personal road-warrior VPN
(`10.10.90.0/24`, undocumented in CLAUDE.md prior to this — see `/root/hot/wireguard-clients/`).
Caddy's `erp.dickson-supplies.com` block on the Gateway VPS was repointed from
`10.10.20.101:8000` (sn-business) to `10.10.1.2:8000` (erp-temp) — commented inline with a revert
note. The Tor hidden service mirror needed no separate change since it routes through the same
Caddy site block.

## Revert plan (once bare metal is restored)

1. Confirm sn-business (10.10.20.101) is reachable and ERPNext there is healthy
2. Change Caddy's `erp.dickson-supplies.com` block back to `reverse_proxy 10.10.20.101:8000`
   (the commented-out original is right there in the Caddyfile)
3. Decide what to do with any orders/data entered into erp-temp during the outage window — this
   needs Mr. Byrne's input on how to reconcile/migrate it into the real instance, not an automated
   step
4. Tear down erp-temp's containers/volumes once confirmed no longer needed, `wg-quick down wg2`
   on both ends, remove the wg2 UFW rules, and decide whether to keep or release the VPS itself
5. Update this README and `CLAUDE.md`'s Service Locations table to remove references to erp-temp
