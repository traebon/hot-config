---
name: sn-web-luks-pilot-fix
description: "Root-caused and fixed the sn-web (VM 102) LUKS2+Tang encrypted-install pilot's boot flakiness on hot-bm-nl — 3 real bugs, not randomness. Applies fleet-wide to any future automated preseed install."
metadata:
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-30T00:11:24.848Z
---

**2026-07-27 — the "genuinely unresolved flakiness" documented in [[open_items_2026_07_27]] and
[[sn_security_rebuild]] was fully root-caused, not random.** Across ~5+ attempts (this session's
sn-web pilot, plus the earlier sn-security attempt that abandoned the automated-preseed approach
entirely in favor of a host-chroot build that then failed at GRUB for a separate reason), every
single failure looked different — sometimes "real progress then reverts to SeaBIOS", sometimes
"frozen at `Probing EDD`" — and was assumed to be non-deterministic. **It wasn't.** The apparent
randomness was a diagnostic artifact: QEMU `screendump` (VGA framebuffer) was the only tool used to
inspect these VMs, and the kernel boots with `console=ttyS0` only — meaning VGA output permanently
freezes at the BIOS→kernel handoff on *every single attempt*, regardless of what's actually
happening. Screendump was showing the same dead frame every time and being misread as "sometimes
hangs earlier, sometimes later."

