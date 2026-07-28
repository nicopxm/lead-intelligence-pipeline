# Spec — #38 Ground the Scorer (closes #35, #36)

Design decisions are settled here. Claude Code implements against this document; it should not invent prompt wording or disqualifier definitions.

Base is Suggestion 2, with four things ported from Suggestion 1 (output ordering, XML fencing, the `<lead>` wrapper, unconditional drafting) and four corrections neither suggestion had.

Deploy order: **config → config validation → prompt → post-model validation → Compute Score**.

---

## 0. What changed and why

| Change | Fixes | Source |
|---|---|---|
| Data fence ("training knowledge is forbidden") | #36 invented headcounts, funding, investors | S2 |
| `<lead>` wrapper binding enrichment + message as one entity | #36 Humaans two-entity split | S1 structure, S2 wording |
| Evidence + reasoning generated **before** scores; disqualification verdict **last** | #35 verdict-first pattern-matching | S1 |
| `hard_disqualifiers` → `{id, label, definition}` objects | #35 undefined boundaries | S2 |
| `disqualifier_id` constrained to configured ids by **code**, not prompt | #35 32% off-config reasons | S2 |
| `icp_description` states B2B SaaS/tech scope **explicitly** | #35 "not B2B SaaS" invented | **neither — new** |
| Ideals explicitly marked non-gating | #35 "200-person ceiling" leak | both |
| Size disqualifier requires a headcount **in the data** | world-knowledge disqualification | **neither — new** |
| Unconditional drafting; model never nulls the draft | policy belongs in code | S1 |
| `config_version` keeps the `-v1` suffix | values still unvalidated pending #39 | **neither — new** |

---

## 1. `config/icp.default.json` (v2)

