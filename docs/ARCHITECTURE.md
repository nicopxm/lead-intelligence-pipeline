# Architecture — Lead Intelligence Pipeline

New lead → enriched → scored against a configurable ICP → personalized draft email → HubSpot, in under 90 seconds. Every decision below includes the WHY, because every one of them is an interview question.

## System diagram

```
┌──────────────┐     ┌─────────────────────────────────────────┐
│ Next.js form │────▶│  Universal webhook (n8n)                │
│ (Vercel)     │     │  validates → writes raw lead → Supabase │
└──────────────┘     └──────────────┬──────────────────────────┘
  any other source ──▶ same webhook │
                                    ▼
                     ┌──────────────────────────────┐
                     │ ENRICHMENT (n8n)             │
                     │ scrape home/about/pricing    │
                     │ tech-stack detect · news     │
                     │ retries · timeouts · partial │
                     │ failure OK · 30-day dedupe   │
                     └──────────────┬───────────────┘
                                    ▼
                     ┌──────────────────────────────┐
                     │ INTELLIGENCE (Claude API)    │
                     │ one structured call →        │
                     │ strict JSON: score, reasons, │
                     │ signals, risks, draft email  │
                     │ validate + retry · cost log  │
                     └──────────────┬───────────────┘
                                    ▼
                     ┌──────────────────────────────┐
                     │ CRM DELIVERY (HubSpot)       │
                     │ properties + note w/ draft   │
                     │ score ≥75 → instant alert    │
                     │ ANY error → alert (no silent │
                     │ failures, ever)              │
                     └──────────────┬───────────────┘
                                    ▼
                     ┌──────────────────────────────┐
                     │ REPORTING                    │
                     │ Next.js dashboard (Supabase) │
                     │ weekly cron → Claude summary │
                     │ → Resend email               │
                     └──────────────────────────────┘
```

## Core decisions and their WHYs

### 1. Supabase is the source of truth, not HubSpot
**Why:** CRMs are terrible databases — rate-limited APIs, opaque schemas, vendor lock-in. Postgres gives us full SQL for the dashboard, cheap storage of raw enrichment payloads (HubSpot properties would be lossy), and makes Phase 2 CRM-agnostic: swapping HubSpot for Pipedrive touches only the delivery layer.
**Tradeoff accepted:** two systems can drift. Mitigation: HubSpot is write-only downstream; we never read state back from it.

### 2. n8n (self-hosted) for orchestration, not custom code or Zapier
**Why:**
- vs. custom Node service: n8n gives retries, error branches, cron, and a visual execution log for free — exactly the boring reliability plumbing that eats weeks. The visual workflow is also a portfolio artifact a hiring manager can *see*.
- vs. Zapier/Make: cost scales per-task (kills the <$0.02/lead target), and self-hosting demonstrates Docker/VPS ops for RevOps/Automation roles.
- Self-hosted on Hetzner: cheapest reliable VPS class; full control; ~€4/mo.
**Tradeoff accepted:** we own uptime. Mitigation: uptime monitoring in Sprint 5; n8n in Docker so restore = `docker compose up` on any box.

### 3. One structured Claude call, not an agent or multi-call chain
**Why:** one call = one point of failure, one cost line, one latency line, predictable at scale. Scoring, summary, signals, risks, and the draft email all condition on the same context anyway — splitting them multiplies tokens without adding information. Agentic loops are unjustifiable for a deterministic pipeline with a fixed output shape.
**Guardrails:** strict JSON schema, validation layer, retry-once-on-malformed, then dead-letter with alert. Tokens and cost logged per lead so the $0.02 target is measured, not vibes.

### 4. ICP as config JSON, not prompt text or code
**Why:** Phase 2 is "deploy for a real business" — that must be a config swap, not a rebuild. Config JSON is versionable, diffable, validatable, and multi-tenant-ready (one config per client). The prompt is a template; the ICP is data injected into it. See ICP-CONFIG.md.

### 5. Universal webhook as the single intake path
**Why:** the form is just the first source. LinkedIn ads, Calendly, a partner's Typeform — everything hits one webhook with one schema `{name, email, company, domain, source, message, timestamp}`. New source = new mapping, not new pipeline. `source` field feeds the source-quality dashboard directly.

