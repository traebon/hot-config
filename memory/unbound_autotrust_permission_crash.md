---
name: unbound-autotrust-permission-crash
description: Gateway VPS unbound container crash-looped (5655 restarts) from a bad auto-trust-anchor-file path; fixed 2026-07-06
metadata: 
  node_type: memory
  type: project
  originSessionId: 1aa380aa-26bb-48ef-980e-9cc4db9670ff
---

Fixed 2026-07-06: `unbound` on the Gateway VPS was crash-looping (5,655 restarts) because `unbound.conf` set `auto-trust-anchor-file: /opt/unbound/etc/unbound/root.key` — the chroot root, which is owned by `root:root` in the `mvance/unbound` image. Unbound drops privileges to `_unbound` after binding, so every RFC 5011 trust-anchor write attempt (including the very first one at startup) hit `Permission denied` and unbound treated it as fatal, exiting immediately.

**Why:** The image's own entrypoint script already `chown`s `/opt/unbound/etc/unbound/var/` to `_unbound:_unbound` and seeds it via `unbound-anchor` specifically so RFC 5011 auto-updates have a writable target — the stack's custom config bypassed that by mounting `root.key` directly into the root:root chroot dir instead.

**Fix applied:** In `/opt/stacks/unbound/unbound.conf`, `auto-trust-anchor-file` → `"var/root.key"` (relative, inside the writable `var/` dir). Removed the now-unnecessary `./root.key:/opt/unbound/etc/unbound/root.key:rw` bind mount from `compose.yml`, and deleted the stale host-side `root.key` file. Recreated the container — confirmed 0 restarts, `healthy`, resolving queries correctly (tested via `dig @unbound` from another container on `hotinfra_internal`).

**How to apply:** If unbound (or any other `mvance/unbound`-based stack, e.g. if cloned to another VM) starts crash-looping with no visible logs, check `docker logs` won't show it — by default this image switches logging to syslog once past the debug banner, which is a black hole in this container (no syslog daemon). Diagnose by running the entrypoint manually with `use-syslog: no` and high verbosity to see the real fatal error. Don't bind-mount a custom `root.key` into the chroot root — always point `auto-trust-anchor-file` at `var/root.key` and let the built-in `unbound-anchor` bootstrap handle it.
