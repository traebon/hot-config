## Tor Hidden Services

Stack: `/opt/stacks/tor/` on Gateway VPS. `network_mode: host` — `HiddenServicePort 80 127.0.0.1:80` hits Caddy directly.

| Service          | Onion Address                                                    | Auth      | Notes                              |
|------------------|------------------------------------------------------------------|-----------|------------------------------------|
| ERPNext (mirror) | qcrzygpg5qbzch4c2qlcgiktuvzf3xwqwtd7mkcn5r4g4mxebmpptkid.onion | x25519 v3 | Mirror of erp.dickson-supplies.com |

Caddy block uses `http://` prefix + `header_up Host erp.dickson-supplies.com`.
Client private key for tristian: Vaultwarden — "ERPNext Onion Client Auth Key (tristian)" (regenerated 2026-08-02, see note below).
Auth files: `/opt/stacks/tor/data/erp/authorized_clients/` (chown 100:101, chmod 600). Reload: `docker compose restart tor`.

⚠️ **`authorized_clients/*.auth` on disk is the server-side PUBLIC key only** (`descriptor:x25519:<pubkey>`) — Tor's standard v3 client-auth layout. It is NOT what Tor Browser's client-auth popup asks for. The matching PRIVATE key (the bare base32 string Tor Browser wants) only ever exists client-side and is never stored in this directory — it must be captured at keypair-generation time and saved separately (Vaultwarden), or it's permanently unrecoverable (X25519 — private can't be derived from public). **2026-08-02 incident:** the Vaultwarden entry had been holding the public key mislabeled as private the whole time; the real original private key was never saved anywhere and was lost. Fixed by generating a fresh keypair, installing the new public half here, restarting Tor, and saving the real private key to Vaultwarden. If this ever needs regenerating again: generate an X25519 keypair, base32-encode (RFC4648, no padding) both halves, write `descriptor:x25519:<pubkey_b32>` to this directory (chown 100:101, chmod 600), restart the tor container, and give the client the bare `<privkey_b32>` string — never store the private half server-side.

⚠️ Backup: Gateway VPS is NOT a Proxmox VM. Losing `hs_ed25519_secret_key` means the onion address is permanently lost. Include `/opt/stacks/tor/data/erp/` in any VPS backup.
`data/` is never committed to git (only docker-compose.yml, Dockerfile, torrc are synced).

---

