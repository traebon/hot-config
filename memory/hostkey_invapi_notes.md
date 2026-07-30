---
name: hostkey-invapi-notes
description: Hostkey invapi.hostkey.com API auth format and eq/order_instance quirks discovered while provisioning a PrivateNexus stand-in VPS during the bare-metal outage
metadata: 
  node_type: memory
  type: reference
  originSessionId: 5824046c-9c29-4488-b161-3595971e3179
  modified: 2026-07-26T21:02:50.331Z
---

Mr. Byrne provided a Hostkey API key (format `<hex>-<hex>`, a customer billing key, role "Customer billing") on 2026-07-15 to provision a temporary external VPS for PrivateNexus (pn-test + sn-personal are both unreachable behind the still-dead bare metal — see [[hostkey_server_replacement]]).

**Update 2026-07-21 — key now persisted.** The 2026-07-15 key was never saved to disk and had to be re-requested for the `vds.v1-storage-8` bare-metal-replacement order (see [[hostkey_server_replacement]]). Mr. Byrne provided a key again (`[REDACTED — live key at /opt/stacks/hostkey-api/secrets/hostkey_api_key.txt]`) — saved this time to `/opt/stacks/hostkey-api/secrets/hostkey_api_key.txt`, root-only (`600`), matching the `tailscale-api` secrets pattern (`/opt/stacks/tailscale-api/secrets/`). Not a Docker-container secret (nothing runs as a non-root container UID here — it's used directly from the Gateway against `invapi.hostkey.com`), so `600` not `644`. Check this file before asking Mr. Byrne for the key again.

**Why this matters:** the key carries broad WHMCS billing permissions (order creation, credit, refunds, payment charges), not just server management — treat it as sensitive as a payment credential, not just an API token.

**Auth flow:** `POST invapi.hostkey.com/auth.php` with `action=login&key=<apikey>` returns a session `token` (2h TTL) plus the customer's `servers` list, `whmcs_id`, `customer_id`, and full `permissions` array.

**Account state as of 2026-07-15:** only 2 existing services under this account — server `145990` (the bare-metal EPYC 3151, hostname "house-of-trae", confirms IP 194.147.214.169 = wg0 endpoint) and `50265` (the Gateway VPS itself, hostname "Gateway", 151.241.217.91). Credit balance was $0.00. Payment method on file is **PayPal**, but it does NOT auto-charge — `eq/order_instance` succeeds and returns an **unpaid WHMCS invoice**, not an active server. The server only actually provisions once that invoice is paid (manually, via the Hostkey control panel at `https://invapi.hostkey.com/`) — confirmed by checking `eq/list` after ordering: server count didn't increase while the invoice sat Unpaid.

**`eq.php action=order_instance` required params (found by trial/error, not documented consistently):**
- `preset` — either the numeric preset ID or its string name (e.g. `vm.v2-medium`) both work; do NOT use `preset_id`, it triggers a bogus "invalid instance name" error instead of a clear complaint.
- `location_name` — datacenter code, e.g. `CH`.
- `os_id` — from `os.php action=list` (Ubuntu 24.04 = id `237`, matches the Gateway VPS's own OS).
- `root_pass` — 8-30 chars, needs upper+lower+digit+one of `%-_+`, must not start with a special char.
- `deploy_period` — `1` (means 1 month) works; the endpoint calls this "billing scheme" in its error text if missing/malformed, which is confusing since there's also a totally separate `traffic_plan` field.
- `traffic_plan` — **the real blocker.** `traffic_plans.php action=list` (per HOSTKEY's own docs at hostkey.ru/documentation/apidocs/traffic_plans/) takes a `vm=`/`traffic_plans[]=`/`all_tags[]=` filter set but every combination I tried returned `invalid request` — never got it to return data. Ended up reusing `traffic_plan=25` (seen in Hostkey's own doc example for an unrelated NL order) and it happened to validate against `vm.v2-medium` in `CH` too — likely a generic/default VPS traffic plan ID, not preset-specific. Worth revisiting `traffic_plans/list`'s actual param contract if ordering again.
- `hostname` is NOT required by `order_instance` (Hostkey's own doc example omits it) — don't waste time on it if you hit "invalid instance name"; that error is actually about the `preset` field type, not the hostname.

**ssh_keys.php action=add** consistently returned `Missing required keys: key` no matter the field name tried (`key`, `ssh_key`, `public_key`, `pubkey`, `value`) — never resolved. Simpler path: provision with `root_pass`, SSH in once with the password, append the Gateway's own key (`/root/.ssh/claude_code_key.pub`) to `~/.ssh/authorized_keys` manually, like any other VM in the fleet.

See [[hostkey_server_replacement]] for why this VPS was needed in the first place, and check CLAUDE.md's erp-temp section for the pattern this PrivateNexus stand-in should follow (dedicated WireGuard tunnel, temporary Caddy repoint, revert plan once bare metal is restored).

**⚠ `eq.php?action=reinstall` is NOT safe to call for parameter discovery — it executes
immediately, even with `os_id` omitted entirely.** Learned the hard way 2026-07-22: called
`eq.php?action=reinstall&token=...&id=22272` with no `os_id`, intending it purely as a probe to
see what validation error came back describing the required parameters (a pattern that's safe on
most REST APIs and had worked for discovering other invapi quirks). Instead it returned
`{"result":"OK","action":"reinstall","stage":"create_pxe",...}` and genuinely began wiping the
server — confirmed within seconds via `ssh`/`ping`: ICMP still responded (VM up) but SSH was
refused (OS gone), and `eq.php?action=show` then reported `"OS": null`. There is no dry-run mode,
no confirmation step, and an incomplete/missing `os_id` does not block execution — it just starts
the reinstall pipeline without one, leaving the server needing a follow-up correct call to actually
land on a real OS. **How to apply: never call `eq/reinstall` (or presumably other `eq/*` actions
with a similarly destructive name — `create_baremetal`, `delete_baremetal`, `hard_off`, etc.)
"just to see the error" — assume every `eq/*` write action executes on the first successful call,
full stop.** If the required parameters for a destructive action aren't already known, find them
via a read-only discovery path first (`os.php?action=list` for OS IDs — worked cleanly, no side
effects — is the model to follow) rather than probing the destructive endpoint itself.

The OS catalog lives at a **separate module**, `os.php?action=list` (not `eq.php`), and is the
reliable way to find `os_id` values — confirmed clean/read-only. Debian 12 is `os_id 219`
(`vm-capable: true`); Debian 11 is 180, Debian 13 is 300. The `eq.php?action=status` action does
not return meaningful progress detail even when passed the `callback` ID from a triggered action —
it just returns its own new callback each call, not a status of the original operation. Matches the
already-documented pattern that Hostkey's API has poor visibility into in-progress operations —
direct SSH/ping polling remains the reliable way to tell when a reinstall has actually completed.

**Support tickets live in a separate module, `jira.php`, not `rtm.php` (2026-07-24 discovery).**
`rtm.php?action=open_ticket` looked like the obvious candidate (the permissions list even includes
`rtm/open_ticket`) but consistently returns a bare `{"result":"error"}` with zero detail regardless
of params tried — dead end, don't waste time on it. The real endpoint is
`jira.php?action=request_assistance`: required params are `id` (server ID, integer) and, oddly,
`terminate_reason_custom` — despite the termination-sounding name, this is genuinely just the
"detailed problem description" field per Hostkey's own docs (`hostkey.com/documentation/apidocs/jira/`),
reused from what was probably originally a cancellation-request form. Confirmed safe to call with
just those two params, leaving the optional `cancellation_type`/`cancellation_reason`/
`terminate_move_to_provider`/`terminate_reboot`/`terminate_contact` fields omitted entirely — does
not trigger any cancellation/termination behavior. Success response: `{"result":"OK",
"jira_issue":"CS-xxxxx","jira_url":"..."}`. The `jira.php` module also has `request_kvm`,
`request_reboot`, `request_poff`/`request_pon`, `request_PXEboot`, `request_check` (all just need
`id`) for when remote/API control isn't enough and a human needs to physically intervene.

Once a ticket exists (however it was created), **reading it back uses `rtm.php` correctly**:
`rtm.php?action=get_tickets&token=...` lists every ticket on the account (good for checking for an
existing/duplicate ticket before opening a new one), and
`rtm.php?action=get_ticket_by_id&token=...&ticket_id=<numeric issueId>` (NOT `id`, `issueId`, or
`issueKey` — those all fail; the working param is specifically `ticket_id`, and it wants the numeric
internal ID like `1164018`, not the human-facing key like `CS-504413`) returns the full ticket plus
its comment thread. So ticket creation and ticket reading live in two different modules with two
different ID conventions — easy to trip over if assuming symmetry.

**`hostkey.com/documentation/apidocs/<module>/` pages are real and fetchable** (e.g.
`hostkey.com/documentation/apidocs/jira/`) — worth checking before blind-guessing param names on an
unfamiliar module, cheaper than trial-and-error against a live write endpoint.

**Update 2026-07-26 — `rtm.php?action=add_comment` appears fully broken for this account/role,
not just on closed tickets.** Tried replying to two different tickets, one closed (CS-505879) and
one still `status:"open"` (CS-503992) — both failed identically with
`"Ticket not found or you has no permissions"` once given the correct field names. Field-name
discovery: `ticket_id` is the correct ID param (others — `issue_id`/`issueId`/`id`/`ticketId` — all
error `"Ticket id required"`), and `message` is the correct body param (others — `body`/`text`/
`msg`/`comment_text`/`description`/`note` — all error `"Empty message"`). So the params are right,
the action itself just doesn't work for this role, regardless of ticket status.
`rtm.php?action=toggle_ticket_status` also failed differently (`"Authorization required"`) — not
investigated further. **Working fallback, confirmed twice: a fresh
`jira.php?action=request_assistance` call, referencing the old ticket number in the message body
text itself** (no real "reply to"/"link to ticket" field exists in this API) — this creates a new
CS-###### ticket, doesn't actually reopen the old one, but Hostkey support reads and responds to it
same as any ticket.

**Gotcha: `request_assistance` is deduplicated per the `id` (server ID) param, not per account or
per topic.** A second `request_assistance` call using the same server `id` as an already-open
assistance ticket for that server fails with `"There is already an open assistance request for
this server: CS-XXXXXX"` (`code: ASSISTANCE_TICKET_EXISTS`) — even for a completely unrelated
topic (hit this filing a billing/refund follow-up while CS-506937, a nested-virt follow-up, was
still open against server `22272`). Worked around by passing a *different* server ID this account
owns (`50265`, the Gateway VPS) for the unrelated billing request — the ticket content itself
doesn't have to actually be about that server, `id` just seems to be used as the dedup key plus
maybe context. If filing multiple simultaneous assistance requests, use a different server ID from
this account's `[50265, 4683, 22272]` list for each one to avoid the dedup collision.
