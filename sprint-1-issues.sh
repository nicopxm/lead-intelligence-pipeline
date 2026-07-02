#!/usr/bin/env bash
# Sprint 1 — Foundation. Run once from the repo root (gh auth'd).
# Goal: a form submission lands in Supabase and HubSpot raw. End-to-end plumbing proven.
set -euo pipefail

# --- Milestones for all 5 sprints (adjust due dates to your calendar) ---
gh api repos/:owner/:repo/milestones -f title="Sprint 1 — Foundation" -f due_on="2026-07-10T23:59:59Z" -f description="Form submission lands in Supabase and HubSpot raw."
gh api repos/:owner/:repo/milestones -f title="Sprint 2 — Enrichment" -f due_on="2026-07-17T23:59:59Z" -f description="Every lead automatically gains a structured company profile."
gh api repos/:owner/:repo/milestones -f title="Sprint 3 — Intelligence" -f due_on="2026-07-24T23:59:59Z" -f description="Leads arrive scored with drafted personalized outreach."
gh api repos/:owner/:repo/milestones -f title="Sprint 4 — Delivery + Dashboard" -f due_on="2026-07-31T23:59:59Z" -f description="Closed loop: form fill → ≤90s → scored lead in HubSpot with alert."
gh api repos/:owner/:repo/milestones -f title="Sprint 5 — Hardening + Polish" -f due_on="2026-08-07T23:59:59Z" -f description="Shipped, documented, defensible portfolio artifact."

# --- Issue 1: process scaffolding ---
gh issue create --milestone "Sprint 1 — Foundation" --title "Set up Scrum scaffolding: project board, LOG.md, RETROS.md, coarse backlog" --body "$(cat <<'EOF'
Plain task (infra/process).

## Acceptance criteria
- [ ] GitHub Projects board created with columns: Backlog → Sprint → In Progress → Done
- [ ] All Sprint 1 issues added to board in Sprint column
- [ ] Coarse backlog issues created for Sprints 3–5 (one umbrella issue per sprint, refined later = backlog grooming)
- [ ] LOG.md created with format header (date / yesterday / today / blockers)
- [ ] RETROS.md created with format header (what worked / what didn't / one change)
- [ ] docs/DECISIONS.md and docs/RUNBOOK.md stubs created
- [ ] .env.example created (empty but present)
EOF
)"

# --- Issue 2: Hetzner + Docker + n8n ---
gh issue create --milestone "Sprint 1 — Foundation" --title "Provision Hetzner VPS with Docker and deploy n8n" --body "$(cat <<'EOF'
Plain task (infra).

## Acceptance criteria
- [ ] Cheapest suitable Hetzner VPS provisioned; SSH key auth only, password login disabled
- [ ] Basic hardening: ufw (only 22/80/443), fail2ban, non-root user
- [ ] Docker + docker compose installed
- [ ] n8n running via docker-compose.yml committed to repo (n8n/ directory), with persistent volume
- [ ] n8n behind HTTPS (Caddy or Traefik reverse proxy) on a domain/subdomain, basic auth enabled
- [ ] Restart policy verified: `docker compose restart` and full VPS reboot both bring n8n back with data intact
- [ ] docs/RUNBOOK.md updated: provisioning steps, restore-from-scratch procedure
EOF
)"

# --- Issue 3: Supabase project + schema ---
gh issue create --milestone "Sprint 1 — Foundation" --title "Create Supabase project and leads schema (migration-first)" --body "$(cat <<'EOF'
Plain task (infra/data).

## Acceptance criteria
- [ ] Supabase project created (free tier)
- [ ] `leads` table via migration file in supabase/migrations/: id (uuid), name, email, company, domain, source, message, submitted_at, created_at, updated_at, status (enum: raw/enriched/scored/delivered/error), plus jsonb columns enrichment, intelligence reserved for later sprints
- [ ] Unique constraint strategy for dedupe documented in migration comments (email+domain lookup; enforcement logic lands Sprint 2)
- [ ] Row Level Security enabled; service-role key used only server-side
- [ ] .env.example updated with SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
- [ ] docs/DECISIONS.md line added: Supabase as source of truth, HubSpot write-only downstream
EOF
)"

