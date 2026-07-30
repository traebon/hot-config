---
name: sn-infra-rebuild
description: "sn-infra rebuild on hot-bm-nl (VM 100) after nested virt was fixed 2026-07-26 — VM provisioning, networking bugs found/fixed, Ntfy + PowerDNS-Admin deployed, Forgejo/Namevault status"
metadata: 
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-30T00:12:22.265Z
---

**2026-07-26 — sn-infra rebuilt as VM 100 on hot-bm-nl, once nested virt was confirmed working
(see [[hostkey_server_replacement]] for the nested-virt saga).** VM 100 was already defined
(2026-07-24, correct spec: 1 vCPU/4GB/250GB, VLAN 10, static 10.10.10.100/24, cloud-init with
`ciuser=root` and the Gateway's SSH key baked in) but had never successfully booted until nested
virt landed. `qm start 100` succeeded; guest is Debian 12 bookworm, hostname `sn-infra`.

**Old data (Forgejo repos/issues/users, PowerDNS-Admin config, Namevault DB) is NOT recoverable —
confirmed no vzdump backup for any original VM survives in either Hetzner or B2 crypt stores**
(checked `hetzner-crypt:`/`b2-hot-crypt:` directly — only 3 real dirs exist:
`gateway-vps-backups`, and two now-empty `*-privatenexus-db` dirs superseded by the newer pg_dump
chain; the only VM-related artifact anywhere is one broken partial `vzdump-qemu-103-...tmp`). This
window was available as recently as 2026-07-09 (used to restore ERPNext) but is gone now — treat
as permanently lost, not a "check again later" item. Mr. Byrne confirmed: go fresh on all 4
services rather than keep hunting for a backup.

**Three real networking bugs found and fixed on hot-bm-nl while getting sn-infra reachable — all
three will silently bite sn-web/sn-monitor/sn-security too if not already fixed by the time they're
built (they should be, since these are host-wide fixes, not per-VM):**

1. **UFW `route allow` rules only matched the literal `vmbr0` interface, never the actual
   `vmbr0.10`/`.30`/`.50`/`.70` VLAN sub-interfaces** (distinct interface names in Linux even
   though they share the parent bridge). TCP was silently dropped by the default-DROP forward
   policy; ICMP looked fine only because ufw's own default rules explicitly allow echo-request
   regardless of interface, which masked the bug. Confirmed via `iptables -L ufw-user-forward -n -v`
   showing 0 packet counts on the old rules. Fixed: deleted the two `vmbr0`-only route rules,
   added 8 new ones (`in`/`out` × 4 VLANs) scoped to the real sub-interface names.

2. **No outbound NAT existed for the VLAN subnets at all** — VMs had zero internet access (their
   default route points at hot-bm-nl's local VLAN gateway, but nothing masqueraded that traffic out
   `ens1`, hot-bm-nl's public uplink). Only Docker's own bridge had a masquerade rule. Fixed: added
   a `*nat` table block to `/etc/ufw/before.rules` (`-A POSTROUTING -s 10.10.0.0/16 -o ens1 -j
   MASQUERADE`) plus `ufw route allow in on vmbr0.<N> out on ens1 from 10.10.0.0/16` for all 4
   VLANs, `ufw reload`. Verified: VM could reach 1.1.1.1 and resolve/reach deb.debian.org (IPv4
   only — no routable IPv6 on this box, `getent ahostsv4` needed to avoid AAAA-only replies causing
   apt to hang).

3. **Same class of bug already documented for hot-pn (2026-07-15): hot-bm-nl's own `wg0` peer
   `AllowedIPs` was scoped to just `10.10.3.1/32` (the Gateway's tunnel IP), not `10.10.0.1`
   (PowerDNS's loopback-alias IP on the Gateway)** — so nothing behind hot-bm-nl's VLANs could
   reach the PowerDNS API at all. Fixed identically to the hot-pn precedent: widened to
   `10.10.3.1/32, 10.10.0.1/32` via `sed` + `wg syncconf wg0 <(wg-quick strip wg0)`, then manually
   `ip route add 10.10.0.1/32 dev wg0` (syncconf never installs routes — same standing gotcha).
   Verified live: `curl http://10.10.0.1:8081/api/v1/servers/localhost` from sn-infra itself now
   returns 200, was timing out before.

**How to apply:** all three fixes are host-level (on hot-bm-nl or the Gateway), not VM-specific —
they should already be in place for sn-web/sn-monitor/sn-security when those get built. But
*verify* rather than assume, the same way bug #3 here was a surprise recurrence of a pattern
already fixed elsewhere once before.

**Base VM setup completed for sn-infra (VM 100):** Docker CE + compose plugin installed (fresh
cloud image had neither), `ufw`/`qemu-guest-agent` installed and configured (default-allow
incoming per the fleet's own VM clone checklist — internal-VLAN-trust model, nothing NATs inbound
to it from the public internet so this isn't a real exposure), SSH alias `sn-infra` in
`/root/.ssh/config` already existed from before and works cleanly once the old host-key entry
(from the original decommissioned VM, same IP) was purged with `ssh-keygen -R`. Nameserver left at
cloud-init's default `1.1.1.1` — checked hot-erp/hot-pn for a fleet convention and found neither
uses anything HoT-internal either (`127.0.0.53`/`8.8.8.8`), so there's no real convention to match.

**Ntfy deployed (2026-07-26), first service live.** Found the compose file
(`/opt/hot-config/gateway/ntfy/`) had no `ports:` binding at all, and the existing Caddy block used
a bare container-name reference (`reverse_proxy ntfy:80`) that can only work if Caddy and the
container share a Docker network — they don't, Caddy is on the Gateway, ntfy is on sn-infra. This
was latent/never-caught because ntfy was apparently never actually live before the bare-metal
outage. Fixed: added `ports: - "10.10.10.100:8080:80"` (matching CLAUDE.md's documented sn-infra
port table), pointed Caddy at `10.10.10.100:8080` directly (same pattern as the working
`namevault.co.uk` block right above it). `hot-config` commit `b444170`, pushed to github+codeberg
(origin/Forgejo still down at time of this commit — chicken-and-egg, fixed once Forgejo itself
redeploys). Verified end-to-end: `https://ntfy.house-of-trae.com/v1/health` → 200.

**PowerDNS-Admin deployed (2026-07-26).** Keycloak's `pdns-admin` OIDC client (securenexus realm)
was untouched by the whole outage (Keycloak lives on the Gateway, unaffected) — reused its existing
secret directly, no rotation needed. Generated fresh `pdns_admin_secret_key`/`db_user`/
`db_password`/`db_uri`; reused the known PowerDNS API key (`pdnsKj7xM9pL2vR5n` — already documented
in CLAUDE.md). **Real gotcha hit: `printf`-vs-heredoc trailing newline broke the DB connection** —
wrote the `pdns_admin_db_uri` secret via `cat > file <<< "$VAR"` (adds a trailing newline), and
pda-legacy's `SQLALCHEMY_DATABASE_URI_FILE` reader doesn't strip it, so SQLAlchemy parsed the
database name as `"pdnsadmin\n"` and failed to connect. Fixed by rewriting all pdns-admin secret
files with `printf '%s'` (no trailing newline) instead. Caddy block (`dns-admin.house-of-trae.com`
→ `10.10.10.100:9191`) already existed correctly from before, no fix needed there. Verified live:
`https://dns-admin.house-of-trae.com/` → 302 (login redirect), DB migrations ran clean.

**Resolved (confirmed 2026-07-30 sweep):** `tristian` has logged in via OIDC and the account is
promoted to Administrator (`role_id=1` confirmed live in `pdns-admin-db`'s `user` table). No longer
an open item.

**Forgejo deployed (2026-07-26), fresh, and hot-config's own `origin` remote fully restored.**
`FORGEJO__security__INSTALL_LOCK=true` had to be added to the compose (not there before) — without
it, `forgejo admin user create` fails with "Unable to load config file for a installed Forgejo
instance" because the env-var-driven `app.ini` generation doesn't itself set the install-lock flag,
so the CLI still thinks the web installer hasn't run. Ports tightened to the specific-IP-bind
pattern (`10.10.10.100:3000:3000`, `10.10.10.100:2222:22`) matching the rest of the fleet, was
previously unscoped `3000:3000`/`2222:22`. Created `tristian` as the initial admin via CLI (real
generated password — **not yet in Vaultwarden, sitting in this session's scratchpad, needs Mr.
Byrne's `bw unlock` to write it**, same standing pattern as every other vault write). Verified live:
`https://git.securenexus.net/` → 200.

Then, since Forgejo was finally up: registered the Gateway's existing `gateway-vps-hot-config-auto`
SSH key (already referenced by `/root/.ssh/config`'s `forgejo-internal` alias, unused until now),
created the `tristian/hot-config` repo via the API (using a bootstrap admin token — still exists on
the account, scoped `write:admin,write:repository,write:user`, not deleted, consider rotating out
later), and pushed hot-config's full history to it. `git push origin main` now works again for the
first time since the original bare-metal outage — closes the loop CLAUDE.md's own Backup
Architecture table describes (config sync → Forgejo → Codeberg + GitHub mirrors).

**Public git-over-SSH is NOT wired up — deliberately left as an open question, not done.** Checked
before attempting: the Gateway already runs a second sshd on port 2222 for emergency access
(`/opt/hot-config/gateway/ssh/60-emergency.conf`) — forwarding Forgejo's git-SSH (also
conventionally 2222) to the Gateway's public IP on the same port would collide with that. No DNAT/
port-forward mechanism for this currently exists on the Gateway at all. HTTPS clone/push through
Caddy already works fine for anything reachable on the VLAN mesh (i.e. the Gateway itself, and
anywhere over Tailscale/wg — not from the open internet). If public git-SSH access is wanted, it
needs a different public port and a real DNAT rule (or a Caddy `layer4` config) — ask Mr. Byrne
before picking a port.

**Namevault reconstructed and deployed (2026-07-26).** Mr. Byrne chose to reconstruct rather than
hunt further for a source copy. Read the surviving `server.js` fully to infer what was missing:
added `package.json` (express/express-session/connect-pg-simple/pg, ESM), a plain `node:20-alpine`
`Dockerfile`, `init.sql` (single `mappings` table — `real` unique, `pseudo`, `created_by`,
`created_at`, matching exactly what the queries in `server.js` use), and **a brand-new minimal
frontend** (`public/index.html` name-generator form, `public/admin.html` mappings table with
delete+CSV export) since the original UI itself is gone — this is functionally equivalent, not a
recreation of the old design, and Mr. Byrne should know the look is new if he ever compares against
memory of the old one. `hot-config` commit `1c0203f`.

Keycloak's `namegen` client (house-of-trae realm) was untouched by the outage — reused its existing
secret directly. Generated fresh `db_password`/`session_secret`. **`ANTHROPIC_API_KEY` resolved
(confirmed 2026-07-30 sweep)** — a real key (`sk-ant-api03-...`) is live in
`/opt/stacks/namegen/secrets/anthropic_api_key.txt`; no longer a placeholder.

Verified live via `curl --resolve namevault.co.uk:443:151.241.217.91` (TLS SNI trick) rather than
real DNS — `/api/me` correctly returned `{"logged_in":false}`, confirming the whole stack (app →
Caddy → TLS) is genuinely wired correctly.

**Resolved** — the public-resolution gap was actually the DNSSEC DS-algorithm mismatch fixed
2026-07-27 (see [[dnssec_namevault_fix]]), not a registrar delegation problem. Confirmed 2026-07-30:
`dig @8.8.8.8 namevault.co.uk` and a full `+trace` both resolve cleanly end-to-end, including a
correct DS chain at the `.uk`/`co.uk` level.

**All 4 sn-infra services are now live: Ntfy, PowerDNS-Admin, Forgejo, Namevault — no loose ends
remain as of the 2026-07-30 sweep** (PowerDNS-Admin promotion, Namevault's Anthropic key, and public
DNS resolution are all confirmed resolved above). Only remaining item: Forgejo's `tristian` admin
password still isn't saved to Vaultwarden (see below) — needs Mr. Byrne's `bw unlock`.

**Secrets saved to Vaultwarden 2026-07-26**, "House of Trae — Gateway VPS" folder (matching where
hot-bm-nl's own root password lives — these are general infra creds, not PrivateNexus-specific):
- **"sn-infra — Forgejo admin (tristian)"** — login item, username/password for
  `git.securenexus.net`.
- **"sn-infra — PowerDNS-Admin"** — notes field has `db_user`/`db_password`/`secret_key`/`db_uri`,
  the OIDC-promotion SQL command, and a reminder the PowerDNS API key + Keycloak client secret were
  both reused unchanged (not regenerated).
- **"sn-infra — Namevault"** — notes field has `db_password`/`session_secret`, the
  still-a-placeholder Anthropic key location + restart command, and the public-DNS caveat.

Standard one-off pattern: Mr. Byrne ran `bw unlock --raw` himself and shared only the resulting
session token (never the master password); vault locked and token discarded immediately after the
3 writes; the plaintext scratchpad copies of these secrets were deleted right after.

---

**⚠ Real incident 2026-07-27: stopping `pve-cluster` on hot-bm-nl locked out SSH entirely —
root's `authorized_keys` is a symlink into the cluster filesystem.** While starting the queued PVE
node-rename (`proxmox22272.hostkey.in` → `hot-bm-nl`, plan documented in
[[hostkey_server_replacement]]), stopped `pvestatd`/`pveproxy`/`pvedaemon`/`pve-cluster` per the
plan's step 1 — immediately after, the Gateway's SSH key started getting rejected
(`Permission denied (publickey,password)`) even with the connection fully bypassed (explicit
`-i`/`IdentitiesOnly`, no config/agent). Network layer was fine throughout (ping/wg4 handshake
both healthy, VM 100 and all 4 sn-infra services stayed fully reachable — only SSH *to the host
itself* broke). Diagnosed via the Hostkey browser console (Mr. Byrne opened it directly, ran
diagnostic commands, screenshotted the output to `/root/hot/docs/` for me to read): **root's
`/root/.ssh/authorized_keys` is a symlink to `/etc/pve/priv/authorized_keys`** — a real Proxmox
convention (syncs root's keys across cluster nodes via pmxcfs) — and stopping `pve-cluster`
unmounts the `/etc/pve` FUSE filesystem entirely, so the symlink target vanished
(`cat` → "No such file or directory") and sshd had nothing to authenticate against. All 4 stopped
services were confirmed cleanly stopped via the console (`systemctl status`, all `code=exited,
status=0/SUCCESS`) — nothing crashed, disk was fine (1% used) — this was purely the symlink
break, not a real fault.

**Fixed at the cause, not just recovered from:** `systemctl start pve-cluster` on the console
remounted `/etc/pve` and restored SSH immediately (confirmed: `cat authorized_keys` showed the
real key again). Rather than just move on, added resilience so this can't recur: sshd's default
`AuthorizedKeysFile` already checks two paths (`.ssh/authorized_keys .ssh/authorized_keys2`, just
commented out/implicit before) — made it explicit in `/etc/ssh/sshd_config` and populated
`/root/.ssh/authorized_keys2` as a **real local file** (not a symlink) with the same key content,
`chmod 600`. This is additive, doesn't touch PVE's own cluster-key-sync symlink at all — if this
box ever joins a real Proxmox cluster later, that mechanism keeps working unchanged; the local
file is purely a fallback for whenever `/etc/pve` isn't mounted. **Verified the fix for real, not
assumed:** deliberately stopped `pve-cluster` again as a test, opened a completely fresh SSH
connection, confirmed `whoami` succeeded while `pve-cluster` was still down, then restarted it.

**How to apply:** any future work that stops `pve-cluster` on this box (or any Proxmox node found
with the same symlink convention) no longer risks an SSH lockout — but this exact bug class (a
critical access path silently depending on a service being up) is worth checking for before
stopping *any* service on this fleet, not just PVE. If a similar lockout happens again on a
different box, check for symlinks under `/root/.ssh/` or `/etc/ssh/` pointing at paths owned by
whatever was just stopped, the same diagnostic pattern that worked here.

---

**⚠ PVE node rename ABANDONED 2026-07-27 — `mv` on `/etc/pve/nodes/` doesn't behave like a normal
filesystem rename; pmxcfs has custom, non-standard handling that isn't well-understood.** After
fixing the SSH-lockout issue above, resumed the queued rename
(`proxmox22272.hostkey.in` → `hot-bm-nl`) with `pve-cluster` stopped and a local `pmxcfs -l`
session up. `mv /etc/pve/nodes/proxmox22272 /etc/pve/nodes/hot-bm-nl` failed:
`mv: cannot overwrite '/etc/pve/nodes/hot-bm-nl': Directory not empty` — but **`stat` and `ls`
both independently confirmed that path does not exist at all.** Reproduced twice, not a one-off
glitch. This means pmxcfs's FUSE `rename()` handler for node directories doesn't behave like a
POSIX filesystem — it's returning a misleading/generic errno for what's actually some internal
validation or special-cased node-directory logic in pmxcfs's own C code, not a real "destination
exists" conflict. (Separately confirmed there's no genuine leftover directory from the 2026-07-24
aborted attempt either — `ls /etc/pve/nodes/` only ever showed `proxmox22272`, `/etc/pve/local`
correctly still resolved to it throughout.)

**Decision: stopped here rather than push further into behavior that doesn't match documented
expectations**, especially with VM 100 and 4 live production services running throughout. Cleanly
reverted: `hostnamectl set-hostname proxmox22272.hostkey.in` (hostname was already changed as an
earlier step in this same attempt), killed the local `pmxcfs -l` session, restarted the real
`pve-cluster`→`pvedaemon`→`pveproxy`→`pvestatd` stack in order. Verified fully healthy afterward:
`/etc/pve/local` resolves to `proxmox22272` correctly, `qm status 100` running, Proxmox web UI
(localhost:8006) and all 4 sn-infra services (git/dns-admin/ntfy/namevault) confirmed responding
normally.

**How to apply — this reverses the earlier decision to attempt the real rename.** The node stays
`proxmox22272.hostkey.in` permanently; `hot-bm-nl` remains only the Gateway's SSH alias, which
already gives fully consistent access — this was actually the original recommendation before Mr.
Byrne chose to attempt the real rename anyway. **Don't re-attempt this rename without first
researching Proxmox's actual documented/community-supported node-rename procedure in detail**
(this session went in without that research, assuming a plain `mv` would work based on the
directory structure looking like a normal filesystem — it isn't one). If it's ever revisited, do
it as a dedicated research-first task, not a quick follow-on to something else, and strongly
consider whether it's worth the risk at all given `hot-bm-nl` already works fine as an alias.

---

**Remaining sn-infra checklist items closed out 2026-07-27:**
- **TLS certs verified real and valid** for all 4 services (`git.securenexus.net`,
  `dns-admin.house-of-trae.com`, `ntfy.house-of-trae.com`, `namevault.co.uk`) — all genuine
  Let's Encrypt certs, none expired. These were never actually broken; Caddy holds/renews certs
  independently of backend availability.
- **Watchtower added to sn-infra** (`hot-config` commit `a38e59f`), same pattern as the Gateway's
  own (v1.5.3, monitor-only, reused the already-correctly-rotated `WATCHTOWER_SMTP_PASSWORD` from
  `/opt/stacks/watchtower/.env` on the Gateway — that value was fixed 2026-07-03, see
  [[grafana_smtp_password_pending]], only Grafana/sn-monitor's copy is still stale and blocked on
  sn-monitor not existing yet). Namevault's `namegen-app` (locally built, no registry path) got
  the `com.centurylinklabs.watchtower.enable=false` label, matching the same pattern already used
  for PrivateNexus's locally-built services on hot-pn.
- **Forgejo's bootstrap admin API token deleted** (`gateway-bootstrap`, broad
  `write:admin/repository/user` scope, only needed for the one-time SSH-key-registration +
  repo-creation setup) — confirmed `204` on delete via Forgejo's own API.

**Both closed out 2026-07-27:**
- **PowerDNS-Admin admin promotion turned out unnecessary** — Mr. Byrne's first OIDC login already
  landed as `role_id=1` (Administrator) automatically, not the "User" role the CLAUDE.md gotcha
  describes. Checked the `role` table to confirm `1=Administrator/2=User/3=Operator` before
  trusting this — no SQL promotion needed. Worth a note: that documented gotcha may be stale for
  this pda-legacy version, or was specific to a different auto-provisioning path than OIDC.
- **Namevault's Anthropic key installed and verified working end-to-end.** First test after
  installing the real key still failed (`Generation failed` in logs) — traced to the actual
  Anthropic API response (tested directly via curl from sn-infra, not just trusting the app's
  generic error): `"Your credit balance is too low to access the Anthropic API."` The key itself
  was valid, just an empty account. Mr. Byrne added credit at console.anthropic.com → Plans &
  Billing; retested `POST /api/generate` against the real live app afterward and got a genuine
  result (`"Michael Torres"` for input `"John Smith"`) — not just a 200, an actual correct
  generation. `docker compose restart app` is the right command for this stack (service name is
  `app`, container name is `namegen-app` — don't confuse the two, `docker compose restart
  namegen-app` fails with "no such service").

**sn-infra rebuild is now fully complete** — all 4 services live, verified, and functional
end-to-end, no remaining blockers on either side.
