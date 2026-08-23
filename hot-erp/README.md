# hot-erp — overview

**Corrected 2026-08-23** — this file previously described the *temporary* erp-temp/Hostinger
stand-in (46.202.129.86) as if it were still current. It isn't. ERPNext's permanent home since
2026-08-01 is **hot-erp-nl** (Hostkey NL, server 41614, 151.243.173.46), reached over the
dedicated `wg5` tunnel (10.10.4.1 Gateway / 10.10.4.2 hot-erp-nl, port 51825) — see CLAUDE.md's
`services-hoterp.md` for the full current state. The old Hostinger box and its `wg2` tunnel were
torn down 2026-08-03 and the account is cancelled; `sn-business` (the original bare-metal home)
will never be rebuilt — its role moved permanently to hot-erp-nl/hot-pn.

Stack-specific docs live in subdirectories:

- `dickson/README.md` — the actual ERPNext/Dickson Supplies stack: setup, data-restore history,
  and the (now-moot) revert-to-bare-metal plan, corrected the same day as this file
- Monitoring (node-exporter + Prometheus, deployed 2026-08-08) has its own local READMEs under
  `node-exporter/` and `prometheus-local/` — deliberately not wired into sn-monitor's central
  Prometheus, see CLAUDE.md for why
