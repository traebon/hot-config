# hot-edge-ch CrowdSec

Independent CrowdSec instance on hot-edge-ch (not shared with the Gateway's own CrowdSec).
`crowdsec_config` is a named Docker volume, **not** bind-mounted from this directory — same
pattern as the Gateway's own CrowdSec (see `operational-rules.md`'s CrowdSec self-ban rule for the
precedent). Any future edit to `notifications/http.yaml` or `profiles.yaml` must be written
directly into the live container/volume first, then copied back here to keep this tracked copy
current — it will not sync the other way.

## CrowdSec-to-Ntfy alerting, wired 2026-09-16

Mirrors the Gateway's own `hot-alerts` Ntfy topic, same shared bearer token, but posts to the
**public** `https://ntfy.house-of-trae.com/hot-alerts` URL rather than the internal `http://ntfy:80/...`
hostname the Gateway uses — hot-edge-ch is a different host with no access to the Gateway's internal
Docker network. Title/message body both carry a `[hot-edge-ch]`/`(hot-edge-ch)` prefix so alerts
from this instance are distinguishable from the Gateway's own in the same topic.

`profiles.yaml` shipped with `notifications:` (and every entry under it) fully commented out by
default — enabling `http_default` required uncommenting the parent `notifications:` key itself, not
just the one list line, or the list item becomes a dangling, unparented top-level YAML node and
breaks the profile.

Verified end-to-end with a real disposable test ban (`cscli decisions add --ip 203.0.113.99
--duration 1m`, reserved TEST-NET-3 address) — confirmed the real Ntfy message arrived
(`[hot-edge-ch] 203.0.113.99 banned (1m) — ...`), then removed the test decision.

To reload after any future edit: `cd /opt/stacks/crowdsec && docker compose restart crowdsec` on
hot-edge-ch, then check `docker logs crowdsec` for `registered plugin http_default` with no parse
errors.