```json
{
  "config_version": "1.1.0-v1",
  "tenant": "flowsignal",

  "company_identity": {
    "name": "FlowSignal",
    "sender_name": "Wop",
    "value_proposition": "Automated lead enrichment, scoring, and CRM delivery for B2B teams drowning in manual lead ops — set up in days, not quarters.",
    "tone": "direct, warm, no corporate filler, no exclamation marks"
  },

  "icp_description": "FlowSignal sells to B2B software and technology companies (Series A–B or bootstrapped-profitable, 20–200 employees) that have real inbound lead volume but no dedicated RevOps function. The best-fit buyer is visibly straining under manual lead handling — hiring their first ops/SDR roles, recently funded, or growing headcount fast — and already uses a CRM or basic tooling, so they understand the category. SCOPE IS A SCORING SIGNAL, NOT A GATE: non-tech B2B (manufacturing, construction, professional services, logistics, staffing, retail) falls outside the ideal profile and should score low on company_fit, but is never disqualified for it. The 20–200 employee range is the ideal scoring target; the only hard size gate is the >1000 employee disqualifier.",

  "scoring_dimensions": [
    {
      "key": "company_fit",
      "weight": 30,
      "ideal": "B2B software/technology company; Series A–B or bootstrapped-profitable; 20–200 employees",
      "notes": "The 'can they actually buy' signal. Score proportionally: a 250-person B2B SaaS company is slightly off-ideal; a 900-person one is far off-ideal; a non-tech B2B company is far off-ideal. NEITHER the size range NOR the tech/SaaS focus is a disqualifier — the only hard size gate is >1000 employees, in hard_disqualifiers. If no size appears in the supplied data, say so and score conservatively rather than guessing."
    },
    {
      "key": "pain_signals",
      "weight": 30,
      "ideal": "Hiring SDR/ops/RevOps roles; 'drowning in leads' or manual-process language; recent funding (scaling pain); fast headcount growth",
      "notes": "Top differentiator among fitting companies. Ground primarily in the inbound message. Equal weight to company_fit is a v1 hypothesis — revisit after the human spot-check (#39)."
    },
    {
      "key": "buying_intent",
      "weight": 20,
      "ideal": "Inbound message states a concrete problem and/or timeline; specificity beats vague curiosity",
      "notes": "Ground exclusively in the inbound message text. Do not infer intent from enrichment."
    },
    {
      "key": "tech_maturity",
      "weight": 15,
      "ideal": "Already runs a CRM or marketing/sales tooling — shorter sales cycle, understands the category",
      "notes": "Base primarily on enrichment tech_stack detection. A tool the lead only claims, which enrichment did not detect, is WEAK evidence — score it below a detected tool. If tech_stack is missing, failed, or skipped entirely, score ≤30."
    },
    {
      "key": "market_timing",
      "weight": 5,
      "ideal": "Funding round <6 months old or a recent product launch",
      "notes": "News-sourced and lowest weight because news is the weakest-evidence enrichment component: the query is by company name only, so an unrelated same-named company's articles can appear. Treat news as suggestive, never verified. If news is missing, empty, or ambiguous, score ≤20."
    }
  ],

  "hard_disqualifiers": [
    {
      "id": "personal_email_no_company",
      "label": "Personal email with no discoverable company",
      "definition": "The lead used a free-mail address (gmail, outlook, yahoo, icloud, etc.) AND no company entity can be identified anywhere in the supplied data — no company name in the message, no enrichment. If a company is identifiable by any means, this does not apply."
    },
    {
      "id": "student_or_job_seeker",
      "label": "Student or job-seeker inquiry",
      "definition": "The message explicitly seeks employment, an internship, or academic/research assistance rather than describing a business problem to solve."
    },
    {
      "id": "obvious_competitor",
      "label": "Direct competitor",
      "definition": "The company's primary product is lead enrichment, lead scoring, lead routing, RevOps automation, or CRM delivery/sequencing — the same category FlowSignal sells into. BEING A B2B SAAS OR TECHNOLOGY COMPANY IS NOT SUFFICIENT. Productivity tools, developer tools, design tools, CMS platforms, email clients, photo/media tools, security tools, HR software, fintech, and vertical SaaS are NOT competitors."
    },
    {
      "id": "company_too_large",
      "label": "Company larger than 1000 employees",
      "definition": "The supplied data explicitly states an employee count greater than 1000. If no headcount appears anywhere in the supplied data, this NEVER applies — score company_fit conservatively instead. Do not infer headcount from a company's reputation, brand recognition, or industry."
    }
  ],

  "thresholds": {
    "hot": 72,
    "review": 48,
    "nurture": 25
  },

  "email_rules": {
    "max_words": 120,
    "must_reference": ["one specific fact from the supplied lead data"],
    "never": ["pricing", "fake urgency", "claiming familiarity we don't have"],
    "cta": "suggest a low-pressure 15-minute call",
    "tone": "direct, warm, no corporate filler"
  }
}
```

**Why `1.1.0-v1` and not `2.0.0`:** the `-v1` suffix marks *unvalidated placeholder values* (ICP-CONFIG.md), and the values are still unvalidated — #39's spot-check hasn't run. Dropping the suffix would falsely signal the weights are validated. There's a defensible argument for `2.0.0-v1` since the `hard_disqualifiers` shape change is breaking; either is fine, but **the `-v1` suffix must survive**.

---

## 2. `prompts/lead-scoring.v2.md`

Keep `lead-scoring.v1.md` in the repo unchanged for rollback.

````markdown
<!-- prompts/lead-scoring.v2.md -->
<!-- prompt_version: lead-scoring-v2 -->
<!-- Slots {{...}} are filled by Intelligence Scorer's "Render Prompt" Code node -->
<!-- from config/icp.default.json and the lead's Supabase row. -->

You are a lead qualification analyst for {{company_identity.name}}.

<rules>
1. DATA FENCE. Use ONLY facts that appear inside the <lead> block below. Any knowledge
   you have about this company from training data is forbidden — do not use it, do not
   reference it, do not let it influence a score. Never state headcount, funding,
   investors, geography, revenue, customer counts, or tech stack unless that exact fact
   appears in <lead>.

2. SINGLE ENTITY. The enrichment payload and the inbound message describe exactly ONE
   company. Never split them into two entities. If they conflict — for example a stated
   headcount that seems inconsistent with the website — note the conflict in your
   reasoning and score conservatively. Never resolve a conflict by inventing a second
   company or by preferring outside knowledge.

