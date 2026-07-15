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
      "home":    { "status": "ok | failed | skipped", "text": "...", "url": "...", "reason": "fetch_failed | robots_disallowed | empty_content" },
      "about":   { "status": "ok | failed | skipped", "text": "...", "url": "...", "reason": "fetch_failed | robots_disallowed | empty_content" },
      "pricing": { "status": "ok | failed | skipped", "text": "...", "url": "...", "reason": "fetch_failed | robots_disallowed | empty_content" }
    },
    "raw_artifacts": {
      "home":    { "script_hosts": ["..."], "link_hosts": ["..."], "meta_generator": "...", "header_names": ["..."], "script_path_markers": ["..."] },
      "about":   { "script_hosts": ["..."], "link_hosts": ["..."], "meta_generator": "...", "header_names": ["..."], "script_path_markers": ["..."] },
      "pricing": { "script_hosts": ["..."], "link_hosts": ["..."], "meta_generator": "...", "header_names": ["..."], "script_path_markers": ["..."] }
    },
    "fetched_at": "2026-07-13T12:00:00Z"
  },
  "tech_stack": {
    "status": "ok | failed | skipped",
    "detected": ["..."],
    "method": "fingerprint",
    "reason": "no_html | config_unreadable"
  },
  "news": {
    "status": "ok | failed | skipped",
    "items": [{ "title": "...", "source": "...", "date": "...", "url": "..." }],
    "reason": "no_company | fetch_failed | parse_failed",
    "fetched_at": "2026-07-13T12:00:00Z"
  }
}
```

Status meanings (consistent across all three steps, though not every step uses every value — `news` has no `partial`, its RSS query is one atomic fetch, not several pages that can fail independently):
- `ok` — step ran and returned usable data
- `partial` — step ran but some sub-parts failed (e.g. one of three pages, or a fingerprint match with low confidence)
- `failed` — step ran and returned nothing usable
- `skipped` — step never ran (e.g. `website`/`tech_stack` skipped when `domain` is null; `news` skipped when `company` is null; the intelligence prompt is written to handle sparse/skipped input honestly, per decision #7)

Per-page status (added by issue #20, `website.pages.*` only) uses a narrower enum than the step-level status above — `ok | failed | skipped`, no `partial` (partial only describes the aggregate across pages). A `reason` field is present whenever a page's status isn't `ok`:
- `fetch_failed` — request errored, timed out, or returned a non-2xx status after the retry
- `robots_disallowed` — the page's path is disallowed by the domain's `robots.txt` for our User-Agent, so it was never fetched (page status is `skipped`, not `failed` — no error occurred, we chose not to fetch)
- `empty_content` — the request succeeded but the stripped text was empty/below a minimal-content threshold (the JS-only SPA case: markup fetched fine, nothing renders without a browser)
- `no_domain` — the lead has no domain, so no page was ever attempted (only appears when `website.status=skipped`)

`website.raw_artifacts` (added by issue #21, amending #20's original shape — see docs/DECISIONS.md) captures a small, structured slice of each page's raw HTML *before* it's stripped down to `pages.*.text` — `script_hosts`/`link_hosts` are hostnames only (not full URLs, not full paths), `meta_generator` is the `<meta name="generator">` content if present (else `null`), `header_names` are the HTTP response header *names* only (not values, to stay minimal). This exists solely to feed #21's tech-stack fingerprinting without re-fetching pages; it is not shown to the intelligence prompt or dashboard. A page with no successful fetch (any `pages.*.status` other than `ok`/`failed`-with-`empty_content` — i.e. `robots_disallowed`, `no_domain`, or `fetch_failed`) has no HTTP response body to extract from, so its `raw_artifacts` entry is present but empty (`{ "script_hosts": [], "link_hosts": [], "meta_generator": null, "header_names": [], "script_path_markers": [] }`).

`script_path_markers` is a narrow exception to "hosts only": some tools (Next.js, WordPress, CDN-loaded React) have no reliable third-party host to fingerprint against — Next.js/WordPress serve their own JS from the site's own domain, and React loaded via a general-purpose CDN (unpkg, jsDelivr) shares that host with thousands of unrelated packages. Rather than storing every script's full path (which would balloon artifact size and edge back toward "store all the markup"), scrape time checks each script `src` in full (host + path, not just the extracted hostname) against a small fixed allowlist of known substrings (`/_next/static/`, `/wp-content/`, `/wp-includes/`, `unpkg.com/react`, `jsdelivr.net/npm/react`) and records only which of those markers were seen. This allowlist lives in the #20 scraper's own code (not `config/tech_fingerprints.json`) since it's about *what to look for* in the markup, not the tool-name mapping — extending it requires a #20 code change and re-export, unlike the fully config-driven `script_host`/`link_host`/`meta_generator`/`header_name` fingerprint rules in #21's config.

`tech_stack`'s per-step `reason` (added by issue #21) is present whenever status isn't `ok`:
- `no_html` — `website.raw_artifacts` had no usable pages to fingerprint against (website step failed or was skipped entirely) — not an error, a graceful skip
- `config_unreadable` — `config/tech_fingerprints.json` could not be read at execution time (bind mount missing, file malformed, etc.) — this **is** an operational failure and fires the error-alert path (unlike every other `skipped`/`failed` reason in this contract, which are expected, graceful outcomes)

`news`'s per-step `reason` (added by issue #22) is present whenever status isn't `ok`:
- `no_company` — the lead has no `company` value, so no query could be built (status is `skipped`, not `failed` — no error occurred, we chose not to query)
- `fetch_failed` — the Google News RSS request errored, timed out, or returned a non-2xx status after the retry
- `parse_failed` — the request succeeded but the response body wasn't parseable as the expected RSS/XML shape

Zero matching articles is a normal, expected outcome for an obscure or newly-formed company — it is **not** a failure. `news.status` is `ok` with `items: []` in that case; only a genuine fetch/parse breakdown sets `status: failed`.

**Name-collision risk (documented per #22, feeds Sprint 3 prompt design):** the query is the company name in quotes, not disambiguated by domain or industry — a lead named "Atlas" or "Summit" will pull news for every unrelated company sharing that name. This is a known, accepted limitation of free RSS search (no company-ID lookup available at this cost tier). `news.items` must therefore be treated as **weak evidence** by the Sprint 3 scoring prompt, not a verified signal — the prompt should be written to cite news cautiously (e.g. "may relate to a same-named company") rather than asserting buying signals from it at face value. Fetch honestly, score skeptically; no relevance filtering happens at fetch time.

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
