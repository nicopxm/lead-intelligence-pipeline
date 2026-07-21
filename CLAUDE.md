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
- Definition of Done: merged to main, pushed to origin, deployed, verified end-to-end, errors alert, docs updated, issue closed. Never end an issue with unpushed commits. If the issue touched n8n workflows, do a fresh export (n8n "..." menu → Download) of every affected workflow and diff it against what's committed in `n8n/workflows/` before closing — live in-editor fixes (credential wiring, node reconfiguration, drift from the originally-imported JSON) do not retroactively update the repo on their own. **Final step, every issue**: verify actual board state via `gh project item-list <n> --owner nicopxm --format json` (or the API) before declaring done — confirm (a) the closed issue's card shows Done, (b) any issue created mid-session (bugs found live, backlog spin-outs) is actually ON the board and in the correct column, (c) rolled/re-triaged issues' columns match their real status. If GitHub's automation already did this, the check takes 5 seconds; if not, fix it in the same session — don't defer to "next time."
- Config-driven everything: ICP, credentials, client identity, thresholds. If you're about to hardcode a value that could differ per tenant, put it in config/env instead.
- No silent failures: every workflow/route gets an error path that alerts. If you can't alert yet (early sprints), log loudly and leave a TODO issue.
- Legal data sources only. No LinkedIn scraping, ever.
- Cost discipline: free tiers, cheapest options, batch/cache Claude calls where possible.
- Monday planning updates the sprint milestone description with goal / scope notes / named day — the milestone is the planning record.
- Reading credentials from `.env`/`web/.env.local` to run verification (Supabase/HubSpot REST or API queries) is sanctioned standing policy, not a one-off — this is how sessions confirm real production state instead of asking Wop to relay it. Three rules govern it: (1) never echo secret values into output — shape/presence checks only (pattern-match a prefix, check non-empty), same method as the secrets rule below; (2) read-only verification calls (SELECTs, GETs, searches) are fine to run unprompted, no need to ask first; (3) any WRITE to a production system via a direct API call made *outside* a workflow's own execution — inserts, deletes, config changes — gets named explicitly in the session summary, the way #24's test-row/test-contact cleanup was called out. See docs/RUNBOOK.md's "Local credentials surface" note for the key-rotation consequence of this.

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
Backlog (not scheduled): #15 (replace Caddy basic auth with session-based access — spun out of #7), #18 (Form UI polish/branding/animations — spun out of #17, deferred to Sprint 5), #26 (Tech Stack Detector `config_unreadable` regression — config file present/readable but the node fails anyway, found live during #23; every real lead currently gets `tech_stack.status: "failed"` until this lands). None block anything.
Sprint 2 — CLOSED (2026-07-17). Goal (every lead automatically gains a structured company profile) met. #19/#20/#21/#22 done (see prior entries). #23 (enrichment orchestration: new `Enrichment Orchestrator` workflow composes Website Scraper → Tech Stack Detector → News RSS sequentially, writes `leads.status`/`enriched_at`/new `enrichment_duration_ms` column iff at least one component reached ok/partial, else leaves status at raw and alerts; wired into `Lead Intake` as a fire-and-forget branch off `Supabase - Insert Lead`, `waitForSubWorkflow: false` verified against the live n8n image so the ~45s enrichment budget never blocks the webhook response, measured 3.4s; live-verified 2026-07-17 end-to-end through the real webhook — not a harness, retiring the #21/#22 harness pattern — both happy path (Stripe lead → enriched, all Supabase fields populated, duration recorded) and alert path (unreachable domain + no company → stays raw, exactly one alert delivered per Resend's own send log); two real orchestration bugs found and fixed live — missing `onError` handling let one component's genuine failure kill the whole chain and double-alert, and missing `alwaysOutputData` let a sub-workflow's zero-item success silently truncate the chain (a recurrence of #21's "zero output items" gotcha) — both now in docs/RUNBOOK.md/DECISIONS.md; also surfaced and filed #26, a pre-existing Tech Stack Detector regression, unrelated to #23, not fixed here) done.
Now on: Sprint 3 — planned 2026-07-20 (milestone description holds the goal/scope/named-day record going forward, see the new Working rules line). #26 closed 2026-07-20: root cause was n8n's fire-and-forget (`waitForSubWorkflow:false`) sub-workflow invocation breaking an async binary-data helper call several levels down the `Lead Intake` → `Enrichment Orchestrator` → `Tech Stack Detector` chain — reproducible only through the real webhook path, never in standalone or manual full-chain testing (see docs/RUNBOOK.md's n8n operational notes). Fixed by replacing the Code-node `getBinaryDataBuffer` call with n8n's built-in Extract From File node; re-verified #21's full original acceptance criteria (3+ known-stack sites, no-HTML skip, config-unreadable failure+alert, clean recovery) through 6 real leads via the actual webhook, not editor tests. Also added a RUNBOOK "Verification schedule" section per the Sprint 2 retro's re-verification-cadence takeaway. #24 closed 2026-07-21: dedupe enforcement (30-day update-not-insert) at intake — matching resolved as domain-priority-with-email-fallback (not a literal "email OR domain" reading, which contradicted the issue's own job-change bullet and ARCHITECTURE #6; documented on the issue and in docs/DECISIONS.md), `Lead Intake` gained a `Compute Dedupe Key → Has Domain? → Find Lead By Domain/Email → Decide Dedupe Action → Insert or Update? → Normalize Lead Record → Should Reenrich?` branch, HubSpot's contact node turned out to already upsert by email (rename only, no logic change), and the job-change edge case's Supabase-vs-HubSpot asymmetry (two leads, one contact) was deliberately accepted and live-verified, not left emergent — see docs/DECISIONS.md and docs/RUNBOOK.md's new "Dedupe enforcement (#24)" section for full verification evidence. #25 remains absorbed into Sprint 3 verification per the milestone description.
[UPDATE THIS EVERY SESSION]

## Don't do this
- Don't re-litigate the stack or architecture — surface concerns to Wop instead.
- Don't implement backlog ideas mid-sprint.
- Don't scrape LinkedIn or any auth-walled source.
- Don't hardcode tenant-specific values (ICP, names, thresholds, sender identity).
- Don't make schema changes without a migration file.
- Don't swallow errors. No empty catch blocks.
- Don't echo secret values into output — verify presence/shape only (e.g. pattern-match a prefix, check non-empty), never print or feed into a command that could leak it on error (curl -v, unvalidated var extraction).
- Don't end a session with board state that contradicts issue state — the board is the single source of truth only if it's true. Verify with `gh project item-list`, don't assume `gh issue close` or a labeled automation handled it.
[grows over time]
