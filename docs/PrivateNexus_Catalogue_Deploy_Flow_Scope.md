# PrivateNexus — Catalogue-Driven Deploy Flow

Scoping doc. Written 2026-08-10 after Mr. Byrne dogfooded the current Discovery approve flow
(deploying a personal Nextcloud instance on hot-pn) and found it opaque — no guidance on what's
about to happen, no preview, no sense of what "approve" actually does. He described Cosmos's old
flow as the bar: Catalogue → pick app → customize (name/env/ports) → review generated
`docker-compose.yml` → confirm → system deploys and wires up the rest (URL, etc.) automatically.
Asked to scope a real version of that for PN, framed explicitly against the future "JARVIS brain"
direction (item 27) — a templated, parameterized flow is something an automated agent can actually
drive; a reactive discovery scan of what already exists is not.

Not a commitment to build — a scope to react to and prioritize against, per Mr. Byrne's direction.

---

## 1. What exists today (verified against the real code, not assumed)

| Piece | State |
|---|---|
| **Catalogue board** (`routes/catalogue.js`, `catalogue/default-repo.json`) | Real, but **read-only**. 52 apps, each with `id/name/category/description/image/site/access_mode/backup/tags`. No compose file, no port/env schema, zero `POST`/deploy route in the file. Supports a tenant-configurable custom repo URL with fallback to the bundled default. |
| **Discovery flow** (`routes/discovery.js`) | Reactive only. `PATCH /candidates/:id {action: approve}` does exactly one thing: inserts a row into `services` with metadata copied from the candidate (name/slug/category/access_mode/health_endpoint/container_name). **No Docker action, no DNS, no Caddy, no compose preview** — this is why the flow felt like nothing happened. It's inventory bookkeeping for something that's already running, not a provisioning action. |
| **Governance rails** (`action_requests` / `action_policies`) | Real, general-purpose, and directly reusable. `action_requests.params` is `jsonb` — exactly the right shape to hold a generated compose spec pending review. Dual-control built in (`proposed_by !== approver`, admin-only approve). `service.deploy` already exists as an action_type, but it's narrow: redeploys an *existing* named container to a new image tag, with rollback tracking (`deploy_rollback_points`). Different job — reusable pattern, not reusable logic. |
| **Secrets** (`agent_tokens`) | PN already has a pattern for provisioning scoped tokens (used by the discovery agent). Worth reusing the same shape for per-deployed-service secrets rather than inventing a new one. |
| **DNS/Caddy write access** | **Does not exist from PN today.** Backend has `CADDY_ADMIN_URL` set, but Caddy's admin API is deliberately `admin off` in the real Caddyfile (security choice — that API is unauthenticated by default and fronts the entire public HoT presence). No `PDNS_API_KEY` configured on PN's backend at all. This is the one part of the Cosmos-style flow that can't just be "flipped on" without a real access-model decision — see §5. |

**Bottom line**: the gap Mr. Byrne felt is real, not a misunderstanding of an existing feature. The
UI for Catalogue exists; the entire "turn a catalogue entry into a running, reviewed, wired-up
service" pipeline does not.

---

## 2. What "done" looks like

From the Catalogue board: pick an app → a form shows the app's customizable fields (name, URL/
subdomain, key env vars, port if relevant) → submitting generates a real `docker-compose.yml` from
a template + your inputs → that goes into the existing `action_requests` queue as a new pending
request, **rendering the actual compose YAML in the review UI** (this is the missing piece Mr.
Byrne specifically called out — Cosmos showed you the file before it ran) → an admin approves →
the container(s) deploy for real on the target host → the resulting service is auto-registered in
`services` (skipping the manual Discovery round-trip entirely, since PN itself did the deploying and
already knows every detail) → the "wiring" step (DNS + Caddy, see §5) either applies automatically
or hands you a ready-to-apply snippet, depending on which access-model option gets picked.

---

## 3. Data model additions

**Catalogue app entries need a real deploy schema**, not just descriptive metadata. Extend
`default-repo.json`'s app shape:

```jsonc
{
  "id": "nextcloud",
  "name": "Nextcloud",
  // ...existing fields unchanged...
  "deploy": {
    "compose_template": "nextcloud/docker-compose.yml.tmpl",   // new: template dir per app
    "fields": [
      { "key": "instance_name", "label": "Instance name", "type": "text", "required": true },
      { "key": "subdomain",     "label": "Subdomain",      "type": "text", "required": true,
        "hint": "e.g. 'cloud' → cloud.house-of-trae.com" },
      { "key": "admin_user",    "label": "Admin username", "type": "text", "default": "tristian" }
    ],
    "generates_secrets": ["db_password", "admin_password"],   // random-generated, never user-entered
    "requires_db": "postgres",                                 // template hint, not enforced here
    "target_host": "hot-pn"                                    // v1: fixed, not user-selectable — see §6
  }
}
```

Not every catalogue app needs a `deploy` block on day one — apps without one just stay
browse-only, same as today. This is additive, not a rewrite of the existing 52-app repo.

**New `action_type`**: `service.provision_from_catalogue`. Add to the `ALLOWED_REQUEST_TYPES` set
in `routes/actions.js` alongside the existing three. `params` holds `{ catalogue_app_id,
field_values, generated_compose, generated_secrets_meta }` — the *generated compose text* is what
the review UI renders verbatim, matching the Cosmos precedent of showing the real file, not a
paraphrase of it.

