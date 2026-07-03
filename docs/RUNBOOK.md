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
- [ ] Vercel CI/CD connection (#5)
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
- `caddy` (caddy:2-alpine) — publishes 80/443, terminates TLS via Let's Encrypt (automatic HTTPS, no config needed beyond the domain in the Caddyfile), reverse-proxies to `n8n:5678`, and enforces HTTP Basic Auth in front of the whole app (`basicauth` directive — this gates the n8n editor itself, not just a sub-path).

**Secrets**: an `.env` file lives in `~/n8n/.env` on the VPS only (`chmod 600`, owned by `deploy`) — never committed. It sets `N8N_HOST`, `GENERIC_TIMEZONE`, `BASIC_AUTH_USER`, `BASIC_AUTH_HASH`. See `.env.example` in the repo root for the documented variable names.

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
