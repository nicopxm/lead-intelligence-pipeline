# Lead Intelligence Pipeline

Lead Intelligence Pipeline turns a form submission into a scored, drafted, CRM-ready lead in about 34 seconds, for under two cents. It enriches the lead (website, tech stack, recent news), scores it against a configurable ideal-customer profile, drafts a personalized outreach email, and writes it to HubSpot with a hot-lead alert if it clears the bar — no human touches any of it. I built this as a portfolio project for GTM/RevOps engineering roles, but it's built to run a real one: swap in a new ICP config file and it scores a different business, no code changes.

## Architecture

Here's the full pipeline, every stage and every dead-letter branch, as it actually runs today:

```mermaid
flowchart TD
    A["Lead form submission"] --> B["Lead Intake webhook"]
    B --> C{"Payload valid?"}
    C -- "no" --> C1["400 response, no lead created"]
    C -- "yes" --> D["Dedupe check: domain, then email fallback"]
    D --> E["Supabase: insert or update lead"]
    E -- "insert fails" --> E1["Alert: intake failure"]

    subgraph ENRICH["Enrichment Orchestrator (sequential)"]
        direction TB
        H["Website Scraper: home, about, pricing"] --> H2["Tech Stack Detector"]
        H2 --> H3["News Scanner"]
    end

    E -. "fire-and-forget" .-> H
    E --> F["HubSpot: create or update contact"]
    F --> G["Respond 200 OK to form"]

    H3 --> I{"At least one step ok or partial?"}
    I -- "all skipped, no domain/company" --> I1["Stays raw, no alert"]
    I -- "all failed" --> I2["Alert: enrichment failed"]
    I -- "yes" --> J["Supabase: mark enriched"]

    J --> K["Intelligence Scorer"]
    CFG[("config/icp.default.json")] -.-> L
    K --> L["ICP Config Loader"]
    L -- "invalid config" --> L1["Alert: config invalid"]
    L --> M{"Company on competitor list?"}
    M -- "yes" --> M1["Disqualify, tier = discard, no Claude call"]
    M -- "no" --> N["Claude Haiku: score, evidence, draft email"]
    N --> O{"Response matches schema?"}
    O -- "no, attempt 1" --> N2["Claude Haiku: retry, attempt 2"]
    N2 --> O2{"Response matches schema?"}
    O2 -- "no" --> P1["Dead-letter: status = error, alert"]
    O -- "yes" --> P["Compute score, tier, disqualifier cap"]
    O2 -- "yes" --> P
    M1 --> P

    P --> Q["Supabase: mark scored"]
    Q --> R["HubSpot: set icp_score and company_summary"]
    R -- "write fails" --> R1["Dead-letter: delivery failed, alert, status stays scored"]
    R --> S{"Tier drafted an email?"}
    S -- "yes" --> S1["HubSpot: create note with draft"]
    S -- "no" --> T
    S1 --> T["Supabase: mark delivered"]

    T --> U{"Tier = hot?"}
    U -- "yes" --> V["Resend: hot-lead alert to Wop"]
    V -- "send fails" --> V1["Alert: hot alert failed, status stays delivered"]
    U -- "no" --> W["Done"]

    classDef alert stroke:#d03b3b,stroke-width:3px;
    classDef success stroke:#0ca30c,stroke-width:3px;
    class E1,I2,L1,P1,R1,V1 alert;
    class V success;
```

Red borders are dead-letter and alert paths — every one pages me, none fail silently. Green is the one success-path alert, a hot lead, deliberately not wired through error handling since a hot lead isn't a failure.

## How it works

A lead starts at a Next.js form, or any webhook that can POST the same shape. n8n picks it up, checks Supabase for a duplicate by domain, falling back to email, and writes the row — a new insert or an update, never a duplicate. The form gets its 200 back in a few seconds regardless of what happens next; enrichment kicks off in the background and never blocks the response.

From there, an n8n sub-workflow scrapes the company's homepage, about, and pricing pages, fingerprints their tech stack from what's on those pages, and pulls the last 90 days of news by company name. Real websites fail constantly, timeouts, JS-only pages, robots.txt blocks, so each step reports its own status instead of taking the whole lead down with it.

Once enrichment settles, the lead goes to the Intelligence Scorer: one call to Claude Haiku, given the lead's message plus everything enrichment found, comes back with a score across five weighted dimensions, evidence for each one, buying signals, objection risks, and a draft outreach email. Code, not the model, does the weighted math, applies a disqualifier cap if the lead trips one, and assigns a tier.

From there it's a write to HubSpot: score and a company summary land on the contact, the draft email attaches as a note if the lead cleared the discard tier, and a hot lead fires a Resend alert on top of the normal delivery. Every failure point along the way, a bad payload, an enrichment wipeout, a malformed model response, a failed HubSpot write, dead-letters the lead and sends a Resend alert instead of failing silently.

The ICP itself lives in a JSON config file, not in code: scoring dimensions, weights, thresholds, disqualifiers, even the sender's name and tone. Onboarding a second client means writing a new config file, not touching the pipeline.