3. MISSING DATA IS NORMAL. Enrichment frequently fails or is skipped. When a field is
   missing, say "missing" in your reasoning and score that dimension conservatively.
   Missing data is never grounds for disqualification.

4. IDEALS ARE NOT GATES. The "ideal" and "notes" text on each scoring dimension guides
   scoring only. Nothing there can disqualify a lead. Only the <disqualifiers> block can
   set hits_disqualifier to true.

5. ALWAYS DRAFT. Write the draft email for every lead, including disqualified ones. The
   system decides whether it is delivered — you do not.

6. DIVISION OF LABOR. You judge and cite evidence. The system computes the weighted
   total, applies caps, and assigns tiers. Do not compute or state a total score.
</rules>

<business>
{{company_identity.name}}: {{company_identity.value_proposition}}
</business>

<icp>
{{icp_description}}
</icp>

<scoring_dimensions>
Score each dimension 0–100 independently. 0 means no evidence or a clear mismatch;
100 means a strong match to the ideal.

{{scoring_dimensions}}
</scoring_dimensions>

<disqualifiers>
Set hits_disqualifier to true ONLY when one of the definitions below is clearly met by
data present in <lead>.

You may emit ONLY one of the exact `id` values listed. Inventing any other reason is
forbidden. If a lead is a poor fit for a reason not listed here, score it low on the
relevant dimension instead — do not disqualify it.

{{hard_disqualifiers}}
</disqualifiers>

<lead>
Everything below describes one single company.

<enrichment>
{{lead_enrichment_json}}
</enrichment>

<message>
{{lead_message}}
</message>
</lead>

<email_rules>
- Maximum {{email_rules.max_words}} words
- Must reference at least one specific fact that appears in <lead>
- Never mention: {{email_rules.never}}
- Tone: {{email_rules.tone}}
- Call to action: {{email_rules.cta}}
- Signed by: {{company_identity.sender_name}}
</email_rules>

## Output

Return ONLY valid JSON. No markdown fences, no preamble, no trailing commentary.

Generate the keys in exactly the order shown. Evidence and reasoning precede every
score, and the disqualification verdict comes last — after you have worked through all
five dimensions. Do not decide disqualification before examining the evidence.

{
  "company_summary": "string",
  "buying_signals": ["string"],
  "objection_risks": ["string"],
  "dimensions": {
    "company_fit":   { "evidence": ["string"], "reasoning": "string", "score": 0 },
    "pain_signals":  { "evidence": ["string"], "reasoning": "string", "score": 0 },
    "buying_intent": { "evidence": ["string"], "reasoning": "string", "score": 0 },
    "tech_maturity": { "evidence": ["string"], "reasoning": "string", "score": 0 },
    "market_timing": { "evidence": ["string"], "reasoning": "string", "score": 0 }
  },
  "observed_headcount": {
    "value": 0,
    "source_quote": "string | null"
  },
  "disqualification": {
    "hits_disqualifier": false,
    "disqualifier_id": null,
    "reasoning": "string",
    "evidence": ["string"]
  },
  "fields_used": ["string"],
  "draft_email": "string"
}

Field rules:
- company_summary — 1–2 sentences built only from <lead>. If enrichment is empty,
  summarize the message alone and state that enrichment was unavailable.
- buying_signals / objection_risks — only items actually present in <lead>. Empty arrays
  are valid and preferred over speculation.
- evidence — every string must be a near-verbatim excerpt from <enrichment> or
  <message>. Never paraphrase into a claim the source does not make.
- observed_headcount — if an employee count appears anywhere in <lead>, put the number
  in value and the verbatim source excerpt in source_quote. If none appears, value 0 and
  source_quote null. Never fill this from outside knowledge — it is the receipt for any
  size-based disqualification.
- disqualifier_id — exactly one `id` from <disqualifiers>, or null. Never free text.
- reasoning inside disqualification — required whether or not a disqualifier hit.
- fields_used — the enrichment keys you actually referenced, plus the literal string
  "message" if you used the inbound message.
- draft_email — always a non-empty string, even when hits_disqualifier is true.
````

---

## 3. `Validate ICP Config` (config-load validation)

