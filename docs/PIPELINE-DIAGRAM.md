# Pipeline diagram

Full flow, form submission to CRM delivery, including every dead-letter and alert branch. Rendered from the actual n8n workflows (`lead-intake.json`, `enrichment-orchestrator.json`, `intelligence-scorer.json`) and `config/icp.default.json` as of Sprint 6 — not the original architecture sketch, the as-built pipeline.

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

Red borders are dead-letter/alert paths — every one of them pages Wop, never fails silently. Green is the one success-path alert (a hot lead), deliberately not wired through the error-workflow mechanism, since a hot lead isn't a failure.

## Two corrections to the original design

- **Enrichment is sequential, not parallel.** `docs/ARCHITECTURE.md`'s original sketch called for the website/tech-stack/news trio to run in parallel. #23 shipped them sequential (Website Scraper → Tech Stack Detector → News Scanner) — that's what's actually running, so that's what's diagrammed.
- **The hot-tier threshold is 72, not 75.** `docs/ARCHITECTURE.md`'s original target was "score ≥75". The shipped config (`config/icp.default.json`, `thresholds.hot`) is 72, as of `config_version 1.3.0-v1`. The diagram's "Tier = hot?" gate reflects the real threshold.
