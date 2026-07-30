---
name: rclone-crypt-password-vaultwarden
description: Where the rclone crypt password/salt for Proxmox backup remotes (hetzner-crypt, b2-hot-crypt, b2-snap-crypt) lives, and its mislabeling history
metadata:
  type: reference
  originSessionId: 117aa5dc-c3dc-49d1-ab51-7125c1a1e0a9
---

The rclone crypt password + salt used by all three encrypted backup remotes (`hetzner-crypt:`, `b2-hot-crypt:`, `b2-snap-crypt:` — same pair reused across all three) is stored in Vaultwarden as item **"Hetzner Storage Box rclone crypt — Gateway + Proxmox backups"** (item id `33478078-50ef-4cf5-8ec2-f3588c3f2323`). Notes field contains the raw password, raw salt, the Hetzner Storage Box hostname/port, and remote paths.

**Why this needed a memory:** The entry was originally created 2026-07-04 but at some point carried a leftover/confusing label ("gocryptfs") that caused a later session (2026-07-06) to miss it entirely and wrongly conclude the password was unreachable (Proxmox-only) — see the correction in [[hostkey_server_replacement]]. Verified 2026-07-09 (via `bw unlock` with the master password, then re-locked) that the entry is now correctly labeled and its contents match what earlier sessions configured on both Proxmox and the Gateway VPS.

**How to apply:** If a future session needs the Hetzner/B2 rclone crypt password (e.g. for a real restore, or reconfiguring the fallback on a rebuilt Gateway/Proxmox), look up this Vaultwarden item by name/id rather than re-deriving or re-guessing it — don't repeat the mislabeling confusion. Don't assume it's Proxmox-only; it isn't.

**Vault access note:** `bw` CLI on the Gateway is logged in (API key) but stays locked between sessions. Unlocking requires the master password — as of 2026-07-09 Mr. Byrne authorized using the one found in a 2026-07-03 transcript for a one-off check, but on 2026-07-03 he had previously chosen "API key login, I'll unlock myself and paste the session token" specifically to keep the master password out of the agent's session. Ask before unlocking again rather than assuming the master-password shortcut is standing permission — treat each unlock as needing fresh authorization.
