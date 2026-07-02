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
- [ ] Hetzner provisioning steps (#2)
- [ ] Docker + n8n setup and restart/reboot recovery (#2)
- [ ] Supabase project setup + migration workflow (#3)
- [ ] HubSpot private app setup (#4)
- [ ] Vercel CI/CD connection (#5)
- [ ] Restore-from-scratch procedure (full stack)

## Restore-from-scratch (stub)
1. Clone repo.
2. Copy `.env.example` to `.env`, fill in secrets.
3. `cd n8n && docker compose up -d` on the VPS.
4. Apply Supabase migrations from `supabase/migrations/`.
5. Verify HubSpot private app token still valid.
6. Redeploy Next.js app on Vercel (auto on push to main).
