## Keycloak SSO

URL: https://auth.house-of-trae.com
Backend: Gateway VPS — PostgreSQL backend

| Realm           | Used By                                                      |
|-----------------|--------------------------------------------------------------|
| securenexus     | Grafana, Forgejo, PowerDNS-Admin, HoT staff                  |
| personal        | Vaultwarden, Nextcloud, Immich, Notesnook (tresemme.space)   |
| byrne-accounts  | Byrne Accounts staff                                         |
| stratus-digital | Stratus Digital staff                                        |
| discreet-elite  | Discreet Elite users                                         |
| emerald-markets | Emerald Markets users                                        |
| clients         | Client portal users                                          |
| house-of-trae   | House of Trae parent — master identity-provider-redirector broker |
| master          | Keycloak's own built-in admin realm (not app-facing)         |
| privatenexus    | PrivateNexus app users (prod/dev/test, all on hot-pn)        |

10 realms total. All realms: MFA enforced, brute force detection, strong password policy.
Keycloak OIDC API URL must point to realm root: `.../realms/<realm-name>` (NOT the protocol endpoint — causes 500 errors).

**WebAuthn/passkey policy (rolled out 2026-07-02, verified 2026-07-04 via admin API against all 10 realms):**
- 2FA WebAuthn policy: `rpId=house-of-trae.com`, signature algorithm `ES256`, `userVerification=preferred`
- Passwordless policy: same `rpId`/`ES256`, `userVerification=required`, `requireResidentKey=required`, `authenticatorAttachment=platform` (passkey-grade — platform authenticator + resident key forces a real synced/hardware passkey, not just any FIDO2 token)
- Required actions `webauthn-register` and `webauthn-register-passwordless` enabled (not default) on every realm — so users can register a passkey from their account console, but aren't force-enrolled
- Config is identical across all 10 realms including `master` — confirmed via `admin/realms/<realm>` and `admin/realms/<realm>/authentication/required-actions` REST calls, not just inferred from the commit message

