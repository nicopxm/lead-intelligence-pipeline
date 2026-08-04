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

## ICP scoring

Five dimensions, weighted:

| Dimension | Weight | Grounded in |
|---|---|---|
| Company fit | 30 | Company size, B2B software/tech category |
| Pain signals | 30 | The lead's own message: hiring signals, manual-process language, recent funding |
| Buying intent | 20 | The message only, never enrichment |
| Tech maturity | 15 | Detected tech stack, not a claimed one |
| Market timing | 5 | Recent news, the weakest evidence, weighted accordingly |

Four hard disqualifiers sit on top of the weighted score, not inside it: a personal email with no discoverable company, a student or job-seeker inquiry, a direct competitor, and headcount over 1,000. Three of those are model judgment against a strict written definition, checked at score time. The fourth isn't. Competitor status is a checked list in code: Attio, Clearbit, Apollo, Clay, HubSpot, Outreach, Salesloft. I ran a controlled experiment and found the model can't be trusted with that call — real, recognizable brand names got disqualified as competitors 60% of the time, and the same lead with the name scrubbed out dropped to 17%. That's a name-recognition bias firing before the model reads the definition, not a wording problem, and no amount of prompt tuning reaches it. A short list in config does.

The other design call worth explaining: the model drafts an email for every lead, even ones that end up disqualified or scored too low to send. Code decides after scoring whether that draft ships. I could have told the model to skip drafting for bad leads and saved a few hundred tokens a call. I didn't, because that couples two separate decisions, should I write to this lead and is this lead worth talking to, and coupling them meant an earlier prompt version silently threw away leads that a wrongly-tripped disqualifier had misjudged. Split the two, and fixing the disqualifier recovers those leads for free, with zero change to how drafting works.

## Cost model

A lead costs $0.0141 to $0.0170 to score under the current prompt, comfortably under the $0.02 target I set at the start. That's one Claude Haiku call per lead; a second attempt only fires if the first response fails schema validation, which is rare.

That range isn't open-ended by luck. Enrichment input is capped at 4,000 characters per scraped page, three pages max, and news is capped at the 5 most recent items. However verbose or sparse a target site is, the prompt has a hard ceiling: cost tracks enrichment richness, not model verbosity.

The prompt went through a rewrite mid-project (v1 → v2) to fix a grounding bug: the model was asserting facts, like headcounts, that weren't anywhere in the actual lead data. Grounding every score in evidence and requiring a source quote for size claims raised cost 1.37x on the same five test leads, almost entirely in output tokens, since v2 also drafts for leads v1 used to silently discard before ever scoring them. Still well under budget. Full per-lead numbers and methodology in [docs/COST-ANALYSIS.md](docs/COST-ANALYSIS.md).

Cost isn't the whole story. The same pipeline that scores a lead for under two cents also gets it from form submit to a live HubSpot contact in about 34 seconds, well inside the 90-second target.

## Key decisions and tradeoffs

**Claude Haiku over Sonnet.** One structured call per lead, every time, so cost had to be predictable at volume. Haiku scores the same five dimensions under the same grounding rules for a fraction of Sonnet's price, and lead scoring doesn't need frontier reasoning, it needs consistent extraction against a fixed rubric. Predictable latency mattered too: a 34-second budget doesn't have room for a model that occasionally thinks longer.

**n8n over Zapier or Make.** Priced per workflow execution, not per task, which matters at any real lead volume. It also meant building and debugging real orchestration logic, sub-workflows, retries, dead-letter branches, fire-and-forget execution, instead of chaining prebuilt steps. That's closer to what a RevOps engineering role actually looks like day to day.

**Config-as-data, not code.** The entire ICP, scoring dimensions, weights, thresholds, disqualifiers, sender identity, lives in one JSON file, validated on load and never silently defaulted. Onboarding a second client is writing a new config, not touching the scoring logic itself. Routine tuning, a weight, a threshold, a new disqualifier reason, is a JSON edit and nothing else. It's a bet made before there's a second client to prove it against; the weights themselves are still an unvalidated v1 hypothesis, since the human spot-check meant to tune them against real outcomes got deferred and never actually completed.

**The competitor name-prior experiment.** Covered above under ICP scoring, but it's worth calling out as a decision on its own: when a bug looks like a prompt problem, the fix isn't always a better prompt. I ran a controlled experiment, real name against a scrubbed one, before writing a single line of new prompt, because guessing at the mechanism would have meant iterating on wording that could never fix it.

**Dead-letter without reverting status.** A delivery failure after a lead is already scored doesn't roll the lead back to a redo state. It dead-letters delivery specifically, alerts, and leaves the trustworthy score in place, because a scoring failure and a delivery failure mean different things: one says redo the Claude call, the other says the data was fine, just retry the write. Conflating them would make a HubSpot outage look like a broken score.
