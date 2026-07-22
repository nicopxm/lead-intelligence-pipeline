# PIPELINE_REFERENCE.md — Lead Intelligence Pipeline

**Status authority: REALITY.md (external doc) — this file describes design and mechanics, not current build state.**

Snapshot: 2026-07-15.

## System overview

An AI-powered lead pipeline: a new lead lands via a universal webhook, gets enriched from public sources (website content, tech stack, recent news), is scored by a single structured Claude call against a configurable Ideal Customer Profile, and — for leads that clear a threshold — gets a personalized draft email attached to its HubSpot contact record, with an instant alert on high-scoring leads. Supabase Postgres is the system of record; HubSpot is a write-only downstream CRM mirror. Every stage is designed to degrade gracefully (partial enrichment beats a dead pipeline) and to alert loudly on genuine failure rather than fail silently. Everything that could differ per client — ICP weights, thresholds, sender identity, credentials — is config/env, not hardcoded, because the second deployment target is a real client, not just this instance.

## Enrichment mechanics

Enrichment runs as three independent n8n sub-workflows, each taking a lead id, looking up the row, and writing only its own slice of the `leads.enrichment` JSONB column (`website`, `tech_stack`, `news`) so a failure in one never blocks or corrupts the others. Each sub-workflow reports its own `status` (`ok | partial | failed | skipped`, `news` has no `partial` — see below) and, when not `ok`, a `reason` explaining why. An orchestrating workflow merges all three into one write and advances the lead's status once at least one component came back usable.

