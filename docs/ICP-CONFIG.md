# ICP-CONFIG.md — Ideal Customer Profile as Configuration

The ICP is **data, not prompt text**. The intelligence layer loads a JSON config, injects it into a fixed prompt template, and scores against it. Phase 2 onboarding = write a new config file. Zero code changes.

## Design rules
1. **One config per tenant.** File name = tenant id (`configs/icp.default.json`, `configs/icp.acme.json`). Active tenant selected by env var `ICP_CONFIG` — multi-tenant-ready from day one.
2. **Everything the model needs to judge a lead lives here** — nothing about the ICP is hardcoded in the prompt template.
3. **Weights must sum to 100.** The scoring dimensions ARE the rubric; the model scores each dimension, we (not the model) compute the weighted total. Why: LLMs are unreliable at arithmetic and at self-consistent holistic scores; per-dimension scoring + deterministic aggregation is reproducible and debuggable ("why 62?" → look at the dimension breakdown).
4. **Config is validated on load** (JSON schema): weights sum, required fields, threshold sanity. A bad config fails loudly at startup, never mid-lead.
5. **Versioned.** `config_version` is logged with every scored lead so historical scores are interpretable after ICP changes.

## Schema

```jsonc
{
  "config_version": "1.0.0",
  "tenant": "default",

  "company_identity": {
    "name": "Wop Consulting",            // used in draft emails
    "sender_name": "Wop",
    "value_proposition": "One-sentence pitch injected into email drafts",
    "tone": "direct, warm, no corporate filler, no exclamation marks"
  },

  "icp_description": "2–4 sentence prose description of the ideal customer. This anchors the model's overall judgment.",

  "scoring_dimensions": [
    {
      "key": "industry_fit",
      "weight": 25,
      "ideal": "B2B SaaS, agencies, professional services",
      "disqualifiers": ["adult", "gambling", "crypto-speculation"]
    },
    {
      "key": "company_size",
      "weight": 20,
      "ideal": "5–100 employees; big enough to have lead flow, small enough to lack RevOps"
    },
    {
      "key": "buying_signals",
      "weight": 25,
      "ideal": "hiring sales/marketing roles, recent funding, launched new product, visible manual lead handling"
    },
    {
      "key": "tech_maturity",
      "weight": 15,
      "ideal": "already uses a CRM or marketing tooling; comfortable with SaaS"
    },
    {
      "key": "message_intent",
      "weight": 15,
      "ideal": "inbound message expresses a concrete problem or timeline, not tire-kicking"
    }
  ],

  "hard_disqualifiers": [
    "personal email + no discoverable company",
    "competitor",
    "student/job-seeker inquiry"
  ],
  // Hard disqualifier hit → score capped at 10 regardless of dimensions.
  // Why a cap and not zero: preserves relative ordering inside the reject
  // bucket for auditing, while guaranteeing no alert fires.

  "thresholds": {
    "hot": 75,        // instant alert
    "review": 50,     // normal CRM entry
    "nurture": 25     // below this: log-only, no draft email (saves tokens)
  },

  "email_rules": {
    "max_words": 120,
    "must_reference": ["one specific fact from enrichment"],
    "never": ["pricing", "fake urgency", "claiming familiarity we don't have"],
    "cta": "suggest a 15-minute call, low pressure"
  }
}
```

## How it flows into the prompt
The prompt template has slots: `{{icp_description}}`, `{{scoring_dimensions}}`, `{{hard_disqualifiers}}`, `{{email_rules}}`, `{{company_identity}}`. The model returns per-dimension scores (0–100 each) + reasoning; the pipeline computes `icp_score = Σ(dimension_score × weight) / 100`, applies disqualifier caps, then compares against `thresholds`.

## Interview-worthy points
- **Deterministic aggregation over model-reported totals** (rule 3) — reproducibility and debuggability.
- **`nurture` threshold gates email drafting** — direct cost lever; don't spend output tokens on leads nobody will contact.
- **Config versioning per scored lead** — scores are only meaningful relative to the rubric that produced them.