### 6. Dedupe at intake: same email/domain within 30 days = UPDATE, not INSERT
**Why:** real leads resubmit forms, download two whitepapers, get uploaded twice. Duplicates would double Claude cost, spam HubSpot, and corrupt dashboard metrics. 30 days chosen because a returning lead after a month is plausibly a *new buying event* worth re-enriching (news and tech stack change).
**Edge case:** same email, different domain (person changed jobs) → treat as new lead; the domain is the enrichment key.

### 7. Graceful partial enrichment, never pipeline death
**Why:** scraping fails constantly — Cloudflare, JS-only sites, timeouts, robots.txt. A lead with only a homepage scrape and no news is still scoreable; a dead pipeline is a lost lead. Each enrichment step has a timeout + retry budget, then writes what it got with an `enrichment_status` per field. The intelligence prompt is written to handle sparse input honestly (score reasoning must acknowledge missing data).
**Legal line:** public website pages + news APIs only. No LinkedIn scraping — ToS violation, and "we stayed compliant" is itself an interview answer.

### 8. No silent failures — every error alerts
**Why:** a lead pipeline that fails silently is worse than none: the business believes it's covered while leads rot. Every workflow has an error branch → alert to Wop with lead ID + failing step. Failed leads land in a dead-letter state in Supabase, replayable after fix.

### 9. Paid enrichment (Clearbit/Apollo) is swap-in-able, not built-in
**Why:** free scraping proves the architecture at $0 marginal cost; paid enrichment is a Phase 2 per-client business decision. The enrichment record schema is provider-agnostic, so swapping the scraper node for an Apollo node changes nothing downstream.

## Enrichment record contract

The `leads.enrichment` JSONB column (see #7's migration) holds one object per lead with three top-level keys, one per enrichment step. Each step reports its own `status` so a partial failure in one step never blocks the others or the pipeline (see decision #7 above).

```json
{
  "website": {
    "status": "ok | partial | failed | skipped",
    "pages": {
      "home":    { "status": "ok | partial | failed", "text": "...", "url": "..." },
      "about":   { "status": "ok | partial | failed", "text": "...", "url": "..." },
      "pricing": { "status": "ok | partial | failed", "text": "...", "url": "..." }
    },
    "fetched_at": "2026-07-13T12:00:00Z"
  },
  "tech_stack": {
    "status": "ok | partial | failed | skipped",
    "detected": ["..."],
    "method": "html_fingerprinting"
  },
  "news": {
    "status": "ok | partial | failed | skipped",
    "items": [{ "title": "...", "url": "...", "published_at": "..." }],
    "fetched_at": "2026-07-13T12:00:00Z"
  }
}
```

Status meanings (consistent across all three steps):
- `ok` — step ran and returned usable data
- `partial` — step ran but some sub-parts failed (e.g. one of three pages, or a fingerprint match with low confidence)
- `failed` — step ran and returned nothing usable
- `skipped` — step never ran (e.g. `website`/`tech_stack` skipped when `domain` is null; the intelligence prompt is written to handle sparse/skipped input honestly, per decision #7)

`leads.enriched_at` (added in this issue's migration) is set once orchestration finishes writing this object, regardless of how many sub-steps came back partial/failed/skipped — it marks "enrichment ran," not "enrichment fully succeeded."

## Latency budget (<90s form-to-CRM)

| Stage | Budget |
|---|---|
| Intake → Supabase | <2s |
| Enrichment (scrape ×3 pages + news, parallel) | <45s |
| Claude call incl. one retry | <25s |
| HubSpot write + alert | <8s |
| Slack/buffer | ~10s |

## Cost budget (<$0.02/lead)
Claude call is ~all of it: sparse input (~3–5k tokens in, ~1k out) on a mid-tier model lands well under 2¢. Scraping, n8n, Supabase free tier, HubSpot free = $0 marginal. Per-lead token/cost logging makes this auditable.

## Failure modes summary

| Failure | Behavior |
|---|---|
| Scrape timeout / block | Partial enrichment, flagged, continue |
| Claude malformed JSON | Retry once → dead-letter + alert |
| Claude API down | Dead-letter queue, replayable, alert |
| HubSpot API error | Retry with backoff → alert; lead safe in Supabase |
| Duplicate lead | Update-in-place, no new Claude call unless >30 days |
| n8n down | Uptime monitor alerts (Sprint 5); webhook source retries |
