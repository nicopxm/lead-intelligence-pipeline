# Runbook — Lead Intelligence Pipeline

Operational reference: infra provisioning, restore-from-scratch, and day-2 procedures. Update this file whenever infra changes (server setup, Docker, env vars, restore steps).

## Infra
- **VPS**: Hetzner (provisioned in #2)
- **Orchestration**: n8n, self-hosted via Docker Compose (`n8n/`)
- **Database**: Supabase (Postgres) — source of truth
- **CRM**: HubSpot (Free tier, write-only downstream)
- **App**: Next.js on Vercel
- **Email**: Resend

## Sections (fill in as each lands)
- [x] Hetzner provisioning steps (#2)
- [x] Docker + n8n setup and restart/reboot recovery (#2)
- [x] Supabase project setup + migration workflow (#3)
- [x] HubSpot Service Key setup + contact verification (#4)
- [x] Universal webhook intake workflow (#7)
- [x] Vercel CI/CD connection (#5)
- [ ] Restore-from-scratch procedure (full stack)

## Hetzner provisioning (#2)

**Server**: Hetzner Cloud CX23 (2 vCPU / 4GB RAM / 40GB disk), Falkenstein (fsn1), Ubuntu 26.04. ~€6.49/mo.

1. Create a Hetzner Cloud project, add a server: choose region, cheapest suitable shared-vCPU type, Ubuntu image.
2. Add an SSH public key at creation time (dedicated keypair per project, not a personal one). Password login is disabled — SSH key is the only way in.
3. Note the server's public IPv4 — needed for the DNS A record and all SSH access below.

### DNS (Porkbun)
Create an `A` record on the domain: host = subdomain (e.g. `n8n`), answer = server's public IPv4, TTL default. Propagation is typically fast (minutes) but can take longer.

### Hardening (done once, as root, then root login is disabled)
- Non-root sudo user (`deploy`) created; root's `authorized_keys` copied to `deploy`'s `~/.ssh/authorized_keys`.
- `ufw`: default deny incoming, allow only 22/tcp, 80/tcp, 443/tcp. `ufw enable`.
- `fail2ban`: `sshd` jail enabled, `banaction = ufw`, maxretry 5 / findtime 10m / bantime 1h. Config at `/etc/fail2ban/jail.local`.
- `/etc/ssh/sshd_config.d/99-hardening.conf`: `PasswordAuthentication no`, `PermitRootLogin no`. Verify the non-root user can still connect and `sudo` works *before* reloading sshd.

### Docker
Installed via the official convenience script (`curl -fsSL https://get.docker.com | sh`), which installs `docker-ce`, `docker-ce-cli`, `containerd.io`, and the `docker-compose-plugin` (i.e. `docker compose`, no separate `docker-compose` binary). The deploy user is added to the `docker` group; Docker daemon is enabled at boot (`systemctl enable docker`).

### n8n + Caddy (docker compose)
Compose file and Caddyfile live in `n8n/` in this repo (`n8n/docker-compose.yml`, `n8n/Caddyfile`). Two services:
- `n8n` (n8nio/n8n:latest) — not exposed to the host directly; only reachable via the `internal` Docker network. Data persists in the named volume `n8n_data` mounted at `/home/node/.n8n` (contains `database.sqlite`, the encryption key, workflows).
- `caddy` (caddy:2-alpine) — publishes 80/443, terminates TLS via Let's Encrypt (automatic HTTPS, no config needed beyond the domain in the Caddyfile), reverse-proxies to `n8n:5678`, and enforces HTTP Basic Auth in front of the editor/API (`basicauth` directive inside a `route {}` block). As of issue #7, `/webhook/*` and `/webhook-test/*` are explicitly excluded from basic auth — see "Universal webhook intake workflow (#7)" below — since external lead sources can't authenticate as the editor user. This basic-auth setup itself is flagged for replacement, see backlog issue #15 (repeated browser re-prompts, forward_auth vs. dropping it for n8n's own user accounts).

**Secrets**: an `.env` file lives in `~/n8n/.env` on the VPS only (`chmod 600`, owned by `deploy`) — never committed. It sets `N8N_HOST`, `GENERIC_TIMEZONE`, `BASIC_AUTH_USER`, `BASIC_AUTH_HASH`. See `.env.example` in the repo root for the documented variable names. **Gotcha found in #7**: `N8N_HOST` had at some point only been passed inline at container start (`N8N_HOST=... docker compose up -d`) rather than actually saved in this file — meaning any future plain `docker compose up -d` would silently recreate the `n8n` container with an empty `N8N_HOST`, breaking `WEBHOOK_URL`. Confirm `N8N_HOST` is genuinely present in `~/n8n/.env` (`grep -o '^[A-Za-z_]*=' ~/n8n/.env`, name only, don't `cat` a secrets file) before any `docker compose up -d` on this box.

**Single-file bind-mount gotcha**: `./Caddyfile:/etc/caddy/Caddyfile:ro` bind-mounts one file, which Docker pins to that file's *inode*. Overwriting it with `mv newfile Caddyfile` swaps the inode, so the already-running container keeps serving the old content — `caddy reload`/`caddy validate` inside the container will look correct but silently operate on stale config. After any Caddyfile change, redeploy with `docker compose up -d --force-recreate caddy` (not just `mv` + `reload`), and verify with `docker compose exec caddy cat /etc/caddy/Caddyfile` that the container actually sees the new content.

To generate the bcrypt hash for `BASIC_AUTH_HASH`:
```
docker run --rm caddy:2-alpine caddy hash-password --plaintext 'your-password-here'
```
The `$` characters in the resulting hash must be escaped as `$$` when placed in the `.env` file (Docker Compose's own `.env` parser treats a single `$` as the start of a variable reference).

Deploy / redeploy:
```
cd ~/n8n
docker compose up -d
```

## Supabase project setup + migration workflow (#3)

**Project**: Supabase free tier. Postgres is the pipeline's source of truth (see docs/ARCHITECTURE.md #1); HubSpot is write-only downstream.

1. Create the project at supabase.com (free tier, nearest region to the VPS/users).
2. From Project Settings → API, note the Project URL and the service-side key that bypasses RLS. Supabase now ships two key systems: legacy JWT-based `anon`/`service_role` keys, and newer **publishable**/**secret** keys (`sb_secret_...` prefix). Prefer disabling legacy API keys and using the new **secret key** — it's the equivalent of the old `service_role` key (bypasses RLS, server-side only) but rotates via a standby-key-then-rotate flow instead of a single irreversible JWT-secret reset. Put the Project URL and secret key in `.env` per `.env.example` (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`) — never in the browser, never committed.
3. Apply migrations from `supabase/migrations/` in order. Without the Supabase CLI installed locally, paste each migration's SQL into the Supabase dashboard's SQL Editor and run it; if the CLI is available (`supabase link` + `supabase db push`), that's the preferred path going forward since it keeps `supabase/migrations/` as the single source of truth and avoids drift from ad hoc dashboard edits.
4. Schema: `leads` table — see `supabase/migrations/20260703163152_create_leads.sql` for the authoritative definition. Columns: `id` (uuid pk), intake fields (`name`, `email`, `company`, `domain`, `source`, `message`, `submitted_at`), `status` (enum: raw/enriched/scored/delivered/error), `enrichment` and `intelligence` (jsonb, reserved for later sprints), `created_at`/`updated_at`.
5. Dedupe lookup: `leads_email_domain_idx` on `(email, domain)` supports the "same email+domain within 30 days = update, not insert" rule (docs/ARCHITECTURE.md #6). The upsert logic itself is enforced by the intake workflow, landing in Sprint 2 — the migration only documents the strategy and indexes the lookup.
6. RLS is enabled on `leads` with no policies, so `anon`/`authenticated` roles get zero access via PostgREST by default. All pipeline reads/writes use the service-role key server-side, which bypasses RLS entirely.

### Restart / reboot recovery — verified
- `docker compose restart` (inside `~/n8n`): both containers restart, `n8n_data` volume is untouched (verified via checksum of `/home/node/.n8n/config`, which contains the persistent encryption key), HTTPS + basic auth continue to work immediately.
- **Full VPS reboot** (`sudo reboot`): Docker daemon is enabled at boot, and both services use `restart: unless-stopped`, so `docker compose up -d` is not needed manually — containers come back on their own. Verified: same config checksum after reboot (data intact), `ufw` and `fail2ban` both `active` on boot, HTTPS cert still valid, basic auth still enforced (401 without/with wrong creds, 200 with correct creds).

## HubSpot Service Key setup + contact verification (#4)

**Auth**: HubSpot's private-app creation flow now flags UI-created private apps as legacy (no new scopes/features going forward) and steers new integrations to **Service Keys** — the modern credential for account-level, system-to-system API access. We use a Service Key, not a legacy private app (see docs/DECISIONS.md).

1. Create a free HubSpot account at hubspot.com (skip the AI-assisted/guided marketing setup — not needed).
2. Settings → Integrations → create a **Service Key** (not a legacy private app) named `lead-intelligence-pipeline`.
3. Scopes, least privilege:
   - `crm.objects.contacts.read` + `crm.objects.contacts.write` — read/write contact records.
   - `crm.schemas.contacts.write` — required separately to create/modify contact *property definitions* (schema operations are distinct from object read/write; creating `lead_source`/`icp_score` below fails with a `MISSING_SCOPES` 403 without it).
4. Copy the key value once shown (HubSpot only displays it once). Store as `HUBSPOT_TOKEN` in `.env` per `.env.example` — server-side only, never committed, never in n8n workflow JSON (use n8n credentials).
5. **n8n compatibility**: n8n's HubSpot node has three auth options — OAuth 2.0, App Token, API Key (legacy, deprecated by HubSpot). The "App Token" option accepts a Service Key directly (n8n renamed the label to "Service Key" to match HubSpot's terminology; the underlying credential type is unchanged) — no HTTP Request node workaround needed. Service Keys don't support webhooks, but our integration only pushes contacts out to HubSpot, so this doesn't apply.
6. Custom contact properties created via `POST https://api.hubapi.com/crm/v3/properties/contacts`: `lead_source` (string/text), `icp_score` (number) — the latter unused until Sprint 4 scoring lands.
7. Verified auth end-to-end: created a test contact via `POST /crm/v3/objects/contacts`, confirmed `lead_source` round-tripped correctly, then deleted it via `DELETE /crm/v3/objects/contacts/{id}` (204). Both properties and the Service Key confirmed working.

## n8n operational notes

Reusable gotchas hit while building the intake workflow (#7) — full debugging trail in that issue's closing comment, this is just the distilled checklist for next time:

- **Webhook body is nested.** The Webhook node's output is `{ headers, params, query, body }` — read `$json.body.fieldName`, not `$json.fieldName`.
- **Resource-locator fields don't survive a from-scratch JSON import.** Supabase's table/field/filter pickers and similar dropdown-driven params come back empty/invalid after Import from File, even when the exported JSON had values — reselect them in the editor after every fresh import.
- **Publish ≠ Active.** Newer n8n has a separate draft/published state per workflow. A workflow must be Published before it can be chosen as another workflow's Error Workflow, and edits to a published workflow don't take effect until you Publish again.
- **Single-file bind mounts pin to inode, not path.** Overwriting a bind-mounted file with `mv` leaves the running container serving the old content (even `caddy reload`/`validate` inside it looks correct against the stale copy). After replacing `n8n/Caddyfile` or similar, redeploy with `docker compose up -d --force-recreate <service>`, don't just `mv` + reload.

## Universal webhook intake workflow (#7)

**Workflows**: exported live from n8n after full setup + verification to `n8n/workflows/lead-intake.json` and `n8n/workflows/lead-intake-error-alert.json` (n8n "..." menu → Download). These reflect the actual working config, not the original hand-authored JSON — n8n's Supabase/HubSpot/Respond-to-Webhook node parameter shapes drifted from what was originally written, so re-importing from scratch will need the same manual node fixes below re-applied; always fix in the live editor then re-export, don't hand-edit the JSON.

1. In the n8n editor, import both files (Overflow menu → Import from File). Each import lands as a **separate** workflow — if you import the second file while the first workflow's canvas is still open/focused, n8n can add its nodes onto the same canvas instead of creating a new one. Create a blank workflow first (Workflows → Add workflow) before importing each file to avoid this.
2. `Lead Intake` needs credentials wired in, created directly in n8n (values are never pasted into chat/commits):
   - **Supabase Leads** (Supabase credential type): Host = `SUPABASE_URL`, Service Role Secret = `SUPABASE_SERVICE_ROLE_KEY`. Used by "Supabase - Insert Lead" and "Supabase - Mark Lead Error".
   - **HubSpot Service Key** (HubSpot node, App Token/Service Key auth): the Service Key from issue #4. Used by "HubSpot - Create Contact" and, via **Predefined Credential Type → HubSpot Service Key**, the "HubSpot - Set Lead Source" HTTP Request node (see step 6 on why that node exists).
3. `Lead Intake - Error Alert` needs one credential:
   - **Resend API Key** (Generic Header Auth credential): Name = `Authorization`, Value = `Bearer <RESEND_API_KEY>`. Sender is Resend's default `onboarding@resend.dev` (no domain verification needed; only sends to the account owner's own inbox, which is exactly Wop's alert use case).
4. Newer n8n has a **draft vs published** state per workflow (separate from Active). A workflow must be **Published** before it can be selected as another workflow's Error Workflow, and before its own webhook/trigger runs on anything other than manual test data. Publish both workflows.
5. In `Lead Intake`'s workflow Settings, set **Error Workflow** to `Lead Intake - Error Alert` (only shows up in the dropdown once that workflow is published).
6. **HubSpot's contact-properties picker in n8n only lists a curated common set — custom properties like `lead_source` don't show up even though they exist in HubSpot.** Workaround: an extra `HubSpot - Set Lead Source` HTTP Request node runs right after "HubSpot - Create Contact", calling `PATCH https://api.hubapi.com/crm/v3/objects/contacts/{{ $json.vid }}` directly (note: n8n's HubSpot "Create or Update" operation returns the contact's legacy-API shape, so the ID field is `vid`, not `id`) with JSON body `{{ { "properties": { "lead_source": $('Supabase - Insert Lead').item.json.source } } }}`, authenticated via **Predefined Credential Type → HubSpot Service Key**.
7. Webhook URL: `https://<N8N_HOST>/webhook/lead-intake` (POST). Payload schema: `{name, email, company, domain, source, message, timestamp}` — `name`/`email`/`source`/`timestamp` required, `company`/`domain`/`message` optional.
8. **Caddy must not basic-auth-gate the webhook path** — `/webhook/*` and `/webhook-test/*` are excluded from `basicauth` in `n8n/Caddyfile` (via a `route {}` block that runs a path-matched `reverse_proxy` before the `basicauth` directive) so any external lead source can POST without n8n editor credentials; only the editor/API stays behind basic auth. See "n8n + Caddy" above for the deploy gotcha (single-file bind mounts pin to an inode — always redeploy this file with `docker compose up -d --force-recreate caddy`, a bare `mv` + `caddy reload` will silently keep serving the old file).
9. Behavior:
   - Malformed payload → `Validate Payload` (Code node, reads `$json.body.*` — the Webhook node nests the POST body under `body`) flags it invalid → 400 JSON response with `details` (visible in n8n executions regardless of outcome, since the webhook always creates an execution).
   - Valid payload → insert into Supabase `leads` (`status=raw`) → create/upsert HubSpot contact → set `lead_source` (step 6) → 200 JSON response with the lead id.
   - Supabase insert failure → node throws, execution fails → `Lead Intake - Error Alert` fires automatically (n8n's Error Workflow mechanism) → Resend email to Wop.
   - HubSpot failure (after Supabase insert succeeded) → the lead row is updated to `status=error` (dead-letter, per docs/ARCHITECTURE.md #8, replayable after fix) before the execution is deliberately failed (Stop and Error node) → same alert path fires. Verified live end-to-end (2026-07-07): forced a HubSpot failure, confirmed the lead row flipped to `status=error`, the execution showed failed in n8n, and the Resend alert email arrived with the lead id/email/execution link.
10. Manual verification: `curl -X POST https://<N8N_HOST>/webhook/lead-intake -H 'Content-Type: application/json' -d '{"name":"Test Lead","email":"test@example.com","company":"Acme","domain":"acme.com","source":"curl-test","message":"hi","timestamp":"2026-07-07T12:00:00Z"}'` returns 200 + `{"status":"ok","id":...}`, creates a Supabase row and a HubSpot contact with `firstname`/`lastname`/`company`/`lead_source` populated. A payload missing `email` returns 400 and shows up in n8n's Executions list as a completed (not silently dropped) run.

## Vercel CI/CD connection (#5)

**App**: Next.js (TypeScript) app scaffolded in `web/` — a subdirectory, not repo root, since the repo also holds `n8n/`, `supabase/`, `docs/`, etc.

1. Connect the Vercel account to GitHub and import `nicopxm/lead-intelligence-pipeline`.
2. **Root Directory must be set to `web`** (Settings → General → Root Directory) — without it, Vercel tries to build from repo root and finds no Next.js app, producing a `NOT_FOUND` on every route despite a "successful"-looking deploy.
3. **Framework Preset must be explicitly `Next.js`**, not `Other`. Setting Root Directory after initial project creation can leave the preset on `Other` (looking for a static `public`/`.` output instead of running the Next.js build/routing), which also serves `NOT_FOUND` even though the build log shows a clean `next build`. If this happens: fix the preset in Settings, then redeploy (build-cache-skipped) — changing the setting alone doesn't retroactively fix the current production deployment.
4. Env vars (Settings → Environment Variables), scoped to **Production + Preview** (not Development — local dev reads `.env` directly per this repo's convention): `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`. HubSpot/Resend keys are **not** added here — only n8n talks to those services; the Next.js app never does.
5. Push to `main` → production deploy. Opening a PR → preview deploy + a Vercel bot comment on the PR with per-project preview URLs. Verified both directions live (2026-07-07): placeholder page reachable on the production URL and on a throwaway test-branch PR's preview URL.
6. **Watch for duplicate Vercel projects on the same repo.** An earlier failed/misconfigured import attempt can leave a second Vercel project still wired to GitHub pushes/PRs alongside the working one — both then post separate status checks. Vercel Settings → Advanced → Delete Project removes the stray one; check the PR bot comment's project table if checks look duplicated.

### Custom domain: leads.nicopxm.me

Root `nicopxm.me` is reserved for a future personal portfolio site, not this pipeline — see docs/DECISIONS.md (2026-07-07, revises the 2026-07-02 domain decision). The pipeline lives at the subdomain `leads.nicopxm.me` instead.

1. Vercel project (`lead-intelligence-pipeline-8uzs`) → Settings → **Domains** → add `leads.nicopxm.me`.
2. Vercel shows a CNAME target for the subdomain (a root/apex domain would need an A record instead, but a subdomain always gets a CNAME). At setup time this was `cname.vercel-dns.com.` — always confirm against what the Domains page actually displays, since Vercel can issue a project- or region-specific target.
3. Porkbun (nicopxm.me → DNS Records) → add: type `CNAME`, host `leads`, answer `cname.vercel-dns.com.` (or whatever Vercel showed), TTL 600 (default).
4. Propagation was fast (a few minutes); Vercel auto-issues the TLS cert once the CNAME resolves and marks the domain "Valid". Verified live (2026-07-07): `https://leads.nicopxm.me` returns 200 with a valid cert and serves the app.

## Restore-from-scratch
1. Provision a new Hetzner VPS per "Hetzner provisioning" above (or restore from a Hetzner snapshot/backup if one exists — none configured yet, see backlog).
2. Harden per the steps above (non-root user, ufw, fail2ban, disable password/root SSH).
3. Install Docker via `curl -fsSL https://get.docker.com | sh`.
4. Clone this repo (or just copy `n8n/docker-compose.yml` and `n8n/Caddyfile`) to `~/n8n` on the new server.
5. Recreate `~/n8n/.env` with `N8N_HOST`, `GENERIC_TIMEZONE`, `BASIC_AUTH_USER`, `BASIC_AUTH_HASH` (regenerate the hash if the password changed).
6. If migrating from an old server and you want to keep existing workflows: copy the `n8n_data` Docker volume across (`docker run --rm -v n8n_data:/from -v /path:/to alpine cp -a /from/. /to/`) before first `docker compose up -d` on the new box. Otherwise n8n starts fresh.
7. `cd ~/n8n && docker compose up -d`.
8. Update the Porkbun A record to the new server's IP if the IP changed.
9. Apply Supabase migrations from `supabase/migrations/`.
10. Verify HubSpot Service Key still valid.
11. Redeploy Next.js app on Vercel (auto on push to main).
