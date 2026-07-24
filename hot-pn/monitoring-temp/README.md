# pn-vps monitoring-temp — temporary fleet monitoring hub

Built 2026-07-15 as a local-only Prometheus + Loki + node-exporter + Promtail stack so
PrivateNexus's own health-scheduler/dashboard had something reachable to query while `sn-monitor`
(the real fleet Prometheus/Grafana/Loki/Uptime Kuma, one of the 7 VMs behind the dead bare-metal
host — see [[hostkey_server_replacement]]) stays unreachable. Originally monitored pn-vps only.

## 2026-07-22 — extended to also cover erp-temp

Mr. Byrne asked how to get "the fleet" to pick up erp-temp/pn-vps/hot-bm-nl while sn-monitor is
down. Rather than build a second hub on the Gateway (would violate the Gateway's "no databases"
rule) or leave it fully manual, extended this stack to also scrape erp-temp's node-exporter and
ingest erp-temp's container logs via Promtail, over a new narrowly-scoped cross-tunnel route
through the Gateway (erp-temp and pn-vps each only have a WireGuard tunnel back to the Gateway, no
path to each other directly).

**What changed, across three hosts:**

- **Gateway VPS**: two `ufw route allow` rules (`wg3→wg2` for port 9100, `wg2→wg3` for port 3100 —
  see the Gateway's own `ufw status numbered` for the exact rules, both commented). Note
  `DEFAULT_FORWARD_POLICY=ACCEPT` in `/etc/default/ufw` does **not** mean generic forwarding
  already works — the live `ufw-after-forward` chain was empty and raw `FORWARD` policy is `DROP`;
  always check the real iptables chains, not `ufw status verbose`'s summary label.
- **erp-temp** (`/etc/wireguard/wg2.conf`): peer `AllowedIPs` widened from `10.10.1.1/32` to add
  `10.10.2.2/32` (pn-vps's tunnel IP), so erp-temp can route promtail's log-push traffic through
  the Gateway to pn-vps. Plus a UFW rule: `allow from 10.10.2.2 to any port 9100 proto tcp`. Plus
  new `/opt/stacks/node-exporter/` (compose, `network_mode: host`, bound to
  `10.10.1.2:9100` specifically — not `0.0.0.0`) and `/opt/stacks/promtail/` (compose,
  `network_mode: host`, pushes to `http://10.10.2.2:3100/loki/api/v1/push`, static `host: erp-temp`
  label).
- **pn-vps** (`/etc/wireguard/wg0.conf`): peer `AllowedIPs` widened to add `10.10.1.2/32`
  (erp-temp's tunnel IP), alongside the `10.10.0.1/32` already there from the 2026-07-15 PowerDNS
  reachability fix. Plus a UFW rule: `allow from 10.10.1.2 to any port 3100 proto tcp`. Plus this
  directory's `docker-compose.yml` gained a `loki-external` network (plain bridge, non-internal)
  attached to **both** `loki` and `prometheus` — see the gotcha below — and a `ports:` publish on
  `loki` bound to `10.10.2.2:3100`. `config/prometheus.yml` gained a second `node-exporter` job
  target (`10.10.1.2:9100`, `instance: erp-temp`).

**⚠ The real gotcha, worth remembering for any future edit to this stack:** the original
`compose_pn-internal` network this stack lives on is `internal: true` (deliberate isolation).
Docker silently accepts a `ports:` directive on a container attached only to an internal network —
`docker inspect`'s `HostConfig.PortBindings` even shows the intended mapping — but nothing actually
binds: no `docker-proxy`, no DNAT rule, `NetworkSettings.Ports` stays `null`. Internal networks have
no gateway at all. Hit this twice in the same session: once for `loki` (inbound — the port publish
above), once for `prometheus` (outbound — its own scrape of erp-temp failed with `network is
unreachable`, since the container had no route out at all, even though the pn-vps *host* itself
could reach erp-temp fine over its own routing table). **Fix for both was the same: give the
container a second, non-internal network (`loki-external`) alongside its existing internal-network
membership.** If a future service on this stack needs to talk to anything off-box, it'll need the
same second network — don't try to publish a port or reach out directly from a container that's
only on `compose_pn-internal`.

## Revert / teardown (once sn-monitor is restored)

1. Remove the 2 `ufw route allow` rules on the Gateway (`ufw status numbered`, delete by rule
   number — they're commented, easy to find)
2. Remove the per-host UFW rules: `ufw delete allow from 10.10.2.2 to any port 9100 proto tcp` on
   erp-temp, `ufw delete allow from 10.10.1.2 to any port 3100 proto tcp` on pn-vps
3. Narrow both `AllowedIPs` back down: erp-temp's `wg2.conf` peer back to `10.10.1.1/32` only,
   pn-vps's `wg0.conf` peer back to `10.10.2.1/32, 10.10.0.1/32` (keep the PowerDNS one, only drop
   the erp-temp addition)
4. `cd /opt/stacks/node-exporter && docker compose down` and `cd /opt/stacks/promtail && docker
   compose down` on erp-temp, then `rm -rf` both directories
5. On pn-vps: drop the `loki-external` network + `ports:` block from `loki`, and drop
   `loki-external` from `prometheus`, in this directory's `docker-compose.yml`; remove the
   `erp-temp` target from `config/prometheus.yml`; `docker compose up -d` to apply
6. If hot-bm-nl ever got added to this same hub in the meantime (not done as of 2026-07-22 — it's
   still stuck mid-reinstall, see [[hostkey_server_replacement]]), repeat steps 1-4 for its `wg4`
   tunnel too before considering this fully torn down
