# CLAUDE.md — Lead Intelligence Pipeline (repo instructions for Claude Code)

## What this is
AI-powered lead pipeline: new lead → enriched → scored vs configurable ICP → personalized draft email → HubSpot, in <90 seconds. Portfolio anchor project for Wop (Full-Stack/Automation/RevOps/Growth Engineer roles). Phase 2 = deploy for a real business, so EVERYTHING is config-driven, never hardcoded.

## Your role vs the architect chat
You (Claude Code) do ALL implementation: code, terminals, servers, debugging, commits — one GitHub issue at a time. Design decisions, prompt engineering, sprint planning, and doc drafting happen in a separate architect chat with Wop. If a task requires a genuine design/architecture decision not covered by docs/, STOP and surface it to Wop — do not decide under momentum.

## Stack (decided — do not re-litigate)
Next.js/Vercel · Supabase (Postgres, source of truth) · n8n self-hosted Docker on Hetzner · HubSpot Free · Claude API · Resend

## Architecture (5 components)
1. INTAKE: Next.js form + universal webhook. Schema: {name, email, company, domain, source, message, timestamp}
2. ENRICHMENT (n8n): website scrape (home/about/pricing) w/ retries+timeouts+graceful partial failure; tech-stack detection; news via search API. Dedupe: same email/domain in 30 days = update not insert. Paid enrichment (Clearbit/Apollo) must be swap-in-able.
3. INTELLIGENCE (Claude API): one structured call → strict JSON {icp_score 0-100, score_reasoning, company_summary, buying_signals[], objection_risks[], draft_email}. ICP lives in config JSON (docs/ICP-CONFIG.md). Validate + retry malformed output. Log tokens/cost per lead.
4. CRM DELIVERY: HubSpot properties + note w/ draft email; score ≥75 → instant alert; ALL errors alert Wop. No silent failures, ever.
5. REPORTING: Next.js dashboard (volume, score distribution, source quality, latency); weekly n8n cron → Claude-written summary → Resend.

Full rationale: docs/ARCHITECTURE.md. Read it before structural work.

## Success metrics
<90s form-to-CRM · <$0.02/lead · >85% enrichment success · zero silent failures

## Working rules
- Session start: check LOG.md has a line for today's date. If missing, prompt Wop for Y/T/B (Yesterday/Today/Blockers) before starting any issue work — don't write the line yourself, LOG.md is Wop's.
- Work ONE GitHub issue at a time (single-piece flow). The issue's acceptance criteria are the spec. Reference the issue in commits; close with "Closes #N".
- Board (GitHub Projects: Backlog → Sprint → In Progress → Done) is the single source of truth. Move the issue to In Progress when starting.
- Mid-task ideas → create a Backlog issue via `gh issue create`, do NOT implement.
- Definition of Done: merged to main, pushed to origin, deployed, verified end-to-end, errors alert, docs updated, issue closed. Never end an issue with unpushed commits. If the issue touched n8n workflows, do a fresh export (n8n "..." menu → Download) of every affected workflow and diff it against what's committed in `n8n/workflows/` before closing — live in-editor fixes (credential wiring, node reconfiguration, drift from the originally-imported JSON) do not retroactively update the repo on their own.
- Config-driven everything: ICP, credentials, client identity, thresholds. If you're about to hardcode a value that could differ per tenant, put it in config/env instead.
- No silent failures: every workflow/route gets an error path that alerts. If you can't alert yet (early sprints), log loudly and leave a TODO issue.
- Legal data sources only. No LinkedIn scraping, ever.
- Cost discipline: free tiers, cheapest options, batch/cache Claude calls where possible.

