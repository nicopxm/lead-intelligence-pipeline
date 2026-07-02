# 5-Sprint Plan — Lead Intelligence Pipeline

## Scrum mechanics (how the sprints run)
- Each sprint below = one GitHub Milestone with its issues; progress visible on the GitHub Projects board (Backlog → Sprint → In Progress → Done).
- Repo contains LOG.md (daily standups) and RETROS.md (Friday retros).
- Sprint 1 includes a setup task: create the board, milestones for all 5 sprints, issues for Sprints 1–2 in detail (Sprints 3–5 stay coarse in Backlog — refining them later IS backlog grooming), plus LOG.md and RETROS.md.
- The process itself is a portfolio artifact: closed issues linked to commits, five demo recordings, and retros demonstrate working Scrum experience to interviewers.

## Sprint 1 — Foundation
Hetzner VPS + Docker + n8n deployed · Supabase project + schema · HubSpot dev account · GitHub repo + Vercel CI · intake form + universal webhook.
SPRINT GOAL / DELIVERABLE: a form submission lands in Supabase and HubSpot raw. End-to-end plumbing proven.

## Sprint 2 — Enrichment
Website scraping workflow with retries, timeouts, graceful partial failure · news pull via search API · normalization into enrichment record · dedupe logic (same email/domain in 30 days = update, not insert).
SPRINT GOAL / DELIVERABLE: every lead automatically gains a structured company profile. Document edge cases handled.

## Sprint 3 — Intelligence
ICP config format (JSON, multi-tenant-ready) · structured-output Claude prompt + validation/retry layer · token/cost logging per lead · test and tune against 30–50 synthetic leads of varying quality.
SPRINT GOAL / DELIVERABLE: leads arrive scored with drafted personalized outreach.

## Sprint 4 — Delivery + Dashboard
HubSpot writes (score + summary as properties, draft email as note) · hot-lead alerts (score ≥75) · error alerting · dashboard v1 (volume, score distribution, source quality, latency).
SPRINT GOAL / DELIVERABLE: closed loop — form fill → ≤90 seconds → scored lead in HubSpot with alert fired.

## Sprint 5 — Hardening + Polish
Weekly Claude-written summary report via Resend · 100-lead batch load test · uptime monitoring on n8n · polished README with architecture diagram, cost-per-lead analysis, edge cases, tradeoffs · 3-minute Loom walkthrough.
SPRINT GOAL / DELIVERABLE: shipped, documented, defensible portfolio artifact.

## Phase 2 (after Sprint 5 — context, not current scope)
Deploy for one real small business: swap in their ICP config + HubSpot. Run 30–60 days. Capture before/after response times and reply rates. Publish public write-up.