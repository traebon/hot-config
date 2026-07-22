# erp-temp — overview

Temporary ERPNext stand-in VPS (46.202.129.86) while sn-business stays behind the dead bare-metal
host — see [[hostkey_server_replacement]] for the full story. Stack-specific docs live in
subdirectories:

- `dickson/README.md` — the actual ERPNext/Dickson Supplies stack: setup, data-restore history,
  and the revert plan back to sn-business
- Monitoring (node-exporter + Promtail, added 2026-07-22) has no local README — it's documented
  from the pn-vps side in `../pn-vps/monitoring-temp/README.md`, since that's the actual hub these
  feed into over the cross-tunnel route through the Gateway. Check there for setup detail and the
  teardown steps.
