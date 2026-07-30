---
name: clamav-stale-signatures
description: "Docker Mailserver's bundled ClamAV is stuck on stale signatures (Aug 2025) because upstream hasn't cut a new stable release in ~11 months — accepted gap, not fixed by pulling"
metadata: 
  node_type: memory
  type: project
  originSessionId: 662a2e2b-edf7-4613-857f-27ff2bf97ace
---

Docker Mailserver's bundled ClamAV engine (1.0.7) and virus database (main.cvd/daily.cvd, dated Aug 11 2025) are stuck because `ghcr.io/docker-mailserver/docker-mailserver:latest` (currently resolving to release 15.1.0) genuinely hasn't been rebuilt by upstream since 2025-08-12 — confirmed by comparing the GHCR registry digest directly, not a local caching issue. `docker compose pull` on 2026-07-05 was a no-op for this reason. freshclam is stuck in a permanent CDN cool-down loop ("Forbidden; Blocked by CDN") because ClamAV's CDN rate-limits/blocks outdated client versions — this can't be fixed by re-running freshclam or waiting, only by upgrading the engine itself.

The `edge` tag (nightly/unstable branch) does have a current ClamAV (1.4.3, signatures as of 2026-06-30) — checked 2026-07-05 by pulling and inspecting it directly. Confirmed available but deliberately NOT adopted.

**Why:** Mr. Byrne explicitly chose to stay on the pinned stable release rather than run production mail (SMTP/IMAP for every HoT domain, including notifications@house-of-trae.com alerting) on an unreleased nightly branch just to fix a secondary AV signature gap. rspamd remains the primary spam/phishing filter and is unaffected — ClamAV here is a secondary attachment-scanning layer, so the risk of stale signatures was judged lower than the risk of destabilizing live mail delivery on an untested branch. This mirrors the existing Watchtower v1.5.3 pin (documented in CLAUDE.md) — this operator consistently prioritizes pinned/stable versions over bleeding-edge for infra that's actually load-bearing.

**How to apply:** Don't suggest switching docker-mailserver to `:edge` as a routine fix. If this comes up again, check whether upstream has shipped a new stable release (`ghcr.io/docker-mailserver/docker-mailserver` tags via GHCR API) before re-raising it — the fix is either a genuine upstream release, or the sidecar option below. The real long-term fix, if ever prioritized, is decoupling ClamAV into its own sidecar using the actively-maintained `clamav/clamav` image, with docker-mailserver's milter pointed at that external clamd socket instead of the bundled one — this was proposed 2026-07-05 as a "real project, not a quick pull," scoped but not started. No urgency assigned; revisit only if AV coverage becomes a real concern beyond rspamd's spam/phishing filtering.