---

## 4. Backend flow

1. `GET /api/catalogue/:id/deploy-form` — returns the app's `fields` schema for the frontend to
   render (new route; thin, no compose generation yet).
2. `POST /api/catalogue/:id/preview` — takes `field_values`, renders the compose template
   (simple placeholder substitution is enough for v1 — no need for a templating engine), generates
   random values for anything in `generates_secrets`, returns the rendered YAML **without deploying
   anything**. This is the "show me the file" step.
3. `POST /api/actions/requests` with `action_type: "service.provision_from_catalogue"` and the
   previewed compose + field values as `params` — reuses the *existing* propose endpoint unchanged
   except for the new allowed type. Blast-radius check already runs generically; for a brand-new
   service it'll correctly report `count: 0` (nothing depends on something that doesn't exist yet).
4. Existing pending-request review UI renders `params.generated_compose` as a syntax-highlighted
   block — this is almost entirely a frontend change, the storage/approval mechanics are already
   there.
5. `POST /api/actions/requests/:id/approve` — new `else if` branch in the existing executor switch:
   write the compose file to `/opt/stacks/<slug>/` on the target host (needs the same
   `docker-socket-proxy` pattern PN already uses locally — see §6 for the multi-host question),
   `docker compose up -d`, write the generated secrets to Docker secrets files (matching this
   fleet's `chmod 644` convention for non-root container users), then `INSERT INTO services`
   directly (no separate Discovery round-trip needed — PN already knows the slug, name, category,
   container name, and can set a real `health_endpoint` immediately instead of waiting for a
   human to fill it in later).
6. Discovery keeps running as-is, unchanged — it's the correct fallback for anything deployed
   outside this flow (manually, by someone else, or found mid-migration), which is exactly the
   role it's already playing well.

---

## 5. DNS + Caddy wiring — needs a real decision, not just code

This is the one part of "the system takes care of the rest" that can't be scoped as a pure
engineering task, because it's a security-model decision about how much live write access PN's
backend gets to shared, public-facing infrastructure. Three real options:

**Option A — Generate, don't apply.** PN generates the exact PowerDNS API call and Caddy site
block as text in the approved request's result, but doesn't execute either. A human (you or me)
applies them, same as every DNS/Caddy change made this whole session. Zero new credentials on PN's
backend. Slowest, safest, matches how every Caddy change this session was actually done (validate,
backup, reload, verify — never blind-automated).

**Option B — PN gets scoped write access to PowerDNS only.** A `PDNS_API_KEY` (ideally a
narrower-scoped one than the fleet-wide key, if PowerDNS's API supports per-zone tokens — worth
checking) added to PN's backend, so DNS record creation is real automation. Caddy stays
generate-only (Option A) since that's the higher-blast-radius one (a bad Caddy write can take down
every public HoT domain at once; a bad DNS write is scoped to one record and easy to revert).

**Option C — Full automation.** Caddy's admin API gets turned on (bound narrowly, e.g. only
reachable from hot-pn's tunnel IP, `10.10.2.2`, via UFW — never publicly) and PN gets write access
to both. Fastest end-to-end flow, matches Cosmos most closely, but is a real, deliberate expansion
of what a web app's backend can do to shared public infrastructure — the kind of change this
project has consistently treated as needing explicit sign-off (see: every `wg3`/UFW widening this
session was scoped and asked about first, never assumed).

**Recommendation: start with Option A.** Prove the compose-generation/review/deploy part of the
flow first (the part Mr. Byrne actually asked for — visibility and control before something runs),
then revisit B/C once that's trusted and it's clear DNS/Caddy automation is worth the access
expansion. This also sidesteps a real open question — whether Caddy's admin API even *should* ever
be reachable from a public VPS that itself sits behind that same Caddy instance.

---

## 6. Decisions — Mr. Byrne, 2026-08-10

1. **Target host: hot-pn only.** No multi-host executor needed for v1 — confirmed, not just
   assumed.
2. **Which apps get a `deploy` block first: the 2 already in flight.** Nextcloud (template written
   retroactively against the already-running instance) and Notesnook (the 5-service stack, once
   Nextcloud proves the flow) — not a push to template all 52 catalogue apps up front.
3. **Secrets exposure in the review UI: show them before deployment.** No masking — nothing's live
   yet at review time, so the generated passwords are shown in plain text in the compose preview.
4. **Discovery stays permanently, as the fallback.** Not replaced by this flow — confirmed as the
   intended end state, not just a v1 shortcut. Catalogue deploy becomes the front door for new
   services; Discovery keeps catching anything deployed outside it.

---

## 7. Phasing

- **Phase 1**: Catalogue deploy-form + preview + compose-review-in-the-existing-approval-UI +
  container deploy on hot-pn only + DNS/Caddy as Option A (generate, don't apply). Nextcloud as the
  first real templated app, using the instance already running as the reference implementation.
- **Phase 2**: Notesnook's 5-service stack as the complexity stress test for the template schema.
- **Phase 3** (only after Phase 1 is trusted in real use): revisit DNS auto-apply (Option B), and
  separately, whether Caddy automation (Option C) is ever wanted at all.