## Docs to maintain
- docs/RUNBOOK.md — update when infra changes (server setup, docker, env, restore steps)
- docs/DECISIONS.md — one line per significant choice (date, decision, why)
- .env.example — keep current with every new env var
- LOG.md — Wop's daily standup lines (don't edit)
- RETROS.md — Friday retros (don't edit)

## Conventions
- TypeScript everywhere in the Next.js app; zod for validation at every boundary (webhook payloads, Claude JSON output, ICP config load).
- Supabase migrations in repo (`supabase/migrations/`), never dashboard-only schema changes.
- n8n workflows exported as JSON into `n8n/workflows/` after every change — workflows must be restorable from the repo.
- Secrets only in env; .env.example documents every var with a comment.
- Commits: small, imperative mood, reference issue number.

## Current status
Sprint 1 — CLOSED. Goal (form submission lands in Supabase and HubSpot raw) met and verified.
Done: #1 (scaffolding), #2 (Hetzner + Docker + n8n), #3 (Supabase project + leads schema migration), #4 (HubSpot Service Key + contact verification — used a Service Key instead of the legacy private app named in the issue, see docs/DECISIONS.md), #7 (universal webhook intake — verified end-to-end incl. a forced-failure test of the dead-letter/alert path; several real n8n/Caddy bugs found and fixed along the way, see docs/DECISIONS.md and docs/RUNBOOK.md), #5 (Next.js TypeScript app scaffolded in web/, Vercel CI/CD connected — Root Directory=web and Framework Preset=Next.js both had to be set explicitly or every route 404'd; verified production deploy and PR preview deploy live, see docs/RUNBOOK.md), #6 (intake form at / — shared zod validation client+server, domain derivation with free-mail exclusion, posts via a server-side API route to the n8n webhook; verified end-to-end on production including the free-mail edge case and failure states preserving input, see docs/RUNBOOK.md), #17 (demo-ready form styling — CSS Modules + custom properties, no new deps, single accent color, focus/loading/success/error states, mobile-verified on production, see docs/RUNBOOK.md), #8 (Sprint 1 end-to-end verification — fresh happy-path run (Supabase row + HubSpot contact confirmed via API) and deliberate HubSpot-credential-failure test (dead-letter to status=error, no HubSpot contact, correct alert email, clean restore with no republish needed) both verified in production on 2026-07-08; HubSpot Free's default contacts list view doesn't reliably show custom properties — use a saved view, see docs/RUNBOOK.md; 60s review recording linked in the issue). Also: custom domain leads.nicopxm.me wired (revises the 2026-07-02 root-domain decision — root is now reserved for a future portfolio site, see docs/DECISIONS.md); the earlier stray duplicate Vercel project and its Safe Browsing flag are fully resolved (docs/RUNBOOK.md).
Backlog (not scheduled): #15 (replace Caddy basic auth with session-based access — spun out of #7), #18 (Form UI polish/branding/animations — spun out of #17, deferred to Sprint 5). Neither blocks anything.
Now on: Sprint 2 — Goal: every lead automatically gains a structured company profile (enrichment). #19 (scaffolding: LOG hook, enrichment record contract in ARCHITECTURE.md, enriched_at migration, 3 design-decision lines) done — see docs/DECISIONS.md for the no-headless-browser / fingerprinting-over-paid-API / Google-News-RSS decisions. #20 (website scraper: two n8n sub-workflows, `Website Scraper` + `Website Scraper - Fetch Page`, home/about/pricing with fallback paths, minimal robots.txt enforcement, 4,000-char cap; live-verified 2026-07-14 against all 5 cases — normal site, 404-heavy, robots-disallowed, JS-only SPA, null-domain — see docs/RUNBOOK.md; two bugs found and fixed during verification: HTTP response body lands in `$json.data` not `$json.body`, and the empty-content threshold was raised 40→80 chars, both in docs/DECISIONS.md) done, later amended by #21 to add `website.raw_artifacts`. #21 (tech-stack fingerprinting: `config/tech_fingerprints.json` config-as-data, new `Tech Stack Detector` sub-workflow, config bind-mounted read-only into the n8n container via `CONFIG_DIR`; live-verified 2026-07-14/15 against 3 real sites with known stacks — stripe.com→Next.js, wordpress.org→WordPress, gymshark.com→Shopify — plus no-HTML/skip and a genuinely-triggered config-unreadable/alert case; several real n8n gotchas found along the way (Code sandbox has no global `URL`, a file-read node can silently succeed with zero output items on every branch, Error Workflows don't fire on manual editor test runs), all now in docs/RUNBOOK.md for #22/#23 to inherit) done. #22 (news via Google News RSS: new `News RSS` sub-workflow, quoted-company-name query, top 5 items last 90 days as `{title, source, date, url}`, zero results = status=ok not failed; live-verified 2026-07-15 against Stripe (5 items) and a fake company (empty items); RSS fetch failure verified as graceful status=failed/reason=fetch_failed with no alert, and a genuinely alert-worthy failure (bad Supabase table) verified to actually deliver the Resend alert email, confirmed via Resend's own API send log rather than assumed; ARCHITECTURE's news contract updated with a name-collision-is-weak-evidence decision feeding Sprint 3's prompt) done — deployed/verified entirely via n8n CLI (`import:workflow`/`publish:workflow`/`export:workflow` + `docker compose restart n8n`) with no editor/browser access this session, now the documented non-interactive path in RUNBOOK for #23 onward. #23 (orchestration) next.
[UPDATE THIS EVERY SESSION]

## Don't do this
- Don't re-litigate the stack or architecture — surface concerns to Wop instead.
- Don't implement backlog ideas mid-sprint.
- Don't scrape LinkedIn or any auth-walled source.
- Don't hardcode tenant-specific values (ICP, names, thresholds, sender identity).
- Don't make schema changes without a migration file.
- Don't swallow errors. No empty catch blocks.
- Don't echo secret values into output — verify presence/shape only (e.g. pattern-match a prefix, check non-empty), never print or feed into a command that could leak it on error (curl -v, unvalidated var extraction).
[grows over time]