Change the `hard_disqualifiers` check from array-of-strings to array-of-objects, and add a required-dimension-keys check. Everything else in the node stays as-is.

```js
// hard_disqualifiers: array of { id, label, definition }
if (!Array.isArray(config.hard_disqualifiers) || config.hard_disqualifiers.length === 0) {
  errors.push('hard_disqualifiers must be a non-empty array');
} else {
  const seen = new Set();
  config.hard_disqualifiers.forEach((d, i) => {
    if (!d || typeof d !== 'object') {
      errors.push(`hard_disqualifiers[${i}] must be an object with id/label/definition`);
      return;
    }
    for (const k of ['id', 'label', 'definition']) {
      if (!d[k] || typeof d[k] !== 'string') {
        errors.push(`hard_disqualifiers[${i}] missing string field: ${k}`);
      }
    }
    if (d.id) {
      if (seen.has(d.id)) errors.push(`hard_disqualifiers duplicate id: ${d.id}`);
      seen.add(d.id);
    }
  });
}

// scoring_dimensions must contain exactly the five keys Compute Score expects
const requiredDims = ['company_fit', 'pain_signals', 'buying_intent', 'tech_maturity', 'market_timing'];
const presentDims = (config.scoring_dimensions || []).map(d => d && d.key).filter(Boolean);
for (const k of requiredDims) {
  if (!presentDims.includes(k)) errors.push(`scoring_dimensions missing required key: ${k}`);
}
```

Also add `tone` to the existing `email_rules` required-key list — it's currently unchecked.

**Do not add semantic-version parsing to `config_version`.** It is validated as a non-empty string only, as today. The `-v1` suffix (`1.1.0-v1`) is intentional — it marks unvalidated placeholder values pending #39 — and any semver parse or numeric comparison would trip on the alphanumeric suffix. Leave the existing string check as-is.

Failure behaviour is unchanged: `configOk: false` → `Fail Execution - ICP Config Invalid` → alert. Never a silent default.

---

## 4. New node — `Validate Model Output` (post-model)

Runs after schema validation, before `Compute Score`. **Failures route into the existing retry-once → dead-letter → alert path.** Do not create a new failure mode.

**Enforcing (hard-fail) in v2:**

1. `disqualifier_id` must be one of the configured ids when `hits_disqualifier` is true, and `null` when false. Exact string match — zero false-positive risk. *This is the mechanism that would have caught 32% of Sprint 3's disqualifications.*
2. `company_too_large` requires a headcount the model actually extracted from the supplied data. Do NOT regex the raw payload for a headcount — inbound phrasing varies too much ("team of 1500", "headcount is currently 1200", "~2,000 strong") and any keyword-adjacency pattern will miss legitimate cases, false-hard-failing a correctly-scored lead. Instead the model populates an `observed_headcount` field (see prompt schema), and the check is three exact conditions: when `hits_disqualifier` is `company_too_large`, require `observed_headcount.value > 1000` AND `observed_headcount.source_quote` is non-null AND that quote appears in `<lead>` as an **exact substring**. Exact substring, not token overlap — a headcount is a short factual string; if it isn't verbatim in the source, the model invented it, which is the #36 behaviour we're forbidding. This makes the check enforce the data fence rather than fight it.
3. `draft_email` must be a non-empty string regardless of disqualification status.

**Log-only (warn, do not fail) in v2:**

4. **Evidence provenance** — each `evidence[]` string should be traceable to the supplied data. Implement as token-overlap: normalise case/punctuation, take tokens of 4+ characters, require ≥60% to appear in the haystack. Write violations to the execution log and to `leads.intelligence.validation_warnings[]`.

Provenance is fuzzy matching and *will* produce false positives on legitimate paraphrase. Enforcing it on day one risks dead-lettering good leads — a worse failure than the one it prevents. Run it log-only through #39's batch, measure the false-positive rate, then promote it to enforcing in a follow-up issue. **File that follow-up during #38 so the promotion doesn't get forgotten.**

---

## 5. `Compute Score` changes

Three edits, all small:

```js
// was: parsed.disqualified / parsed.disqualifier_reason
const disqualified   = parsed.disqualification?.hits_disqualifier === true;
const disqualifierId = parsed.disqualification?.disqualifier_id ?? null;
```

Persist `disqualifier_id` (the configured enum) rather than free text, and keep `disqualification.reasoning` alongside it for auditability.

**Unconditional drafting needs no new code.** A disqualified lead is capped at 10, 10 is below the `nurture` threshold of 25, so `tier === 'discard'`, and the existing `draft_email: deliverDraft ? parsed.draft_email : null` already discards it. The change is purely removing the prompt instruction that made the *model* null the draft. Policy now lives in exactly one place.

Log `prompt_version: "lead-scoring-v2"` and `config_version: "1.1.0-v1"` per score, as today.

---

## 6. Acceptance / regression tests

Fixtures already exist as retained Supabase rows — resubmit the same payloads through the real webhook, don't re-invent them.

**Batch 1 — competitor boundary (#35's named fixture)**
- Raycast, Superhuman, Framer, Sanity, Photoroom → **not** disqualified as competitors
- Attio, Clearbit → **still** `obvious_competitor`

**Batch 3 — fabricated facts (#36)**
- Ignite Visibility scored against its stated ~120 employees, not an invented "700+"
- Frontline Source, Anders CPA, Behlen Country → no invented headcounts in reasoning; not disqualified on size
- **Aerotek and W.W. Grainger no longer hit `company_too_large`** (no headcount in the supplied data) but must still land in `discard` via low dimension scores. *This is the deliberate consequence of forbidding world-knowledge size inference — the outcome is preserved, the shortcut is removed.*

**Two-entity binding (#36 comment)**
- A lead using a real company's domain with a stated headcount that differs from the real company → scores on the stated figure; `company_summary` describes one company, never two

**Off-config reasons**
- The batch-2 leads that previously drew "insufficient lead data" and "low buying intent" → now either a configured `id` or no disqualification at all

**Unconditional drafting**
- A disqualified lead's raw model response contains a non-empty `draft_email`; the persisted record has it discarded by the tier gate

**Non-tech scoring, not gating**
- A non-tech B2B lead scores low on `company_fit` and is **not** disqualified

DoD per CLAUDE.md: merged, deployed, verified live through the real webhook (not editor tests), errors alert, workflow JSON exported and diffed, docs updated, `gh project item-list` board check last.

---

## 7. What this does NOT change

- One structured call per lead — unchanged
- Model judges / code does arithmetic and policy — unchanged, and now more strictly true
- Weighted aggregation, disqualifier cap at 10, tier thresholds — unchanged
- The five dimensions and their 30/30/20/15/5 weights — unchanged; the revisit waits on #39
- Retry-once → dead-letter → alert — unchanged, reused by the new validation node

---

## 8. DECISIONS.md entries owed

1. **Revises 2026-07-22 (draft-always / nurture gate).** The model no longer nulls `draft_email` on disqualification; drafting is unconditional and all discard policy lives in `Compute Score`. Rationale: nulling on disqualification was policy executed by the model, contradicting the model-judges/code-enforces division; and given the measured over-disqualification rate, a model-side null silently destroyed drafts for leads that shouldn't have been disqualified. Requires no new code — the existing tier gate already discards.
2. `hard_disqualifiers` restructured from bare strings to `{id, label, definition}`; `disqualifier_id` constrained to configured ids by post-model validation, not by prompt instruction alone.
3. `icp_description` states the B2B SaaS/tech scope explicitly per 2026-07-23, framed as a scoring signal rather than a gate — closing the inference gap that produced the invented "not B2B SaaS" disqualifier.
4. **Size disqualification requires a headcount present in the supplied data.** World-knowledge size inference is forbidden. Known consequence: large, recognisable companies now reach dimension scoring instead of the gate and land in `discard` by score. Verified by the Aerotek/Grainger regression cases.
5. Output key order changed so evidence and reasoning are generated before scores and the disqualification verdict comes last — the v1 schema put `disqualified` first, forcing a verdict before any reasoning existed.
6. Evidence-provenance validation ships log-only in v2 to measure its false-positive rate before enforcement; promotion tracked in a follow-up issue.