### Website scraper
Fetches up to three pages per lead — home, about, pricing (with fallback paths per page type) — over HTTP with a 10s timeout and one retry. Each page fetch is gated by a minimal `robots.txt` check (parses the `User-agent: *` block's `Disallow` paths; a missing/unreachable/unparseable robots.txt is treated as permissive, since this check must never itself break enrichment). Successful fetches are stripped of scripts/styles/nav/tags down to plain text, capped at 4,000 characters per page. A page whose stripped text falls under a minimum-content threshold is treated as `empty_content` (catches JS-only SPAs that return markup but render nothing without a browser) rather than `ok`. Alongside the stripped text, a small structured slice of each page's raw HTML is captured — script/link hostnames, `<meta name="generator">` content, response header names, and a fixed set of same-origin path markers (`/_next/static/`, `/wp-content/`, etc.) — purely to feed tech-stack fingerprinting without a second fetch.

**Why no headless browser**: JS-only sites failing to render fully is an accepted partial-failure case, not a gap worth closing — a headless-browser step would roughly triple the infra footprint (browser binaries, memory, per-page execution time) to rescue a minority of sites, blowing both the latency budget and cost discipline for marginal gain.

### Tech-stack fingerprinting
Matches the website step's captured artifacts (script/link hosts, meta generator, header names, path markers) against a config-driven rule set (`config/tech_fingerprints.json` — tool name + match type + pattern) to produce a list of detected tools (e.g. Next.js, WordPress, Shopify, HubSpot). Runs only when the website step produced usable artifacts; otherwise skipped.

**Why fingerprinting over a paid API** (Clearbit/BuiltWith/Wappalyzer-as-a-service): fingerprinting is free and reuses data already fetched by the website step with zero extra requests, and is accurate enough for the ICP's `tech_maturity` signal — a paid per-lookup API would eat directly into the <$0.02/lead cost budget for a signal that doesn't need paid-tier precision. The fingerprint rules are read from a mounted config file at execution time (not embedded in code), so updating detection coverage is a config edit and redeploy, never a workflow change.

### News (Google News RSS)
Queries `https://news.google.com/rss/search?q="<company name>"&hl=en-US&gl=US&ceid=US:en` — the company name in quotes, exactly as entered on the lead, no disambiguation by domain or industry. The RSS response is parsed to a list of articles, filtered to items published within the last 90 days, sorted newest-first, and truncated to the top 5, each captured as `{title, source, date, url}`. Skipped entirely when the lead has no company name.

**Zero-results-as-success semantics**: an obscure or newly-formed company legitimately has no news coverage. That is a normal, expected outcome — `news.status` is `ok` with `items: []`, never `failed`. Only a genuine RSS fetch/parse breakdown sets `status: failed`, and the pipeline continues regardless (a missing news signal never blocks scoring).

**Why RSS over a paid news/search API**: free, no API key, no rate-limit budget to manage — consistent with the cost-discipline principle governing every enrichment choice here.

**Name-collision risk is a deliberate, accepted limitation**: a company sharing its name with an unrelated, more prominent entity will pull that entity's news instead (or alongside). No relevance filtering happens at fetch time — the fetch is honest about what it retrieved, not about whether it's really the same company. This pushes the judgment call downstream: news items must be treated as **weak evidence** by the scoring layer, not a verified fact — the scoring prompt should cite news cautiously (e.g. "may relate to a same-named company") rather than asserting buying signals from it at face value.

## HubSpot integration mechanics

HubSpot is written to, never read from — Supabase remains the source of truth, so the two systems can never conflict on which one is authoritative; this also keeps a future CRM swap (Pipedrive, etc.) isolated to the delivery layer alone. Authentication uses a HubSpot **Service Key** (the modern, non-legacy credential for system-to-system access) rather than a private app, wired into n8n's HubSpot node via its "App Token"/Service Key auth option.

A new or updated lead becomes (or updates) a HubSpot contact with standard fields (`firstname`, `lastname`, `company`) plus a custom `lead_source` property (HubSpot's own contact-properties picker doesn't surface custom properties, so `lead_source` is set via a direct `PATCH /crm/v3/objects/contacts/{id}` call rather than the picker). A custom `icp_score` number property also exists on the HubSpot side, reserved for the scoring layer. Once scoring lands, a scored lead's HubSpot contact is meant to also receive a note containing the generated draft email, and a score at or above the `hot` threshold triggers an instant alert — in addition to the standing rule that every pipeline error, anywhere, alerts unconditionally (no silent failures).

**Dedupe design**: the same email or domain resubmitting within 30 days is treated as an update to the existing lead row, not a new insert — this prevents a returning lead (a second form fill, a duplicate upload) from doubling Claude cost, spamming HubSpot with duplicate contacts, or corrupting dashboard volume metrics. The 30-day window is chosen so a lead returning after roughly a month is treated as a plausibly new buying event worth a fresh enrichment pass (new news, possibly a new tech stack), rather than silently merged into stale data. Edge case: the same email under a different domain (e.g. a contact changed jobs) is treated as an entirely new lead, since domain is the enrichment key, not email.

## ICP scoring schema

The Ideal Customer Profile is data, not prompt text — a per-tenant JSON config (selected via env var, so onboarding a new client is a config file, not a code change) that gets injected into a fixed prompt template. Its shape:

- **`scoring_dimensions[]`** — a rubric of weighted dimensions (e.g. industry fit, company size, buying signals, tech maturity, message intent), each with a weight and a description of what "ideal" looks like on that axis. **Weights must sum to 100.**
- **`hard_disqualifiers[]`** — conditions (competitor, student/job-seeker inquiry, personal email with no discoverable company) that cap the score at 10 regardless of dimension scores — a cap rather than a hard zero, so relative ordering survives inside the reject bucket for later auditing, while still guaranteeing no alert ever fires on a disqualified lead.
- **`thresholds`** — `hot` (instant alert), `review` (normal CRM entry), `nurture` (below this, log-only). The draft email is always generated in the same structured call as the score (the model doesn't know the score until after it drafts) — below `nurture`, the pipeline discards the generated draft rather than delivering or storing it, so the token cost is paid but the downstream waste (a delivered email nobody acts on) is not. Gating generation itself would need a second call and was rejected for breaking the one-structured-call design.
- **`email_rules`** — word cap, required references (must cite a specific enrichment fact), forbidden moves (pricing, fake urgency, claiming familiarity that wasn't established), and a fixed low-pressure CTA shape.
- **`company_identity`** — the sending identity (name, sender, one-line value proposition, tone) injected into drafts, so identity is also swappable per tenant.

**Scoring is a deterministic aggregation, not a model-reported total**: the model scores each dimension (0–100) and gives per-dimension reasoning; the pipeline itself computes `icp_score = Σ(dimension_score × weight) / 100` and applies disqualifier caps in code. This exists because LLMs are unreliable at both arithmetic and self-consistent holistic scoring — per-dimension scoring plus deterministic aggregation is reproducible and directly debuggable ("why did this lead score 62?" has an exact, inspectable answer). Every scored lead also logs the `config_version` of the ICP that produced its score, since a score is only meaningful relative to the rubric that generated it — ICP configs will change over time, and historical scores need to stay interpretable against the rubric they were actually scored under.
