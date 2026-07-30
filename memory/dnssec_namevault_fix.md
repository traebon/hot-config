---
name: dnssec-namevault-fix
description: namevault.co.uk was SERVFAILing on validating resolvers due to a registrar-side DS algorithm mismatch (14 vs actual 13) — fixed 2026-07-27, all other zones checked clean
metadata:
  node_type: memory
  type: project
---

**2026-07-27 — `namevault.co.uk` didn't resolve on public DNS (8.8.8.8) despite correct NS
delegation and a correctly-configured PowerDNS zone.** Root cause found by comparing the actual DS
record published at the registry (queried live: `2006 14 4 0CD31B77...`) against PowerDNS's
current signing key (`2006 13 4 0cd31b77...` — same digest bytes, different algorithm field).
Registry said algorithm 14 (ECDSAP384SHA384), PowerDNS's real key is algorithm 13
(ECDSAP256SHA256) — matches `/root/hot/docs/dnssec-ds-records.md`'s documented value exactly, so
the docs and PowerDNS agree; only the registrar's published DS was stale. `dig ... @8.8.8.8` showed
`SERVFAIL` with EDE 9 "DNSKEY Missing" — the diagnostic tell for this specific class of bug
(delegation/NS is fine, only the DS-pinned key is wrong). Non-validating resolvers (our own
internal Unbound) never caught this since they don't check DS/DNSKEY consistency at all.

Mr. Byrne updated the DS record at the registrar directly (algorithm 14→13, same keytag/digest
type/digest). Confirmed live: `namevault.co.uk` now returns `NOERROR` with a real answer via
8.8.8.8.

**Checked all other managed zones for the same pattern — isolated to namevault.co.uk only.**
Queried `A @8.8.8.8` for all 12 zones in `dnssec-ds-records.md`
(house-of-trae.com/securenexus.net/byrne-accounts.org/stratus-digital.com/discreet-elite.uk/
emerald-markets.net/privatenexus.net/tresemme.space/dickson-supplies.com/evilrabbitart.com/
rubyosiris.com/cloud-architects.online) — all return clean `NOERROR`. Also found
`cloud-architects.online`'s docs entry was stale (flagged "⏳ DS submitted, awaiting TLD
propagation" from 2026-06-01) — it resolves fine now, propagation completed at some point since
then and nobody updated the doc. Fixed the doc comment to reflect that.

**How to apply:** if any other zone ever shows unexplained public-resolution failure with
delegation/NS looking correct, check `dig <zone> A @8.8.8.8 +noall +comments` for `SERVFAIL` first
— that's the fast triage signal for a DNSSEC DS/DNSKEY mismatch specifically (vs NXDOMAIN, which
would mean a real delegation problem). Compare the registry's live DS (`dig <zone> DS @8.8.8.8`)
against PowerDNS's actual current key (`GET /zones/<zone>./cryptokeys` on the API) rather than
trusting `dnssec-ds-records.md` alone — the docs can drift from reality if a key is ever rotated
without resubmitting the DS to the registrar, exactly like this case.
