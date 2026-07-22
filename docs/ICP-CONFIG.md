# ICP-CONFIG.md — Ideal Customer Profile as Configuration

The ICP is **data, not prompt text**. The intelligence layer loads a JSON config, injects it into a fixed prompt template, and scores against it. Phase 2 onboarding = write a new config file. Zero code changes.

## Design rules
1. **One config per tenant.** File name = tenant id (`config/icp.default.json`, `config/icp.acme.json`). Lives in the same `config/` directory bind-mounted into n8n by #21 (`CONFIG_DIR:/config:ro`) — no separate `configs/` directory. Active tenant selected by env var `ICP_CONFIG` — multi-tenant-ready from day one.
2. **Everything the model needs to judge a lead lives here** — nothing about the ICP is hardcoded in the prompt template.
3. **Weights must sum to 100.** The scoring dimensions ARE the rubric; the model scores each dimension, we (not the model) compute the weighted total. Why: LLMs are unreliable at arithmetic and at self-consistent holistic scores; per-dimension scoring + deterministic aggregation is reproducible and debuggable ("why 62?" → look at the dimension breakdown).
4. **Config is validated on load** (JSON schema): weights sum, required fields, threshold sanity. A bad config fails loudly at startup, never mid-lead.
5. **Versioned.** `config_version` is logged with every scored lead so historical scores are interpretable after ICP changes.

## Schema

```jsonc
{
  "config_version": "1.0.0-v1",         // -v1 suffix marks unvalidated placeholder values, see DECISIONS.md
  "tenant": "flowsignal",

  "company_identity": {
    "name": "FlowSignal",               // used in draft emails
    "sender_name": "Wop",
    "value_proposition": "Automated lead enrichment, scoring, and CRM delivery for B2B teams drowning in manual lead ops — set up in days, not quarters.",
    "tone": "direct, warm, no corporate filler, no exclamation marks"
  },

  "icp_description": "FlowSignal sells to B2B companies (Series A–B or bootstrapped-profitable, 20–200 employees) that have real inbound lead volume but no dedicated RevOps function. The best-fit buyer is visibly straining under manual lead handling — hiring their first ops/SDR roles, recently funded, or growing headcount fast — and already uses a CRM or basic tooling, so they understand the category. Companies over 1000 employees are out of scope: they build in-house or buy enterprise.",

  "scoring_dimensions": [
    {
      "key": "company_fit",
      "weight": 30,
      "ideal": "B2B; Series A–B or bootstrapped-profitable; 20–200 employees",
      "notes": "The 'can they actually buy' gate. Misfit here poisons downstream signals. ≤200 is a deliberate SMB/lower-mid scope, not a soft preference."
    },
    {
      "key": "pain_signals",
      "weight": 30,
      "ideal": "Hiring SDR/ops/RevOps roles; 'drowning in leads' or manual-process language; recent funding (scaling pain); fast headcount growth",
      "notes": "Top differentiator among fitting companies. Equal weight to company_fit is a v1 hypothesis — revisit after #30's human spot-check."
    },
    {
      "key": "buying_intent",
      "weight": 20,
      "ideal": "Inbound message states a concrete problem and/or timeline; specificity beats vague curiosity"
    },
    {
      "key": "tech_maturity",
      "weight": 15,
      "ideal": "Already runs a CRM or marketing/sales tooling — shorter sales cycle, understands the category",
      "notes": "Fed directly by enrichment tech_stack detection."
    },
    {
      "key": "market_timing",
      "weight": 5,
      "ideal": "Funding round <6 months old or a recent product launch",
      "notes": "News-sourced; low weight because news is the weakest-evidence enrichment component (collision noise)."
    }
  ],

  "hard_disqualifiers": [
    "personal email with no discoverable company",
    "student or job-seeker inquiry",
    "obvious competitor",
    "company larger than 1000 employees"
  ],
  // Hard disqualifier hit → score capped at 10 regardless of dimensions.
  // Why a cap and not zero: preserves relative ordering inside the reject
  // bucket for auditing, while guaranteeing no alert fires.

  "thresholds": {
    "hot": 72,        // instant alert
    "review": 48,     // normal CRM entry
    "nurture": 25     // below this: log-only — draft is generated but discarded, not delivered/stored (see DECISIONS.md 2026-07-22)
  },

  "email_rules": {
    "max_words": 120,
    "must_reference": ["one specific fact from enrichment"],
    "never": ["pricing", "fake urgency", "claiming familiarity we don't have"],
    "cta": "suggest a low-pressure 15-minute call",
    "tone": "direct, warm, no corporate filler"
  }
}
```

The values above are the actual v1 `config/icp.default.json` content (tenant `flowsignal`), not a hypothetical example — see DECISIONS.md for why they're marked placeholder/unvalidated.

## How it flows into the prompt
The prompt template has slots: `{{icp_description}}`, `{{scoring_dimensions}}`, `{{hard_disqualifiers}}`, `{{email_rules}}`, `{{company_identity}}`. The model returns per-dimension scores (0–100 each) + reasoning; the pipeline computes `icp_score = Σ(dimension_score × weight) / 100`, applies disqualifier caps, then compares against `thresholds`.

## Interview-worthy points
- **Deterministic aggregation over model-reported totals** (rule 3) — reproducibility and debuggability.
- **`nurture` threshold gates draft delivery/storage, not generation** — the single structured call always drafts (the model itself nulls the draft only on disqualification); code discards the draft below this threshold rather than persisting or delivering it. Generating only for scores ≥ threshold would require knowing the score before drafting, which needs a second call — see docs/DECISIONS.md 2026-07-22 for why that breaks the one-structured-call architecture.
- **Config versioning per scored lead** — scores are only meaningful relative to the rubric that produced them.
