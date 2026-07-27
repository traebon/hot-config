# Tang server on sn-infra

NBDE fallback Tang server (Gateway's own Tang at 10.10.0.1:7500 is the preferred slot;
this is the fallback, matching CLAUDE.md's documented dual-binding pattern).

Setup: `apt-get install tang`, drop `tangd-socket-override.conf` into
`/etc/systemd/system/tangd.socket.d/override.conf`, `systemctl daemon-reload`, then
**`systemctl restart tangd.socket`** — not just `enable --now`. If the package's own postinst
already auto-started the socket with its default (0.0.0.0:80) binding before the override is
applied, a `daemon-reload` alone leaves it in a broken "Socket unit configuration has changed
while unit has been running, no open socket file descriptor left" state until an explicit restart.
Hit this live on 2026-07-27 — always verify with `ss -tlnp | grep :80` after setup, not just
`systemctl status` (which reported "active (listening)" even while genuinely broken).

Keys live in `/var/lib/tang/` on sn-infra itself — not backed up here (matches the Gateway's own
Tang key handling, keys are host-local and regenerated if truly lost, VMs would just need
rebinding).
