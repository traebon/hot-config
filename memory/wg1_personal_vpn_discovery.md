---
name: wg1-personal-vpn-discovery
description: Gateway VPS already runs a wg1 WireGuard interface for Mr. Byrne's personal road-warrior VPN, undocumented in CLAUDE.md until 2026-07-06
metadata:
  type: project
  originSessionId: 662a2e2b-edf7-4613-857f-27ff2bf97ace
---

Discovered 2026-07-06 while setting up a new WireGuard tunnel to a temporary VPS (erp-temp, see [[hostkey_server_replacement]]): the Gateway VPS already has an active `wg1` interface, listening on port 51821, subnet `10.10.90.0/24` (Gateway itself at `10.10.90.1`), with three peers (`10.10.90.2/3/4` — no active handshakes at time of discovery, so likely phone/laptop/windows respectively). Client configs live at `/root/hot/wireguard-clients/{phone,windows,laptop}.conf`. It's also referenced in `/opt/stacks/caddy/Caddyfile`'s access-control snippet for at least one internal-only service (alongside `10.10.0.0/16` and the Gateway's own public IP).

This was **not documented anywhere in CLAUDE.md** before this date — the only WireGuard tunnel CLAUDE.md described was `wg0` (Gateway ↔ bare metal).

**Why this matters:** I picked the name `wg1` and port `51821` for a brand-new tunnel without checking `wg show` first, and `wg-quick up wg1` on the Gateway correctly refused ("already exists") — but I'd already overwritten `/etc/wireguard/wg1.conf` on disk with my own config before checking. Live interface was recovered via `wg showconf wg1` (dumps the running private key + peers) before anything rebooted, and the file was restored to match. No damage occurred, but this was close — a reboot before the fix would have taken out Mr. Byrne's own VPN access using a config that was never backed up elsewhere.

**How to apply:** Before creating any new WireGuard interface on the Gateway VPS, always run `wg show` (or `wg show interfaces`) first to see what's actually active, and check `/etc/wireguard/*.conf` for existing files — don't assume sequential naming (wg0 documented → wg1 "must be free"). This personal VPN should now also be added to CLAUDE.md's Network Topology section (done 2026-07-06) so future sessions see it without needing to rediscover it. If `/etc/wireguard/wg1.conf` is ever missing or looks wrong, the authoritative recovery method is `wg showconf wg1` while the interface is still live — the private key is NOT retrievable any other way if lost (Mr. Byrne doesn't appear to keep a separate backup of the client-side private keys either, only the client `.conf` files under `/root/hot/wireguard-clients/`, which do contain their own private keys — those are the actual backup, not the server-side conf).