# --- Issue 4: HubSpot dev account + API access ---
gh issue create --milestone "Sprint 1 — Foundation" --title "Set up HubSpot free account with private app token and verify contact creation" --body "$(cat <<'EOF'
Plain task (infra).

## Acceptance criteria
- [ ] HubSpot free account + private app created with crm.objects.contacts write scope (least privilege)
- [ ] Token stored in n8n credentials + .env.example updated (HUBSPOT_TOKEN)
- [ ] Test contact created and deleted via API (curl or n8n node) — proves auth works
- [ ] Custom contact properties created: lead_source, icp_score (number, unused until Sprint 4)
- [ ] docs/RUNBOOK.md updated with HubSpot app setup steps
EOF
)"

# --- Issue 5: Repo + Vercel CI ---
gh issue create --milestone "Sprint 1 — Foundation" --title "Scaffold Next.js app and connect Vercel CI/CD" --body "$(cat <<'EOF'
Plain task (infra).

## Acceptance criteria
- [ ] Next.js (TypeScript) app scaffolded in repo; lint + typecheck pass
- [ ] Vercel project connected to repo: push to main = production deploy; PRs get preview deploys
- [ ] Env vars configured in Vercel (Supabase keys)
- [ ] Placeholder page deployed and reachable on production URL
- [ ] README stub with one-paragraph project description
EOF
)"

# --- Issue 6: Intake form (user story) ---
gh issue create --milestone "Sprint 1 — Foundation" --title "Intake form: prospect can submit a lead" --body "$(cat <<'EOF'
As a prospect, I want to submit my details through a simple form so that the business can follow up with me.

## Acceptance criteria
- [ ] Form at /: name, email, company, domain (optional — derived from email if blank), message
- [ ] Client + server validation with zod (shared schema); invalid email rejected with clear message
- [ ] On submit, payload POSTed to the universal webhook with source="website_form" and timestamp
- [ ] Success and failure states shown to user; failure never loses the typed input
- [ ] Domain derivation edge case handled: free-mail domains (gmail/outlook/etc.) NOT used as company domain — leave domain null instead
EOF
)"

# --- Issue 7: Universal webhook (user story) ---
gh issue create --milestone "Sprint 1 — Foundation" --title "Universal webhook: any lead source lands in Supabase and HubSpot raw" --body "$(cat <<'EOF'
As the business owner, I want every lead source to hit one webhook so that adding a new source never means building a new pipeline.

## Acceptance criteria
- [ ] n8n webhook accepts POST with schema {name, email, company, domain, source, message, timestamp}
- [ ] Payload validated; malformed payload → 400 + logged (visible in n8n executions), not silently dropped
- [ ] Valid lead inserted into Supabase leads table with status="raw"
- [ ] Raw contact created in HubSpot (name, email, company, lead_source property)
- [ ] Error branch in workflow: Supabase or HubSpot failure → execution marked failed + notification to Wop (email or Telegram — simplest that works today; formal alerting matures in Sprint 4)
- [ ] Workflow JSON exported to n8n/workflows/ in repo
- [ ] Manual test evidence: curl with a fake lead → row in Supabase + contact in HubSpot, screenshot/links in issue comment
EOF
)"

# --- Issue 8: Sprint 1 verification + review ---
gh issue create --milestone "Sprint 1 — Foundation" --title "Sprint 1 end-to-end verification and review recording" --body "$(cat <<'EOF'
Plain task (process).

## Acceptance criteria
- [ ] Full path verified on production: submit form on Vercel URL → row in Supabase → contact in HubSpot
- [ ] Deliberate failure test: break HubSpot token, submit lead → alert received, lead still safe in Supabase
- [ ] 60-second screen recording of the working flow (Sprint Review artifact), linked in issue
- [ ] CLAUDE.md "Current status" updated to Sprint 2 goal
- [ ] Retro written in RETROS.md
EOF
)"

echo "Sprint 1 created: 5 milestones, 8 issues."