**Fix to the diagnostic method (do this first on any future boot issue with this install
technique):** attach a bidirectional bridge to the VM's serial socket instead of relying on
screendump:
```
socat UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0 PTY,link=/root/<name>-pty,rawer,echo=0 &
cat /root/<name>-pty >> /root/<name>-console.log 2>/root/cat-stderr.log &
```
(Route stderr separately — piping a `socat`/`cat` process's own stderr into the same log file
contaminates it with that process's shutdown messages when killed, breaking later parsing.) The
captured stream is raw ANSI/dialog escape codes (Debian installer's newt UI), unreadable as plain
text — reconstruct the actual screen with `pyte`:
```python
import pyte
screen = pyte.Screen(80, 24)  # standard serial console geometry
stream = pyte.ByteStream(screen)
stream.feed(open('console.log','rb').read())
print('\n'.join(l.rstrip() for l in screen.display if l.strip()))
```
Fractional replay (`stream.feed(data[:cut])` at increasing `cut` values) reconstructs the sequence
of screens across the whole boot, which is how the real blockers below were actually found.

**Bonus discovery: the installer's serial console runs inside GNU Screen** (visible as the
`0 start / 1 installer / 2 shell / 3 shell / 4 log` tab bar). Switch windows by sending `Ctrl-A`
(`\x01`) then the window number into the pty (`printf '\001' > pty; printf '4' > pty`) — window 4
is the live `/var/log/syslog` tail (shows exactly which component/process is running), windows 2/3
are real root shells inside the installer environment itself (`ps w`, manual `wget`, etc. all work
— BusyBox `ps` doesn't take `aux`, just `ps w`). This is far more conclusive than guessing from
outside the VM.

**The three real, fully deterministic bugs found and fixed, in the order they're hit:**

1. **Wrong installer image.** `/var/lib/vz/template/iso/debian12-installer/{vmlinuz,initrd.gz}`
   were netinst-ISO-style files (`install.amd/` from inside a netinst ISO), which run
   `cdrom-detect` expecting physical/virtual CD media — but the VM boots via bare QEMU
   `-kernel`/`-initrd` with no virtual CD-ROM device attached at all, so it always landed on
   "Your installation media couldn't be mounted... Retry mounting installation media?" and sat
   there forever (a real dialog waiting for input, at `priority=critical` — this specific question
   has no automatable default). **Fix:** use the actual **netboot** image variant, built
   specifically for HTTP-only installs with no CD-ROM expectation at all:
   `http://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/{linux,initrd.gz}`
   (~41MB initrd vs. ~22MB for the wrong one — a real, checkable size difference).

2. **DHCP attempted before the preseed file (and its static-IP directives) is even loaded.** The
   very first network bring-up — needed just to *fetch* `preseed.cfg` over `url=` — happens before
   any of that file's own `netcfg/*` values exist, so it defaults to DHCP. None of these internal
   VLANs run a DHCP server (everything is static per CLAUDE.md), so it timed out and landed on
   "Network autoconfiguration failed... `<Continue>`", another real stuck dialog.
   **Fix:** pass the static network config directly on the kernel `-append` line (not just inside
   `preseed.cfg`), using the bare `question=value` cmdline-preseeding form (no `d-i ` prefix,
   applies before templates are registered):
   ```
   netcfg/disable_autoconfig=true netcfg/get_ipaddress=<ip> netcfg/get_netmask=<mask>
   netcfg/get_gateway=<gw> netcfg/get_nameservers=<ns> netcfg/confirm_static=true
   ```

3. **The real, fleet-relevant one: no UFW rule for the ad-hoc preseed HTTP server's port.** Even
   with (1) and (2) fixed, and a genuine `netcfg/link_wait_timeout`-style hang on "Detecting link
   on ens18" worked around by manually sending Enter to its `<Cancel>` button (host-side
   confirmed via `tap<vmid>i0`/`bridge vlan show` that networking was never actually broken — this
   specific d-i dialog for virtio NICs just doesn't self-resolve, Cancel-then-continue is the
   correct, safe action), the install then hung *silently* — no dialog, no syslog output, zero
   guest-side network packets outbound to anything **except** the preseed URL itself, which showed
   real TCP SYN retransmits with exponential backoff (`tcpdump -i vmbr0.30 host 10.10.30.102`) and
   **zero response — no SYN-ACK, no RST**. That signature is a silent firewall DROP, not "port
   closed." Confirmed via `ufw status numbered`: **no rule for port 8091 existed at all** — the
   `python3 -m http.server 8091 --bind 10.10.30.1` was started ad-hoc for this one-off install,
   bypassing the "New Service Deployment Checklist" step that normally adds a UFW allow rule.
   Fixed live with `ufw allow from 10.10.0.0/16 to any port 8091 proto tcp` — the guest's own
   already-in-flight retry succeeded within its next backoff cycle, no VM restart needed.
   **This is almost certainly the exact same root cause that killed sn-security's original
   automated-preseed attempt** ("stuck at 56K written, never diagnosed why" — see
   [[sn_security_rebuild]]), which used the identical pattern (ad-hoc `http.server` on a different
   VLAN gateway IP, likely also missing its own UFW rule) before abandoning that approach entirely
   for a host-chroot build that then failed separately at GRUB.

**How to apply — checklist for any future automated preseed VM install on this fleet:**
1. Use **netboot** debian-installer images, never netinst-ISO-extracted ones, for any
   `-kernel`/`-initrd` boot with no virtual CD attached.
2. Put static network config on the kernel `-append` line directly, not only in `preseed.cfg`.
3. **Add a UFW rule for the preseed HTTP server's port before starting the install** — treat this
   ad-hoc server like any other new service for UFW purposes, don't skip it just because it's
   temporary.
4. If it stalls, attach serial (not screendump) via the `socat`+`pyte` recipe above before
   concluding anything is "randomly" hanging — the real state is almost always fully deterministic
   and readable once you're looking at the right stream.
5. A "Detecting link on ens18" dialog stuck at 0% with a `<Cancel>` button is a known, harmless
   virtio quirk on this QEMU version — cancelling it is the correct action, not a workaround to be
   nervous about; host-side `bridge vlan show`/tap-interface state confirmed real networking was
   never actually broken when this fires.

**Status: COMPLETE AND VERIFIED, 2026-07-27 — sn-web (VM 102) is a genuine, working LUKS2-encrypted
VM, the first success in this entire saga (spanning this session's pilot and the earlier
sn-security host-chroot/GRUB failure).** Full chain verified live, not assumed:
- Install completed cleanly (confirmed via the real `poweroff` message in the serial log, not a
  guess: "The system is going down NOW! ... Requesting system poweroff ... reboot: Power down")
- GRUB boots successfully from the real disk (`boot: order=scsi0`, `-args` override removed after
  the poweroff) — this is the exact step that killed the sn-security host-chroot approach; doing
  `grub-install` from *within the actual guest installer* (not a host-side chroot against the raw
  zvol) avoids that geometry bug entirely
- LUKS passphrase prompt (`Please unlock disk sda5_crypt:`) appears on **VGA (tty0), not
  serial** — the installed system's GRUB_CMDLINE_LINUX has `console=ttyS0,115200n8 console=tty0`
  (added by the preseed's `late_command`), unlike the temporary installer environment which was
  serial-only. Sent via `qm sendkey <vmid> <key>` per character (shift-<letter> for uppercase),
  confirmed by `screendump` afterward — reached a real `sn-web login:` prompt
- SSH confirmed working (Gateway key from `late_command` already in `authorized_keys`),
  `qemu-guest-agent` active, `Debian GNU/Linux 12 (bookworm)`, and the real partition layout:
  `sda5` → `sda5_crypt` (LUKS) → LVM (`sn-web-vg-root`/`sn-web-vg-swap`) — a working encrypted
  root, not a fake pass-through

**4th real bug found and fixed during this final stretch — applies to any future preseed install
using this direct-kernel-boot technique:** the installer defaults to `finish-install/reboot_in_progress`
(a literal reboot) after completing. Since this VM's boot args are hardcoded to always load the
*installer's own* kernel/initrd (`-kernel`/`-initrd` in `qm set --args`), any reboot — including the
installer's own intended "reboot into your new system" — just boots back into the installer instead
of the real disk's GRUB, silently re-wiping and restarting the whole install from scratch. This is
almost certainly what the *original* "sometimes progresses then reverts to a fresh SeaBIOS screen"
symptom in the early flaky-attempts era actually was, not a crash. **Fix:** add
`d-i debian-installer/exit/poweroff boolean true` to the preseed so it halts instead of rebooting —
this gives a clean, safe checkpoint to remove the `-args` override and set `boot: order=scsi0`
*before* ever starting the VM again, so it boots the real installed system instead of looping.

**Sub-gotcha hit while applying this exact fix:** the ad-hoc `python3 -m http.server` serving
`preseed.cfg` was started once and left running continuously across multiple restart attempts —
the restart script's preseed-copy step was guarded by `ps aux | grep 8091 || (...cp...)`, so once
the server was already running, edits to the source preseed file were **never actually copied into
the served file**, silently making two "fixed" restart attempts re-run the exact same old,
unfixed preseed. Caught via a direct `diff` between the two files. **How to apply:** when
iterating on a preseed file served by a long-lived ad-hoc HTTP server, always re-copy the file into
the served location explicitly after every edit — don't rely on a "start if not running" guard to
also mean "content is current."

**Tang/NBDE automatic unlock: DONE AND VERIFIED, 2026-07-27.** sn-web now unlocks its LUKS volume
fully unattended on every boot, no manual passphrase entry — confirmed via a real reboot with zero
keys sent, reaching `sn-web login:`, and confirmed in the logs (`journalctl -u
systemd-cryptsetup@sda5_crypt.service` shows "Volume sda5_crypt already active" — i.e. unlocked in
the initramfs itself, before systemd proper even started; `uptime` showed ~1 minute, ruling out a
stale/cached session).

**Two real gaps had to be closed to get here, beyond just `clevis luks bind`:**

1. **Fleet routing/firewall gaps to both Tang servers, none of which existed for this new
   hot-bm-nl architecture:**
   - Gateway Tang's UFW rule only allowed `10.10.0.0/30` (a leftover from the old bare-metal
     architecture, where all VM traffic was NAT'd through a single tunnel endpoint IP). The new
     hot-bm-nl setup routes real per-VM source IPs directly via wg4's `AllowedIPs` (already
     correctly scoped to each VLAN subnet) — so a VM's real IP (e.g. `10.10.30.102`) was never
     covered by that narrow rule. Widened to `10.10.0.0/16` per the fleet's own standing
     convention. (Old rule left in place, harmless — UFW allow rules are additive.)
   - No direct `vmbr0.30` ↔ `vmbr0.10` forward rule existed on hot-bm-nl at all — the earlier
     sn-monitor rebuild only added VLAN 50 ↔ {10,30,70} rules for its own scrape/log-push needs,
     never a direct 30↔10 path. Added both directions.
   - sn-infra's own UFW had no rule for port 80 (its Tang port) from other VLANs at all. Added
     `ufw allow from 10.10.0.0/16 to any port 80 proto tcp`.
   - **Lesson: reachability to Tang (or any shared service) from a *newly rebuilt* VM on this fleet
     cannot be assumed just because other VMs can reach it** — check the actual path (UFW on both
     ends + forward rules on hot-bm-nl) for each new VLAN pairing, don't assume prior fixes cover
     it.

2. **`clevis luks bind` failed silently (exit 1, zero output) over a non-interactive SSH session**
   — almost certainly an interactive trust-on-first-use (TOFU) prompt for the Tang server's key
   fingerprint that needs a real TTY, which isn't available piping a heredoc over SSH. **Fix:**
   fetch the Tang advertisement explicitly first (`curl http://<tang>/adv`) and embed it directly
   in the Tang config JSON's `"adv"` field before calling `clevis luks bind` — this makes the trust
   decision explicit in the command itself rather than relying on an interactive prompt, and
   succeeds non-interactively every time.

3. **The genuinely hard part, exactly as flagged**: Debian's `clevis-initramfs` hook does **not**
   read the system's `/etc/network/interfaces` for early-boot networking — it uses the kernel's
   built-in IP-Config mechanism, which **defaults to DHCP/RARP** (confirmed live via screendump:
   `IP-Config: ens18 ... DHCP RARP`, retrying with escalating backoff forever since no DHCP server
   exists on these VLANs). **Fix:** add an explicit static `ip=` kernel parameter to
   `GRUB_CMDLINE_LINUX` in `/etc/default/grub`:
   ```
   ip=<client-ip>::<gateway-ip>:<netmask>:<hostname>:<device>:off
   ```
   (empty `server-ip` field, `off` disables DHCP/autoconf entirely, `<device>` needs to match the
   real interface name, `ens18` here). Then `update-grub` + `update-initramfs -u -k all`. This is
   the one change that actually made automatic unlock work — before it, Tang was reachable and
   bound correctly, but the initramfs could never reach it at boot time.

**Full working recipe for the remaining 3 VMs (sn-infra/sn-monitor/sn-security), in order:**
1. Rebuild using the proven 4-point install fix (netboot images, static netcfg on kernel cmdline,
   UFW rule for the preseed server, `debian-installer/exit/poweroff boolean true`)
2. Swap `boot: order=scsi0` + remove the installer `-args` once it powers off cleanly
3. Check/add UFW + forward-rule reachability to both Tang servers from that VM's specific VLAN
   (don't assume it's already open)
4. `apt-get install clevis clevis-luks clevis-initramfs`
5. Fetch each Tang server's `/adv` explicitly, bind both via `clevis luks bind ... -k -` with the
   `adv` embedded in the config JSON (passphrase from that VM's own preseed)
6. Set slot priority (`cryptsetup config --priority prefer --key-slot <gateway-slot>`)
7. Add the static `ip=` kernel parameter (per-VM IP/VLAN) to `/etc/default/grub`, `update-grub`,
   `update-initramfs -u -k all`
8. Reboot and verify with **zero manual input** — check `journalctl -u
   systemd-cryptsetup@<device>.service` for "already active" and confirm real uptime, don't just
   trust that it reached a login prompt once.

---

**sn-infra (VM 100) rebuild: COMPLETE AND VERIFIED, 2026-07-28 — the recipe above worked, plus 5
new fleet-relevant findings not seen on sn-web:**

0. **Live production rebuild, not empty like sn-web/sn-web.** sn-infra runs real services
   (Forgejo/git.securenexus.net, PowerDNS-Admin, Namevault, Ntfy) with **no vzdump backup job
   configured at all on hot-bm-nl** (`pvesh get /cluster/backup` returns empty, `/var/lib/vz/dump`
   is empty — the CLAUDE.md nightly-vzdump table is stale for the post-migration reality). Before
   any rebuild of a live-data VM, manually back up: DB dumps via `docker exec -u postgres <db>
   pg_dump -U <user> <db>` (not plain volume tar — needed a consistent logical dump), data-volume
   tarballs, and **every stack's `secrets/` directory** (`find /opt/stacks -path '*/secrets/*'
   -type f | tar czf ... --null -T -` — but tar preserves the full path including the leading
   `/opt/stacks`, so extracting back into `/opt/stacks` on the rebuilt VM double-nests into
   `/opt/stacks/opt/stacks/...` unless you `tar --strip-components` or extract at `/` instead). Pull
   the backup off-host before wiping — don't trust the doomed disk to hold the only copy of its own
   backup.

1. **A VM hosting Tang for the rest of the fleet cannot bind to itself as fallback — the dual-Tang
   pattern in CLAUDE.md's NBDE table doesn't literally apply to sn-infra's own LUKS volume.** Its
   own Tang server's keys live on its own (about-to-be-unlocked) root filesystem and the `tangd`
   service isn't running yet during initramfs — chicken/egg. sn-infra binds to **Gateway Tang
   only** (single slot), not dual-bound like every other VM. Also: **preserve sn-infra's Tang
   *keys* (`/var/lib/tang/*.jwk`) across the rebuild** and restore them verbatim rather than letting
   a fresh `apt-get install tang` generate new ones — otherwise every *other* VM's existing slot-2
   fallback binding (which references the old key's thumbprint) silently breaks. Back up
   `/var/lib/tang/*.jwk` before wipe, restore + `chown _tang:_tang` + `chmod 440` after, then
   reapply the `tangd-socket-override.conf` (binds to the VM's real IP, not `0.0.0.0`) and
   `systemctl restart tangd.socket` (not just `daemon-reload` — a running default-bound socket
   needs a real restart to pick up the override, `systemctl status` misreports "active" even when
   genuinely broken here).

2. **`console=tty0` in `GRUB_CMDLINE_LINUX` is actively harmful on any VM whose Proxmox config has
   `vga: serial0` instead of `vga: std`.** sn-web has a real VGA device (`vga: std`) so `console=tty0`
   correctly gave it a *second*, VGA-based console for the LUKS prompt (interacted with via `qm
   sendkey`+screendump). sn-infra has **no VGA device at all** (`vga: serial0` — Proxmox routes
   BIOS/GRUB/kernel output through the serial chardev directly, there's no real framebuffer). Adding
   `console=tty0` there makes `/dev/console` resolve to a console driver that can't actually
   initialize, so the LUKS passphrase prompt (and kernel output generally) goes silently nowhere —
   looks identical to a hung boot (kernel prints "Loading initial ramdisk..." then nothing forever,
   CPU usage drops to idle as if parked). **Check `qm config <vmid> | grep vga` before reusing the
   late_command's grub sed** — if it says `serial0`, keep `GRUB_CMDLINE_LINUX="console=ttyS0,115200n8"`
   alone, don't add `console=tty0`. If already burned onto a fresh install and stuck, fix it offline:
   `qemu-nbd --connect=/dev/nbdN -f raw /dev/zvol/.../vm-X-disk-0`, `cryptsetup luksOpen
   /dev/nbdNp5 tmproot -` (plain passphrase still works pre-Tang-bind), `vgchange -ay`, mount root +
   boot, sed `/etc/default/grub`, `chroot` + `update-grub`, unmount everything, `qemu-nbd
   --disconnect`. This is also a much easier console to work with once fixed — pure serial, no
   `qm sendkey`/screendump needed at all, just the same `socat`+pty bridge used for the installer.

3. **The serial socket (`/var/run/qemu-server/<vmid>.serial0`) only exists while the VM is running
   — `socat UNIX-CONNECT` must attach *after* `qm start`, not before.** Attaching before start (or
   leaving stale bridge processes running across a `qm stop`) makes `socat` exit immediately/silently
   with nothing to show for it; this looked exactly like "no console output at all" and cost real
   time before checking `ps aux` showed the processes had already died. Always: `qm start`, `sleep
   2`, confirm the socket file exists, *then* attach socat+cat.

4. **`clevis luks bind` (the top-level dispatcher script) silently failed (exit 1, no output) with
   an embedded-`adv` config that worked fine everywhere else** — `clevis encrypt tang` with the
   identical config succeeded immediately, proving the config/connectivity was never the problem.
   Root-caused by re-running through `bash -x /usr/bin/clevis-luks-bind` (the actual slot-binding
   script, bypassing the `clevis luks bind` pin-dispatch wrapper) with the same arguments **but
   options ordered before the positional `PIN CFG` args** (`-d DEV -y -f -k - tang CONFIG` instead
   of `-d DEV tang CONFIG -y -k -`) — this succeeded and is now confirmed live (`clevis luks list`
   shows the real binding). Root cause not fully isolated (wrapper dispatch vs. arg ordering), but
   **the reliable working form is: all flags before the `PIN CFG` positionals, invoke
   `clevis-luks-bind` if `clevis luks bind` fails silently.**

5. **Fresh netboot+preseed installs have no UFW at all** (`pkgsel/include` only ever specified
   `qemu-guest-agent openssh-server` — this affects sn-web too, confirmed and fixed live the same
   session). Cloud-init-templated rebuilds (sn-monitor, sn-security) came with UFW pre-installed,
   default-allow-incoming/outgoing + deny-routed + logging low (this fleet's real convention is
   permissive-by-default UFW with specific allow rules layered on for documentation/defense-in-depth
   — VLAN isolation + Gateway-level Caddy/CrowdSec is the actual perimeter, not per-VM UFW). Add to
   the recipe: **step 9 — `apt-get install ufw`, set `default allow incoming/outgoing`, `default deny
   routed`, `logging low`, add any service-specific `/16` rules the VM needs (e.g. Tang's port 80 on
   sn-infra), `ufw enable`.**
6. **`d-i netcfg/get_hostname` from the preseed didn't actually stick** — post-install `hostname`
   read back as the Debian installer's own fallback (`debian`), not the configured value, and
   `/etc/hosts` still mapped the VM's IP to `debian` too. Cause not isolated (worked fine as a kernel
   cmdline override on sn-web's *install-time* netcfg — this is the *final installed system's*
   persisted hostname, a separate d-i step). Just fix it directly post-install: `echo <name> >
   /etc/hostname; sed -i 's/<old>/<name>/' /etc/hosts; hostnamectl set-hostname <name>`.

**Services restored from the pre-rebuild backup, verified working with real data, not just
"container is up":** Forgejo (real DB dump restore, `git.securenexus.net` returns real repo data,
not an empty instance), PowerDNS-Admin (DB restored, dashboard reachable), Namevault (DB init script
already recreated its — genuinely empty — schema, dump restore was a no-op for real data, confirmed
0 rows in both old and new so nothing lost), Ntfy (data volume tarball restored into the fresh named
volume). All 4 verified reachable **externally through Caddy** (real `https://` URLs, not just
`curl localhost` on the VM itself) post-restore, not just that the containers started.

**Updated full working recipe for sn-monitor/sn-security (the remaining 2 VMs), incorporating all
of the above:**
1. **If the VM has live data with no automated backup coverage** (check `pvesh get /cluster/backup`
   on hot-bm-nl first — it's currently empty fleet-wide): back up DB dumps (`pg_dump`, not raw
   volume copies), data volumes, and secrets directories off-host *before* touching anything.
2. Check `qm config <vmid> | grep vga` — if `serial0` (no real VGA), do **not** add `console=tty0`
   to the late_command's grub sed, keep `console=ttyS0,115200n8` alone.
3. Rebuild using the proven 4-point install fix (netboot images, static netcfg on kernel cmdline,
   UFW rule for the ad-hoc preseed server, `debian-installer/exit/poweroff boolean true`).
4. Swap `boot: order=scsi0` + remove the installer `-args` once it powers off cleanly.
5. Start the VM *first*, confirm `/var/run/qemu-server/<vmid>.serial0` exists, *then* attach the
   `socat`+`cat` bridge — not the other way round.
6. Fix `/etc/hostname` + `/etc/hosts` manually post-install if `hostname` doesn't match what the
   preseed specified.
7. `apt-get install ufw`, configure to the fleet's permissive-default convention, `ufw enable`.
8. Check/add UFW + forward-rule reachability to both Tang servers from that VM's specific VLAN.
9. `apt-get install clevis clevis-luks clevis-initramfs`.
10. Fetch each Tang server's `/adv` explicitly; bind via `clevis-luks-bind -d DEV -y -f -k - PIN
    CFG` (flags before positionals — fall back to this if `clevis luks bind` fails silently).
11. Set slot priority for the preferred (Gateway) binding.
12. Add the static `ip=` kernel parameter, `update-grub`, `update-initramfs -u -k all`.
13. Reboot with **zero manual input**, verify via `journalctl -u
    systemd-cryptsetup@<device>.service` ("already active") + real uptime.
14. If the VM had live data: restore DB dumps/volumes/secrets, bring services up, verify **through
    Caddy from outside**, not just `docker ps`.

---

**sn-security (VM 106) rebuild, 2026-07-28 — 6th real bug found, the inverse of finding
#2 above:** the installer's own kernel `-append` line (not the late_command's post-install grub sed)
must *also* explicitly include `console=ttyS0,115200n8` on any VM with `vga: serial0`. Omitting it
(as this attempt initially did — copied the netcfg/partman/passwd preseed values but forgot the
console= parameter on the raw kernel cmdline itself) doesn't produce a dialog or an error: the
installer kernel defaults its console to `tty0`, which doesn't exist as a real device on a
`vga:serial0` VM, so **all** boot/installer output vanishes silently — zero bytes ever reach the
serial socket, indefinitely. This is easy to mistake for a genuinely hung/crashed install because
the QEMU process itself looks completely alive and busy (confirmed live: 13+ minutes of real
accumulated CPU time, consistent with partman-crypto's disk-wipe/LUKS-format work actually
proceeding) — **the giveaway that it's a console-routing bug, not a real hang, is real sustained CPU
burn with total silence on serial, not an idle/parked process.** Fixed by `qm stop`, adding
`console=ttyS0,115200n8` at the front of the installer `-append` line, `qm start` again — output
resumed immediately (confirmed via `wc -c` on the console log jumping from 0 to 1.2MB within
seconds of reattaching). **Added to the checklist: step 3's "proven 4-point install fix" needs a
5th point — put `console=ttyS0,115200n8` on the *installer's* kernel `-append` line itself for any
`vga:serial0` VM, not only in the late_command's post-install `/etc/default/grub` edit.** Restarting
an install this early (before partman has actually written a LUKS header/filesystem) is safe — nothing
of value exists yet to lose.

**7th real bug — hot-bm-nl hangs at SMP bring-up above 2 vCPUs, both in the installer and the final
installed kernel.** After the console fix above, the installer still hung — this time genuinely, not
a routing artifact — at kernel uptime ~2.16s, mid-PCI-enumeration, with sustained ~100% CPU and zero
further console output ever. Diagnosed via the same `socat`+pyte recipe, but the raw trace needed an
extra regex pass first: `socat -v`'s verbose mode interleaves data bytes with timestamped
`[<>] yyyy/mm/dd hh:mm:ss.ffffff  length=N from=X to=Y` header lines directly in the byte stream —
these have to be stripped (`re.split(rb'[<>] \d{4}/\d{2}/\d{2} [\d:.]+  length=\d+ from=\d+ to=\d+\n',
data)`, rejoin the remaining chunks) before feeding the result to `pyte`, or the reconstructed screen
is garbage. VM 106 was configured `cores=4` (matching CLAUDE.md's documented sn-security spec) — the
proven fix was simply `cores=1` (installer immediately progressed to real interactive dialogs), and
after a full clean install completed, **the identical hang recurred at `cores=4` on the real installed
kernel**, confirming this isn't installer-specific. `cores=2` was then tested and works reliably for
both the installer and the final system. Not root-caused to a specific mechanism, but the timing
(hang lands during early PCI enumeration, i.e. right as secondary CPUs are being brought up and
devices probed) and the fact that this is a nested-virt oVirt VPS (not real hardware) point at
something in QEMU/KVM's SMP bring-up path under nested virtualization on this specific host — possibly
interacting with the `-cpu host,+kvm_pv_eoi,+kvm_pv_unhalt` flags Proxmox injects automatically for
KVM paravirt features (not exposed via `qm set --cpu`, so not directly tunable without editing
Proxmox's own VM-start code path). **Resolved 2026-07-28**: deep-dived via a disposable test VM +
`qm monitor`'s `info registers -a` (proved a genuine kernel-level spin loop, constant RIP, not a
QEMU/hypervisor freeze) and systematically ruled out CPU model, topology, x2apic, hpet, maxcpus, and
ACPI as the trigger — root cause is QEMU/ACPI declaring >2 vCPUs exist at all, independent of guest
usage, most likely a limit of this host's double-nested virtualization depth
(Hostkey hypervisor → hot-bm-nl as their VM → Proxmox/KVM inside that → our VMs), not fixable from the
guest or Proxmox side. Mr. Byrne decided to keep `cores=2` permanently rather than pursue a Hostkey
ticket — real-world load on sn-security's 2 cores measured at 0.06–0.21, negligible. CLAUDE.md's
sn-security spec and VM allocation table updated to match (2026-07-28). Add to
the checklist: **if a fresh install or a real installed kernel on hot-bm-nl hangs early in boot with
sustained CPU burn and zero console output regardless of the console= fix above, suspect the vCPU
count first — retry at `cores=2` or `cores=1` before assuming a different bug.**

**8th real bug — Wazuh's compose file uses a `.env` file for its 3 core passwords, not the fleet's
usual Docker-secrets/`secrets/` pattern, and this was missed in the pre-rebuild backup.** Every other
stack in the fleet uses `chmod 644` files under a `secrets/` directory referenced via Docker's
`secrets:` block — the pre-rebuild backup script for sn-security only thought to tar up `secrets/`
directories and missed that `/opt/stacks/wazuh/docker-compose.yml` instead substitutes
`${WAZUH_INDEXER_PASSWORD}`/`${WAZUH_DASHBOARD_PASSWORD}`/`${WAZUH_API_PASSWORD}` from a plain `.env`
file (gitignored, never captured). This surfaced only after the restore, as a **~2-hour-long silent
failure**: the dashboard came up, looked alive, but every request failed with
`[ConnectionError]`/`[ResponseError]`, and the indexer logs showed `Authentication finally failed for
kibanaserver` — the manager/dashboard containers were running with empty/unset password env vars
against an indexer that still had the real restored password hashes. Fixed by recreating
`/opt/stacks/wazuh/.env` from the credentials CLAUDE.md already documents (sourced from Vaultwarden
originally), `chmod 600`, `docker compose up -d` to recreate just the manager+dashboard containers.
**Add to the pre-rebuild backup checklist: check every stack's compose file for `.env`/`env_file:`
usage, not just `secrets:` blocks — grep `docker-compose.yml` for `\${` substitutions and back up
whatever file resolves them, per-service, don't assume the `secrets/`-directory pattern is universal.**

**Status: COMPLETE AND VERIFIED, 2026-07-28 — sn-security (VM 106) is a genuine, working
LUKS2+Tang-encrypted VM,** superseding the earlier abandoned host-chroot/GRUB-failure attempt
documented in [[sn_security_rebuild]]. Full chain verified live: Tang auto-unlock, Wazuh SIEM
(manager+indexer+dashboard, `_cluster/health` green, real historical indices including
`wazuh-alerts-4.x-2026.07.27` proving genuine data restore not a fresh install) reachable both
locally and externally through Caddy (`https://wazuh.house-of-trae.com` → 200), and Forgejo runner
re-registered and polling. This closes the full 4-VM LUKS2+Tang retrofit sequence
(sn-infra → sn-web → sn-monitor → sn-security).

**Deep-dive investigation into the cores>2 SMP hang, 2026-07-28 (Mr. Byrne asked to investigate
rather than just accept cores=2) — root-caused to the exact trigger, but not fixable from any
guest- or Proxmox-side knob tested.** Reproduced reliably and safely on a disposable throwaway VM
(199, no disk, netboot kernel only, destroyed after testing — never touched the live sn-security
VM) to isolate the variable systematically:

- **First correction: the `proxmox` SSH alias is stale**, still pointing at the old decommissioned
  bare-metal host's dead wg0 tunnel (`10.10.0.2`) — hangs/times out. Use the `hot-bm-nl` alias
  (`10.10.3.2`, over wg4) for anything on the actual current Proxmox host. Worth fixing in
  `/root/.ssh/config` at some point; not done as part of this investigation since it's an unrelated
  cleanup.
- **Confirmed via `qm monitor`'s `info registers -a`, not just symptom-matching**: the BSP (CPU#0)
  is genuinely spinning in a tight loop (RIP constant, RBP — a loop counter — incrementing every
  poll, HLT=0, ~70-110% sustained CPU matching the vCPU-count-dependent total), not stuck in a real
  hang or waiting on I/O. Host-side `dmesg` shows zero KVM/QEMU-level errors or warnings for the
  entire hang window — this is invisible to the hypervisor, confirming it's purely a guest-kernel
  code path issue, not a QEMU/resource problem.
- **Systematically ruled out every guest/VM-config variable that could plausibly cause this**,
  each tested by direct reproduction (not inferred): `cpu=host` vs `cpu=kvm64` (identical failure —
  not CPU-model/passthrough related), `cores=4` vs `sockets=4,cores=1` topology (identical — not a
  cores-vs-sockets APIC-ID computation bug), `nox2apic` kernel param (identical — not x2apic
  emulation specifically), `acpi=off` (identical, though this test is weaker evidence since
  disabling ACPI entirely changes how Linux discovers CPUs at all), and `hpet=off` vs default
  (identical — a real, confirmed config difference between the disposable test VM and production
  VMs, traced to `ostype: l26` triggering PVE's automatic `hpet=off` machine flag — but adding it
  back made no difference).
- **The single most important finding: `maxcpus=2` as a kernel boot parameter (with QEMU still
  configured for 3 vCPUs) hangs identically.** This proves the trigger is **not** actually starting
  additional APs via INIT-SIPI — Linux never even attempts to bring up the 3rd CPU under this
  parameter, and it hangs anyway, in the exact same BSP spin location (confirmed via `qm monitor`:
  CPU#2 stays parked in real-mode wait-for-SIPI, exactly as expected when never started, while CPU#0
  spins regardless). **The bug fires purely from QEMU/ACPI declaring more than 2 CPUs to exist,
  independent of whether the guest kernel ever tries to use them.**
- **Conclusion: this is very likely a genuine limitation of hot-bm-nl's double-nested
  virtualization depth** (Hostkey's own real hypervisor → hot-bm-nl itself as an oVirt-managed VM,
  with `nested=Y` confirmed on `kvm_intel` → Proxmox/KVM running *inside that* as the actual
  effective L1 → our VMs as L2 guests), most plausibly in how the L0/L1 stack constructs or exposes
  synthetic ACPI/MADT CPU-topology data to a doubly-nested L2 guest once more than 2 logical CPUs
  are declared. This class of bug is a known category in nested-KVM setups generally and is not
  something fixable via Proxmox VM config, kernel boot parameters, or CPU model selection — a real
  fix would need either an L0-level change (Hostkey's own hypervisor/microcode, out of HoT's
  control) or avoiding >2-vCPU configs on this host entirely.
- **Recommendation given to Mr. Byrne: accept `cores=2` for sn-security permanently** (or any future
  VM on hot-bm-nl needing more than 2 vCPUs) unless/until Hostkey support confirms a host-side fix —
  this was a genuinely thorough attempt, not a shortcut, and there is no further guest-side lever
  left to try. **How to apply if this resurfaces on a future VM**: don't re-investigate from
  scratch — this file has the full ruled-out list; the fastest diagnostic is `qm monitor <vmid>` →
  `info registers -a` during the hang to confirm the same signature (constant RIP, incrementing loop
  counter, HLT=0 on the BSP) before assuming a different cause.