**`privatenexus` realm — MFA actually enforced for privileged roles (2026-07-23):** the `webauthn-register` required action above is *optional* realm-wide (users can enroll, aren't forced to) — this was flagged as PRD gap AUTH-07 since it meant `admin`/`superadmin`/`breakglass` could log into PrivateNexus with password only. **Two separate flows had to be fixed, not one** — this realm's `house-of-trae` identity provider link (federated broker login) is a completely different code path from local username/password, and most real users (including tristian, whose `privatenexus` account is broker-linked to `house-of-trae`) never touch the local form at all. Fixing only the local flow (first attempt) left the actual login path most people use completely unenforced.
- **Local path:** duplicated `browser` → `browser - privileged MFA` (bound as this realm's `browserFlow`), added 3 role-gated conditional sub-flows under `forms` (password → `Force MFA - superadmin`/`-breakglass`/`-admin`, each `Condition - user role` + `OTP Form` REQUIRED), excluded those roles from the pre-existing optional-2FA fallback via negated role conditions to avoid a double OTP prompt.
- **Broker path:** built `privatenexus post-broker MFA` (same 3 role-gated sub-flows) and bound it as the `house-of-trae` IdP's `postBrokerLoginFlowAlias` (**not** `firstBrokerLoginFlowAlias` — that one only fires once, at initial account linking, never again). **Gotcha hit here:** a post-broker flow made only of conditional sub-flows throws `AuthenticationFlowException` ("Invalid username or password") when none match, since literally nothing in the flow executes — fixed by adding a REQUIRED `allow-access-authenticator` ("Allow access") as an explicit unconditional pass-through.

Verified end-to-end on both paths with disposable test accounts, including a real linked house-of-trae+privatenexus federated pair driven through the actual multi-hop broker redirect chain via curl (not just the local form): role assigned → `CONFIGURE_TOTP`; role removed → normal flow. All test accounts deleted after. Full detail: PRD `AUTH-07`. **If replicating this pattern on another realm: (1) built-in `browser`/`forms` flows can't be edited in place ("illegal to add sub-flow to a built in flow") — copy first, edit the copy, then rebind; (2) check whether users of that realm log in locally or via a broker link — a conditional-role MFA flow bound only to `browserFlow` silently does nothing for brokered users; (3) any post-broker (or similarly freestanding) flow built entirely from conditional sub-flows needs an unconditional `allow-access-authenticator` fallback or it fails outright for anyone matching none of the conditions.**

---

## PowerDNS

API port: 8081 (NOT 8053)
API key: pdnsKj7xM9pL2vR5n
Bound on: 10.10.0.1:8081 (WireGuard interface — reachable from bare metal)
Authoritative nameservers: ns1.house-of-trae.com / ns2.house-of-trae.com

Zones managed (confirmed live):
  house-of-trae.com, securenexus.net, byrne-accounts.org, stratus-digital.com,
  discreet-elite.uk, emerald-markets.net, privatenexus.net, tresemme.space,
  namevault.co.uk, dickson-supplies.com, evilrabbitart.com, rubyosiris.com,
  cloud-architects.online (legacy)

tresemme.space records — all → 151.241.217.91:
  apex (placeholder). This was pn-test's domain for personal services (Cosmos-era Nextcloud/
  Vaultwarden/Immich/etc., removed Jun 2026) — pn-test and sn-personal are now both retired outright
  (2026-08-03 and 2026-08-09 respectively), so no further subdomains are planned here unless a
  future personal-services plan (e.g. Phase 4 "HoT Sync", now needing an unrelated landing spot)
  explicitly picks this domain back up.
  `pn`/`notes` subdomains are still live — plain Caddy redirects to real external services
  (privatenexus.net, app.notesnook.com respectively), never actually depended on pn-test, kept as-is.
  Removed from Caddy 2026-08-03 (DNS records not touched, harmless if still present): `sync`,
  `identity`, `sse`, `s3`, `monograph` — a leftover self-hosted Notesnook-stack cluster that had been
  reverse_proxy'ing to the dead pn-test VM (10.10.60.105) since it was decommissioned; found while
  auditing an unrelated CrowdSec scenario bug (real scan traffic against `monograph.tresemme.space`
  was being miscounted as Forgejo brute-force activity — see crowdsec_custom_scenarios_audit memory).
  Older "Removed" list below predates this session and was never reconciled against the live
  Caddyfile — it lists `notes`/`pn` as removed, but both are confirmed live today (verified via real
  redirect checks), so that list is stale for at least those two; left as-is rather than guess at
  the actual history.
  Previously noted as removed: nextcloud, vaultwarden, photos, notes, firefly, firefly-iii, actual, pn

privatenexus.net — same class of Cosmos-era leftover found+removed 2026-08-10, this time on
`privatenexus.net` itself rather than `tresemme.space`: real `A` records for `cloud`, `nextcloud`,
`vault`, `photos`, `notes`, `notes-auth`, `notes-sse`, `notes-sync`, `notes-pub`, `notes-s3` — all →
151.241.217.91, zero matching Caddy site blocks for any of them (only bare `privatenexus.net`/
`www.privatenexus.net` exist). Found because Mr. Byrne hit a real `ERR_SSL_PROTOCOL_ERROR` trying
`cloud.privatenexus.net` (an understandable guess while testing the new PN Catalogue deploy flow's
Nextcloud instance — unrelated to it in fact, since that instance is deliberately `127.0.0.1`-only
per the Phase 1 scope, not publicly wired at all). **Also found and removed the actual root cause,
a `*.privatenexus.net` wildcard `A` record** — deleting the 10 specific dead names alone didn't fix
the symptom, since the wildcard immediately backfilled `cloud.privatenexus.net` again; removing the
wildcard was the real fix, confirmed via public `dig` (correctly returns nothing now, instead of a
confusing SSL error). `privatenexus.net`'s own apex record untouched throughout, confirmed still
resolving correctly.

house-of-trae.com — `_tailscale-challenge` TXT record added 2026-07-16 (Tailscale domain
verification, admin console "Add + verify domain" flow): `_tailscale-challenge.house-of-trae.com`
TXT `"v2=XK2oDuhegVHtA3SRM7bFE9CcKHsNBZxyB8GMKKf6Nwk3"`, TTL 3600. Added via the PowerDNS API
(PATCH .../zones/house-of-trae.com.), confirmed resolving publicly. Purely a proof-of-ownership
record for Tailscale's background verification — no service routing implication; safe to remove
once Tailscale confirms verification if it doesn't clean itself up.

---

## Email Infrastructure

Host: mail.house-of-trae.com | Webmail: webmail.house-of-trae.com
Stack: Docker Mailserver + Roundcube
Universal SMTP: notifications@house-of-trae.com | port 587 | STARTTLS

Email domains: @house-of-trae.com, @securenexus.net, @byrne-accounts.org,
               @stratus-digital.com, @discreet-elite.uk, @emerald-markets.net, @privatenexus.net

---

