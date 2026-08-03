# Intelligence Workflow (#29) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Intelligence Scorer n8n sub-workflow — one structured Claude API call per enriched lead, scoring it against the ICP config and drafting outreach, with code-side weighted aggregation, disqualifier capping, tier assignment, nurture-gated delivery, schema validation with one retry then dead-letter, and cost logging — then wire it into `Enrichment Orchestrator` so every lead goes `enriched → scored` automatically.

**Architecture:** A new sub-workflow (`Intelligence Scorer`) follows the exact composition pattern already used by `Website Scraper`/`Tech Stack Detector`/`News RSS`/`ICP Config Loader`: `Execute Workflow Trigger({id})` → `Supabase - Get Lead` → calls `ICP Config Loader` → renders the approved prompt template → calls the Claude Messages API via `HTTP Request` (no dedicated n8n Anthropic node exists) → validates the JSON response against the approved output schema → retries once on failure → dead-letters (`status=error` + alert) on a second failure → on success, CODE (not the model) computes the weighted score, applies the disqualifier cap, assigns a tier, and decides whether to keep/discard the draft (nurture gate) → writes `leads.intelligence` + `status='scored'`. `Enrichment Orchestrator` gets one new node calling this sub-workflow right after `Supabase - Mark Enriched`, with `onError: continueRegularOutput` (matching its three existing sub-workflow calls) so a scoring failure — already self-alerted — doesn't double-alert.

**Tech Stack:** n8n (self-hosted, Docker on Hetzner), Claude API (`claude-haiku-4-5`) via HTTP Request node + Header Auth credential, Supabase (existing `leads.intelligence` jsonb column — no migration needed), the already-built-but-unwired `ICP Config Loader` sub-workflow from #28.

## Global Constraints

- The prompt template is APPROVED — implement verbatim (see Task 1 for the exact text). Do not rephrase, restructure, or "improve" it.
- Model: `claude-haiku-4-5` (per DECISIONS.md; Sonnet-if-quality-fails fallback is #30's job, not this issue's).
- No Supabase migration: `leads.intelligence` (jsonb) and `lead_status` enum's `'scored'` value already exist from the #3 migration. `icp_score`, `tier`, `prompt_version`, `config_version`, `scored_at`, `input_tokens`, `output_tokens`, `cost_usd` all go **inside** the `intelligence` jsonb object, not new columns — matches the issue AC's literal wording and avoids an unrequested schema change.
- Nurture gate = **option A**, already reconciled in DECISIONS.md (2026-07-22 entries) and requires the ICP-CONFIG.md wording fix in Task 2: the model always drafts (unless it sets `disqualified: true`, which nulls the draft itself per the prompt's own instruction); CODE discards `draft_email` before persisting when the lead's final `tier` is `'discard'` (below `thresholds.nurture`). Never gate generation.
- Every sub-workflow call from `Enrichment Orchestrator` uses `onError: "continueRegularOutput"` + `alwaysOutputData: true` — apply the same to the new call (this is the established fix for the double-alert bug class from #23/#26, see docs/RUNBOOK.md's n8n operational notes).
- `ANTHROPIC_API_KEY` via n8n credentials + `.env.example` documentation only — never in workflow JSON, never echoed.
- Deploy path: CLI-only (scp/docker cp/import/publish/restart via the `lip` SSH alias), **git pull on the VPS clone FIRST**, every time — per the #28 drift finding elevated to a standing RUNBOOK rule.
- Definition of Done per CLAUDE.md: fresh `export:workflow` diffed against committed JSON for both touched workflows, RUNBOOK/DECISIONS updated, issue AC-reconciliation comment posted, `Closes #29`, pushed, board state verified via `gh project item-list`.

---

### Task 1: Prompt template file

**Files:**
- Create: `prompts/lead-scoring.v1.md`

**Interfaces:**
- Produces: a versioned prompt template consumed by Task 4's `Render Prompt` Code node, which does simple JS template-literal substitution (not a templating engine — no interface contract beyond "this is the literal text to embed with `${...}` slots filled by hand in the Code node").

- [ ] **Step 1: Write the approved template verbatim**

```markdown
<!-- prompts/lead-scoring.v1.md -->
<!-- prompt_version: lead-scoring-v1 — approved in architect chat 2026-07-22, see docs/DECISIONS.md -->
<!-- Slots ({{...}}) are filled by Intelligence Scorer's "Render Prompt" Code node from config/icp.default.json + the lead's Supabase row. This file is the source of truth for the template text; it is not read from disk at n8n runtime (embedded in the Code node — see Task 4). -->

You are a lead qualification analyst for {{company_identity.name}}. Score an inbound lead against the Ideal Customer Profile below, then draft a short outreach email if the lead qualifies.

## The business
{{company_identity.name}}: {{company_identity.value_proposition}}

## Ideal Customer Profile
{{icp_description}}

## Scoring dimensions
Score EACH dimension independently from 0 to 100, where 0 = no evidence or clear mismatch, 100 = ideal. For each, cite the SPECIFIC facts from the lead data you used. If the data is missing or sparse for a dimension, say so and score conservatively — never invent facts not present in the lead data.

{{scoring_dimensions}}

## Hard disqualifiers
If ANY of these is clearly true, set "disqualified": true and name which one. Do not soften or explain them away:
{{hard_disqualifiers}}

## The lead
Enrichment data (some fields may be missing — this is normal; score honestly on what exists):
{{lead_enrichment_json}}

Inbound message from the lead:
{{lead_message}}

## Email drafting
Only if the lead is not disqualified, draft an outreach email following these rules:
- Max {{email_rules.max_words}} words
- MUST reference at least one specific fact from the enrichment data
- NEVER mention: {{email_rules.never}}
- Tone: {{email_rules.tone}}
- Call to action: {{email_rules.cta}}
- From: {{company_identity.sender_name}}
If disqualified, set draft_email to null.

## Lead intelligence
Also surface, at the lead level (not per-dimension):
- buying_signals: concrete signals this lead may be ready to buy (funding, hiring, growth, explicit intent in their message)
- objection_risks: likely reasons this lead could stall or not convert (too early-stage, wrong fit on some axis, budget/timing concerns), each grounded in the lead data — do not speculate beyond what's present

## Output
Return ONLY valid JSON, no markdown, no preamble, matching this exact schema:
{
  "disqualified": boolean,
  "disqualifier_reason": string | null,
  "dimensions": {
    "company_fit":   { "score": 0-100, "reasoning": string, "evidence": [string] },
    "pain_signals":  { "score": 0-100, "reasoning": string, "evidence": [string] },
    "buying_intent": { "score": 0-100, "reasoning": string, "evidence": [string] },
    "tech_maturity": { "score": 0-100, "reasoning": string, "evidence": [string] },
    "market_timing": { "score": 0-100, "reasoning": string, "evidence": [string] }
  },
  "buying_signals": [string],
  "objection_risks": [string],
  "company_summary": string,
  "draft_email": string | null
}
```

- [ ] **Step 2: Commit**

```bash
git add prompts/lead-scoring.v1.md
git commit -m "docs(#29): add versioned lead-scoring prompt template"
```

---

### Task 2: ICP-CONFIG.md nurture-gate wording fix

**Files:**
- Modify: `docs/ICP-CONFIG.md`

**Interfaces:**
- Consumes: nothing (docs-only)
- Produces: nothing (docs-only) — but this is the canonical doc other future work reads, so it must not contradict the option-A design already recorded in DECISIONS.md (2026-07-22).

- [ ] **Step 1: Fix the inline threshold comment**

In the `thresholds` block of the schema example, change:

```jsonc
  "thresholds": {
    "hot": 72,        // instant alert
    "review": 48,     // normal CRM entry
    "nurture": 25     // below this: log-only, no draft email (saves tokens)
  },
```

to:

```jsonc
  "thresholds": {
    "hot": 72,        // instant alert
    "review": 48,     // normal CRM entry
    "nurture": 25     // below this: log-only — draft is generated but discarded, not delivered/stored (see DECISIONS.md 2026-07-22)
  },
```

- [ ] **Step 2: Fix the "Interview-worthy points" bullet**

Change:

```markdown
- **`nurture` threshold gates email drafting** — direct cost lever; don't spend output tokens on leads nobody will contact.
```

to:

```markdown
- **`nurture` threshold gates draft delivery/storage, not generation** — the single structured call always drafts (the model itself nulls the draft only on disqualification); code discards the draft below this threshold rather than persisting or delivering it. Generating only for scores ≥ threshold would require knowing the score before drafting, which needs a second call — see docs/DECISIONS.md 2026-07-22 for why that breaks the one-structured-call architecture.
```

- [ ] **Step 3: Commit**

```bash
git add docs/ICP-CONFIG.md
git commit -m "docs(#29): fix nurture-gate wording to match option-A (delivery gate, not generation gate)"
```

---

### Task 3: `.env.example` — document `ANTHROPIC_API_KEY`

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Append the new section**

Add after the `CONFIG_DIR` section at the end of the file:

```bash

# --- Anthropic Claude API (intelligence scoring), issue #29 ---
# ANTHROPIC_API_KEY= # Claude API key (Console → API Keys). Used only as an n8n Header Auth credential ("Anthropic API Key": header name x-api-key, value the raw key) for the Intelligence Scorer workflow. Model: claude-haiku-4-5 (see docs/DECISIONS.md; Sonnet fallback if #30's spot-check shows quality gaps). Server-side only (n8n credentials) — never committed, never in workflow JSON.
```

- [ ] **Step 2: Commit**

```bash
git add .env.example
git commit -m "docs(#29): document ANTHROPIC_API_KEY in .env.example"
```

---

### Task 4: Author `n8n/workflows/intelligence-scorer.json`

**Files:**
- Create: `n8n/workflows/intelligence-scorer.json`

**Interfaces:**
- Consumes: Execute Workflow Trigger input `{ id }` (a `leads.id` uuid) — same convention as every other sub-workflow.
- Consumes (sub-workflow call): `ICP Config Loader` (workflow id `iCPCfgLoader0001`), called with passthrough, returns `{ configOk, config, config_version }` on its true branch (see `n8n/workflows/icp-config-loader.json`).
- Produces: writes `leads.status = 'scored'` and `leads.intelligence` (jsonb: `{disqualified, disqualifier_reason, dimensions, buying_signals, objection_risks, company_summary, draft_email, icp_score, tier, prompt_version, config_version, scored_at, input_tokens, output_tokens, cost_usd}`) on success; on validation failure after one retry, writes `leads.status = 'error'` and fails the execution (fires `Lead Intake - Error Alert` via `settings.errorWorkflow`).
- Workflow id: `intelScorer0001a` (this is what Task 5 references from `Enrichment Orchestrator`).

- [ ] **Step 1: Write the full workflow JSON**

```json
{
  "name": "Intelligence Scorer",
  "nodes": [
    {
      "parameters": { "inputSource": "passthrough" },
      "id": "b2c3d4e5-0001-4bbb-8000-000000000001",
      "name": "When Executed by Another Workflow",
      "type": "n8n-nodes-base.executeWorkflowTrigger",
      "typeVersion": 1.1,
      "position": [-2000, 160]
    },
    {
      "parameters": {
        "operation": "get",
        "tableId": "leads",
        "filters": {
          "conditions": [
            { "keyName": "id", "keyValue": "={{ $json.id }}" }
          ]
        }
      },
      "id": "b2c3d4e5-0002-4bbb-8000-000000000002",
      "name": "Supabase - Get Lead",
      "type": "n8n-nodes-base.supabase",
      "typeVersion": 1,
      "position": [-1776, 160],
      "credentials": {
        "supabaseApi": { "id": "4pPsx2sAVgrzJm5n", "name": "Supabase Leads" }
      }
    },
    {
      "parameters": {
        "workflowId": {
          "__rl": true,
          "value": "iCPCfgLoader0001",
          "mode": "list",
          "cachedResultUrl": "/workflow/iCPCfgLoader0001",
          "cachedResultName": "ICP Config Loader"
        },
        "workflowInputs": {
          "mappingMode": "defineBelow",
          "value": {},
          "matchingColumns": [],
          "schema": [],
          "attemptToConvertTypes": false,
          "convertFieldsToString": true
        },
        "options": {}
      },
      "id": "b2c3d4e5-0003-4bbb-8000-000000000003",
      "name": "Execute Workflow - ICP Config Loader",
      "type": "n8n-nodes-base.executeWorkflow",
      "typeVersion": 1.2,
      "position": [-1552, 160]
    },
    {
      "parameters": {
        "jsCode": "const lead = $('Supabase - Get Lead').item.json;\nconst config = $('Execute Workflow - ICP Config Loader').item.json.config;\n\nconst dims = config.scoring_dimensions.map(d =>\n  `- ${d.key} (weight ${d.weight}): ideal = ${d.ideal}${d.notes ? `. Notes: ${d.notes}` : ''}`\n).join('\\n');\n\nconst disqualifiers = config.hard_disqualifiers.map(d => `- ${d}`).join('\\n');\n\nconst emailRules = `- Max words: ${config.email_rules.max_words}\\n- Must reference: ${config.email_rules.must_reference.join(', ')}\\n- Never mention: ${config.email_rules.never.join(', ')}\\n- CTA: ${config.email_rules.cta}\\n- Tone: ${config.email_rules.tone}`;\n\nconst leadEnrichmentJson = JSON.stringify(lead.enrichment || {}, null, 2);\nconst leadMessage = lead.message || '(no message provided)';\n\nconst systemPrompt = `You are a lead qualification analyst for ${config.company_identity.name}. Score an inbound lead against the Ideal Customer Profile below, then draft a short outreach email if the lead qualifies.\n\n## The business\n${config.company_identity.name}: ${config.company_identity.value_proposition}\n\n## Ideal Customer Profile\n${config.icp_description}\n\n## Scoring dimensions\nScore EACH dimension independently from 0 to 100, where 0 = no evidence or clear mismatch, 100 = ideal. For each, cite the SPECIFIC facts from the lead data you used. If the data is missing or sparse for a dimension, say so and score conservatively — never invent facts not present in the lead data.\n\n${dims}\n\n## Hard disqualifiers\nIf ANY of these is clearly true, set \"disqualified\": true and name which one. Do not soften or explain them away:\n${disqualifiers}\n\n## The lead\nEnrichment data (some fields may be missing — this is normal; score honestly on what exists):\n${leadEnrichmentJson}\n\nInbound message from the lead:\n${leadMessage}\n\n## Email drafting\nOnly if the lead is not disqualified, draft an outreach email following these rules:\n${emailRules}\n- From: ${config.company_identity.sender_name}\nIf disqualified, set draft_email to null.\n\n## Lead intelligence\nAlso surface, at the lead level (not per-dimension):\n- buying_signals: concrete signals this lead may be ready to buy (funding, hiring, growth, explicit intent in their message)\n- objection_risks: likely reasons this lead could stall or not convert (too early-stage, wrong fit on some axis, budget/timing concerns), each grounded in the lead data — do not speculate beyond what's present\n\n## Output\nReturn ONLY valid JSON, no markdown, no preamble, matching this exact schema:\n{\n  \"disqualified\": boolean,\n  \"disqualifier_reason\": string | null,\n  \"dimensions\": {\n    \"company_fit\":   { \"score\": 0-100, \"reasoning\": string, \"evidence\": [string] },\n    \"pain_signals\":  { \"score\": 0-100, \"reasoning\": string, \"evidence\": [string] },\n    \"buying_intent\": { \"score\": 0-100, \"reasoning\": string, \"evidence\": [string] },\n    \"tech_maturity\": { \"score\": 0-100, \"reasoning\": string, \"evidence\": [string] },\n    \"market_timing\": { \"score\": 0-100, \"reasoning\": string, \"evidence\": [string] }\n  },\n  \"buying_signals\": [string],\n  \"objection_risks\": [string],\n  \"company_summary\": string,\n  \"draft_email\": string | null\n}`;\n\nreturn [{ json: { leadId: lead.id, systemPrompt, configVersion: config.config_version, config } }];"
      },
      "id": "b2c3d4e5-0004-4bbb-8000-000000000004",
      "name": "Render Prompt",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [-1328, 160]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "https://api.anthropic.com/v1/messages",
        "authentication": "genericCredentialType",
        "genericAuthType": "httpHeaderAuth",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [
            { "name": "anthropic-version", "value": "2023-06-01" },
            { "name": "content-type", "value": "application/json" }
          ]
        },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify({ model: 'claude-haiku-4-5', max_tokens: 2048, system: $('Render Prompt').item.json.systemPrompt, messages: [{ role: 'user', content: 'Score this lead and return the JSON now.' }] }) }}",
        "options": {}
      },
      "id": "b2c3d4e5-0005-4bbb-8000-000000000005",
      "name": "Claude API Call (Attempt 1)",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [-1104, 160],
      "onError": "continueRegularOutput",
      "alwaysOutputData": true,
      "credentials": {
        "httpHeaderAuth": { "id": "PLACEHOLDER_ANTHROPIC_CRED_ID", "name": "Anthropic API Key" }
      }
    },
    {
      "parameters": {
        "jsCode": "const resp = $json;\nconst leadId = $('Render Prompt').item.json.leadId;\n\nif (resp.error) {\n  return [{ json: { valid: false, reason: `HTTP error: ${JSON.stringify(resp.error)}`, leadId } }];\n}\n\nconst block = (resp.content || [])[0];\nif (!block || typeof block.text !== 'string') {\n  return [{ json: { valid: false, reason: 'no text content block in response', leadId } }];\n}\n\nlet text = block.text.trim();\ntext = text.replace(/^```(json)?\\n?/, '').replace(/\\n?```$/, '');\n\nlet parsed;\ntry {\n  parsed = JSON.parse(text);\n} catch (e) {\n  return [{ json: { valid: false, reason: `JSON parse failed: ${e.message}`, leadId } }];\n}\n\nconst errors = [];\nif (typeof parsed.disqualified !== 'boolean') errors.push('disqualified must be boolean');\nif (parsed.disqualifier_reason !== null && typeof parsed.disqualifier_reason !== 'string') errors.push('disqualifier_reason must be string or null');\nconst dimKeys = ['company_fit', 'pain_signals', 'buying_intent', 'tech_maturity', 'market_timing'];\nif (!parsed.dimensions || typeof parsed.dimensions !== 'object') {\n  errors.push('dimensions missing');\n} else {\n  for (const key of dimKeys) {\n    const d = parsed.dimensions[key];\n    if (!d) { errors.push(`dimensions.${key} missing`); continue; }\n    if (typeof d.score !== 'number' || d.score < 0 || d.score > 100) errors.push(`dimensions.${key}.score must be 0-100`);\n    if (typeof d.reasoning !== 'string') errors.push(`dimensions.${key}.reasoning must be string`);\n    if (!Array.isArray(d.evidence)) errors.push(`dimensions.${key}.evidence must be array`);\n  }\n}\nif (!Array.isArray(parsed.buying_signals)) errors.push('buying_signals must be array');\nif (!Array.isArray(parsed.objection_risks)) errors.push('objection_risks must be array');\nif (typeof parsed.company_summary !== 'string') errors.push('company_summary must be string');\nif (parsed.draft_email !== null && typeof parsed.draft_email !== 'string') errors.push('draft_email must be string or null');\n\nif (errors.length > 0) {\n  return [{ json: { valid: false, reason: errors.join('; '), leadId } }];\n}\n\nconst usage = resp.usage || {};\nreturn [{\n  json: {\n    valid: true,\n    parsed,\n    leadId,\n    input_tokens: usage.input_tokens || 0,\n    output_tokens: usage.output_tokens || 0\n  }\n}];"
      },
      "id": "b2c3d4e5-0006-4bbb-8000-000000000006",
      "name": "Validate Response (Attempt 1)",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [-880, 160]
    },
    {
      "parameters": {
        "conditions": {
          "options": { "caseSensitive": true, "leftValue": "", "typeValidation": "strict", "version": 2 },
          "conditions": [
            {
              "id": "cond-attempt1-valid",
              "leftValue": "={{ $json.valid }}",
              "rightValue": true,
              "operator": { "type": "boolean", "operation": "true", "singleValue": true }
            }
          ],
          "combinator": "and"
        },
        "options": {}
      },
      "id": "b2c3d4e5-0007-4bbb-8000-000000000007",
      "name": "Attempt 1 Valid?",
      "type": "n8n-nodes-base.if",
      "typeVersion": 2.2,
      "position": [-656, 80]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "https://api.anthropic.com/v1/messages",
        "authentication": "genericCredentialType",
        "genericAuthType": "httpHeaderAuth",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [
            { "name": "anthropic-version", "value": "2023-06-01" },
            { "name": "content-type", "value": "application/json" }
          ]
        },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify({ model: 'claude-haiku-4-5', max_tokens: 2048, system: $('Render Prompt').item.json.systemPrompt, messages: [{ role: 'user', content: 'Score this lead and return the JSON now.' }] }) }}",
        "options": {}
      },
      "id": "b2c3d4e5-0008-4bbb-8000-000000000008",
      "name": "Claude API Call (Attempt 2)",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [-656, 320],
      "onError": "continueRegularOutput",
      "alwaysOutputData": true,
      "credentials": {
        "httpHeaderAuth": { "id": "PLACEHOLDER_ANTHROPIC_CRED_ID", "name": "Anthropic API Key" }
      }
    },
    {
      "parameters": {
        "jsCode": "const resp = $json;\nconst leadId = $('Render Prompt').item.json.leadId;\n\nif (resp.error) {\n  return [{ json: { valid: false, reason: `HTTP error: ${JSON.stringify(resp.error)}`, leadId } }];\n}\n\nconst block = (resp.content || [])[0];\nif (!block || typeof block.text !== 'string') {\n  return [{ json: { valid: false, reason: 'no text content block in response', leadId } }];\n}\n\nlet text = block.text.trim();\ntext = text.replace(/^```(json)?\\n?/, '').replace(/\\n?```$/, '');\n\nlet parsed;\ntry {\n  parsed = JSON.parse(text);\n} catch (e) {\n  return [{ json: { valid: false, reason: `JSON parse failed: ${e.message}`, leadId } }];\n}\n\nconst errors = [];\nif (typeof parsed.disqualified !== 'boolean') errors.push('disqualified must be boolean');\nif (parsed.disqualifier_reason !== null && typeof parsed.disqualifier_reason !== 'string') errors.push('disqualifier_reason must be string or null');\nconst dimKeys = ['company_fit', 'pain_signals', 'buying_intent', 'tech_maturity', 'market_timing'];\nif (!parsed.dimensions || typeof parsed.dimensions !== 'object') {\n  errors.push('dimensions missing');\n} else {\n  for (const key of dimKeys) {\n    const d = parsed.dimensions[key];\n    if (!d) { errors.push(`dimensions.${key} missing`); continue; }\n    if (typeof d.score !== 'number' || d.score < 0 || d.score > 100) errors.push(`dimensions.${key}.score must be 0-100`);\n    if (typeof d.reasoning !== 'string') errors.push(`dimensions.${key}.reasoning must be string`);\n    if (!Array.isArray(d.evidence)) errors.push(`dimensions.${key}.evidence must be array`);\n  }\n}\nif (!Array.isArray(parsed.buying_signals)) errors.push('buying_signals must be array');\nif (!Array.isArray(parsed.objection_risks)) errors.push('objection_risks must be array');\nif (typeof parsed.company_summary !== 'string') errors.push('company_summary must be string');\nif (parsed.draft_email !== null && typeof parsed.draft_email !== 'string') errors.push('draft_email must be string or null');\n\nif (errors.length > 0) {\n  return [{ json: { valid: false, reason: errors.join('; '), leadId } }];\n}\n\nconst usage = resp.usage || {};\nreturn [{\n  json: {\n    valid: true,\n    parsed,\n    leadId,\n    input_tokens: usage.input_tokens || 0,\n    output_tokens: usage.output_tokens || 0\n  }\n}];"
      },
      "id": "b2c3d4e5-0009-4bbb-8000-000000000009",
      "name": "Validate Response (Attempt 2)",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [-432, 320]
    },
    {
      "parameters": {
        "conditions": {
          "options": { "caseSensitive": true, "leftValue": "", "typeValidation": "strict", "version": 2 },
          "conditions": [
            {
              "id": "cond-attempt2-valid",
              "leftValue": "={{ $json.valid }}",
              "rightValue": true,
              "operator": { "type": "boolean", "operation": "true", "singleValue": true }
            }
          ],
          "combinator": "and"
        },
        "options": {}
      },
      "id": "b2c3d4e5-0010-4bbb-8000-000000000010",
      "name": "Attempt 2 Valid?",
      "type": "n8n-nodes-base.if",
      "typeVersion": 2.2,
      "position": [-208, 320]
    },
    {
      "parameters": {
        "jsCode": "const { parsed, leadId, input_tokens, output_tokens } = $json;\nconst config = $('Render Prompt').item.json.config;\n\nlet weightedTotal = 0;\nfor (const dim of config.scoring_dimensions) {\n  const score = (parsed.dimensions[dim.key] && parsed.dimensions[dim.key].score) || 0;\n  weightedTotal += (score * dim.weight) / 100;\n}\nweightedTotal = Math.round(weightedTotal);\n\nconst icpScore = parsed.disqualified ? Math.min(weightedTotal, 10) : weightedTotal;\n\nconst { hot, review, nurture } = config.thresholds;\nlet tier;\nif (icpScore >= hot) tier = 'hot';\nelse if (icpScore >= review) tier = 'review';\nelse if (icpScore >= nurture) tier = 'nurture';\nelse tier = 'discard';\n\nconst deliverDraft = tier !== 'discard';\n\n// Haiku 4.5 pricing as of 2026-07-22: $1.00/1M input tokens, $5.00/1M output tokens (docs/DECISIONS.md)\nconst costUsd = (input_tokens / 1e6) * 1.00 + (output_tokens / 1e6) * 5.00;\n\nconst intelligence = {\n  disqualified: parsed.disqualified,\n  disqualifier_reason: parsed.disqualifier_reason,\n  dimensions: parsed.dimensions,\n  buying_signals: parsed.buying_signals,\n  objection_risks: parsed.objection_risks,\n  company_summary: parsed.company_summary,\n  draft_email: deliverDraft ? parsed.draft_email : null,\n  icp_score: icpScore,\n  tier,\n  prompt_version: 'lead-scoring-v1',\n  config_version: config.config_version,\n  scored_at: new Date().toISOString(),\n  input_tokens,\n  output_tokens,\n  cost_usd: Math.round(costUsd * 1e6) / 1e6\n};\n\nreturn [{ json: { leadId, intelligence } }];"
      },
      "id": "b2c3d4e5-0011-4bbb-8000-000000000011",
      "name": "Compute Score",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [-432, 80]
    },
    {
      "parameters": {
        "operation": "update",
        "tableId": "leads",
        "filters": {
          "conditions": [
            { "keyName": "id", "condition": "eq", "keyValue": "={{ $json.leadId }}" }
          ]
        },
        "fieldsUi": {
          "fieldValues": [
            { "fieldId": "status", "fieldValue": "scored" },
            { "fieldId": "intelligence", "fieldValue": "={{ JSON.stringify($json.intelligence) }}" }
          ]
        }
      },
      "id": "b2c3d4e5-0012-4bbb-8000-000000000012",
      "name": "Supabase - Mark Scored",
      "type": "n8n-nodes-base.supabase",
      "typeVersion": 1,
      "position": [-208, 80],
      "credentials": {
        "supabaseApi": { "id": "4pPsx2sAVgrzJm5n", "name": "Supabase Leads" }
      }
    },
    {
      "parameters": {
        "operation": "update",
        "tableId": "leads",
        "filters": {
          "conditions": [
            { "keyName": "id", "condition": "eq", "keyValue": "={{ $('Render Prompt').item.json.leadId }}" }
          ]
        },
        "fieldsUi": {
          "fieldValues": [
            { "fieldId": "status", "fieldValue": "error" }
          ]
        }
      },
      "id": "b2c3d4e5-0013-4bbb-8000-000000000013",
      "name": "Dead Letter - Intelligence Failed",
      "type": "n8n-nodes-base.supabase",
      "typeVersion": 1,
      "position": [16, 400],
      "credentials": {
        "supabaseApi": { "id": "4pPsx2sAVgrzJm5n", "name": "Supabase Leads" }
      }
    },
    {
      "parameters": {
        "errorMessage": "=Intelligence Scorer: lead {{ $('Render Prompt').item.json.leadId }} failed Claude output validation twice in a row (attempt 1: {{ $('Validate Response (Attempt 1)').item.json.reason }}; attempt 2: {{ $json.reason }}). Dead-lettered to status=error, replayable after investigating the prompt/model output."
      },
      "id": "b2c3d4e5-0014-4bbb-8000-000000000014",
      "name": "Fail Execution - Intelligence Invalid",
      "type": "n8n-nodes-base.stopAndError",
      "typeVersion": 1,
      "position": [240, 400]
    }
  ],
  "pinData": {},
  "connections": {
    "When Executed by Another Workflow": {
      "main": [[{ "node": "Supabase - Get Lead", "type": "main", "index": 0 }]]
    },
    "Supabase - Get Lead": {
      "main": [[{ "node": "Execute Workflow - ICP Config Loader", "type": "main", "index": 0 }]]
    },
    "Execute Workflow - ICP Config Loader": {
      "main": [[{ "node": "Render Prompt", "type": "main", "index": 0 }]]
    },
    "Render Prompt": {
      "main": [[{ "node": "Claude API Call (Attempt 1)", "type": "main", "index": 0 }]]
    },
    "Claude API Call (Attempt 1)": {
      "main": [[{ "node": "Validate Response (Attempt 1)", "type": "main", "index": 0 }]]
    },
    "Validate Response (Attempt 1)": {
      "main": [[{ "node": "Attempt 1 Valid?", "type": "main", "index": 0 }]]
    },
    "Attempt 1 Valid?": {
      "main": [
        [{ "node": "Compute Score", "type": "main", "index": 0 }],
        [{ "node": "Claude API Call (Attempt 2)", "type": "main", "index": 0 }]
      ]
    },
    "Claude API Call (Attempt 2)": {
      "main": [[{ "node": "Validate Response (Attempt 2)", "type": "main", "index": 0 }]]
    },
    "Validate Response (Attempt 2)": {
      "main": [[{ "node": "Attempt 2 Valid?", "type": "main", "index": 0 }]]
    },
    "Attempt 2 Valid?": {
      "main": [
        [{ "node": "Compute Score", "type": "main", "index": 0 }],
        [{ "node": "Dead Letter - Intelligence Failed", "type": "main", "index": 0 }]
      ]
    },
    "Compute Score": {
      "main": [[{ "node": "Supabase - Mark Scored", "type": "main", "index": 0 }]]
    },
    "Dead Letter - Intelligence Failed": {
      "main": [[{ "node": "Fail Execution - Intelligence Invalid", "type": "main", "index": 0 }]]
    }
  },
  "active": true,
  "settings": {
    "executionOrder": "v1",
    "binaryMode": "separate",
    "availableInMCP": false,
    "timeSavedMode": "fixed",
    "errorWorkflow": "Yl0d71QmNV63K9MI",
    "callerPolicy": "workflowsFromSameOwner"
  },
  "id": "intelScorer0001a",
  "tags": []
}
```

**Note on `PLACEHOLDER_ANTHROPIC_CRED_ID`:** this can't be known until the credential is created live in the n8n editor (Task 6, Step 2) — matches the exact same situation every prior workflow hit (`4pPsx2sAVgrzJm5n` for Supabase, etc. were all filled in after first live creation). Leave the placeholder in the committed JSON for this first commit; Task 6 replaces it with the real id and Task 8 re-exports the corrected JSON.

- [ ] **Step 2: Validate the JSON parses**

```bash
python3 -m json.tool n8n/workflows/intelligence-scorer.json > /dev/null && echo "valid JSON"
```

Expected: `valid JSON` (catches any escaping mistakes in the embedded `jsCode` strings before it ever reaches n8n).

- [ ] **Step 3: Commit**

```bash
git add n8n/workflows/intelligence-scorer.json
git commit -m "feat(#29): add Intelligence Scorer sub-workflow (score+draft, retry-once, dead-letter, cost logging)"
```

---

### Task 5: Wire `Intelligence Scorer` into `Enrichment Orchestrator`

**Files:**
- Modify: `n8n/workflows/enrichment-orchestrator.json`

**Interfaces:**
- Consumes: `Intelligence Scorer` (workflow id `intelScorer0001a` from Task 4), called with `{ id }` passthrough.

- [ ] **Step 1: Add the new node**

Insert into the `nodes` array (after the existing `Supabase - Mark Enriched` node's definition):

```json
    {
      "parameters": {
        "workflowId": {
          "__rl": true,
          "value": "intelScorer0001a",
          "mode": "list",
          "cachedResultUrl": "/workflow/intelScorer0001a",
          "cachedResultName": "Intelligence Scorer"
        },
        "workflowInputs": {
          "mappingMode": "defineBelow",
          "value": {},
          "matchingColumns": [],
          "schema": [],
          "attemptToConvertTypes": false,
          "convertFieldsToString": true
        },
        "options": {}
      },
      "id": "a1b1c1d1-0014-4001-8001-000000000014",
      "name": "Execute Workflow - Intelligence Scorer",
      "type": "n8n-nodes-base.executeWorkflow",
      "typeVersion": 1.2,
      "position": [1024, 64],
      "alwaysOutputData": true,
      "onError": "continueRegularOutput"
    }
```

- [ ] **Step 2: Wire the connection**

In the `connections` object, change:

```json
    "Any Component OK?": {
      "main": [
        [{ "node": "Supabase - Mark Enriched", "type": "main", "index": 0 }],
        [{ "node": "Supabase - Record Duration Only", "type": "main", "index": 0 }]
      ]
    },
```

(unchanged — `Supabase - Mark Enriched` still gets `Any Component OK?`'s true branch) and add a new entry for `Supabase - Mark Enriched`'s own outgoing connection, which currently doesn't exist (it's a dead end):

```json
    "Supabase - Mark Enriched": {
      "main": [[{ "node": "Execute Workflow - Intelligence Scorer", "type": "main", "index": 0 }]]
    },
```

`Execute Workflow - Intelligence Scorer` itself stays a dead end (matches the established terminal-node convention — nothing downstream needs its output within this workflow).

- [ ] **Step 3: Validate JSON**

```bash
python3 -m json.tool n8n/workflows/enrichment-orchestrator.json > /dev/null && echo "valid JSON"
```

- [ ] **Step 4: Commit**

```bash
git add n8n/workflows/enrichment-orchestrator.json
git commit -m "feat(#29): wire Intelligence Scorer into Enrichment Orchestrator after Mark Enriched"
```

---

### Task 6: Deploy to VPS (CLI-only, git pull first)

**Files:** none (infra step)

- [ ] **Step 1: Git pull the VPS clone FIRST — mandatory per the #28/#29 standing rule**

```bash
ssh lip "cd /home/deploy/lead-intelligence-pipeline && git pull origin main"
```

Expected: shows the new commits from Tasks 1–5 (prompt file, ICP-CONFIG.md fix, `.env.example`, both workflow JSONs) landing on the VPS clone.

- [ ] **Step 2: Create the Anthropic API Key credential in the n8n editor (manual, one-time)**

In the n8n editor: Credentials → New → **Header Auth**. Name: `Anthropic API Key`. Header Name: `x-api-key`. Header Value: the real `ANTHROPIC_API_KEY` value (never paste it into chat/commits — type directly into the n8n UI). Note the credential's generated id (visible in its URL / via `export:workflow` later) — this replaces `PLACEHOLDER_ANTHROPIC_CRED_ID` in both `Claude API Call` nodes once imported.

- [ ] **Step 3: Import + publish `intelligence-scorer.json`**

```bash
scp n8n/workflows/intelligence-scorer.json lip:/tmp/
ssh lip "docker cp /tmp/intelligence-scorer.json n8n-n8n-1:/tmp/intelligence-scorer.json"
ssh lip "docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/intelligence-scorer.json"
```

Then in the n8n editor, open `Intelligence Scorer`, re-select the `Anthropic API Key` credential on both `Claude API Call (Attempt 1)` and `Claude API Call (Attempt 2)` nodes (resource-locator/credential fields don't survive a from-scratch JSON import — same gotcha as every prior workflow), then Publish.

```bash
ssh lip "docker exec n8n-n8n-1 n8n publish:workflow --id=intelScorer0001a"
```

- [ ] **Step 4: Re-import + publish `enrichment-orchestrator.json`**

```bash
scp n8n/workflows/enrichment-orchestrator.json lip:/tmp/
ssh lip "docker cp /tmp/enrichment-orchestrator.json n8n-n8n-1:/tmp/enrichment-orchestrator.json"
ssh lip "docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/enrichment-orchestrator.json"
ssh lip "docker exec n8n-n8n-1 n8n publish:workflow --id=eOrcH3strAt0r01a"
```

Credentials on the existing Supabase nodes should re-link automatically (matching ids), per the established precedent (#22/#23/#24). The new `Execute Workflow - Intelligence Scorer` node's workflow-picker resource-locator may need re-pointing at `Intelligence Scorer` in the editor if it doesn't resolve — check before publishing.

- [ ] **Step 5: Restart n8n**

```bash
ssh lip "docker compose -f ~/n8n/docker-compose.yml restart n8n"
```

- [ ] **Step 6: Confirm both workflows are active**

```bash
ssh lip "docker logs n8n-n8n-1 --tail 30" | grep -i "Activated workflow"
```

Expected: both `Intelligence Scorer` and `Enrichment Orchestrator` appear in the activated-workflow list.

---

### Task 7: Live verification (real webhook, not editor tests)

**Files:** none (verification step — findings get written into Task 8's RUNBOOK section)

Per the RUNBOOK's own gotcha ("Error Workflows don't fire on manual Test workflow runs" / "a manually-triggered run... is not equivalent to a genuine detached background execution"), every case below MUST run through the real `Lead Intake` webhook (`curl -X POST https://<N8N_HOST>/webhook/lead-intake ...`), not an editor manual-test button.

- [ ] **Step 1: Happy path — a normal lead scores end-to-end**

Submit a real lead via `curl` (e.g. `domain: "stripe.com"`, `company: "Stripe"`, a message with a concrete problem statement). Poll Supabase (`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` from `.env`, read-only, per the sanctioned local-credentials policy) for that lead's row.

Expected: `status` progresses `raw → enriched → scored`; `intelligence` jsonb populated with all 5 `dimensions`, `company_summary`, `icp_score` (0–100), `tier` (one of hot/review/nurture/discard), `prompt_version: "lead-scoring-v1"`, `config_version` matching the live `config/icp.default.json`'s `config_version`, `scored_at`, `input_tokens`/`output_tokens`/`cost_usd` all populated and `cost_usd` comfortably under $0.02.

- [ ] **Step 2: Nurture-gate discard path — a low-scoring, non-disqualified lead has no stored draft**

Submit a lead engineered to score below `thresholds.nurture` (25) without tripping a hard disqualifier — e.g. a real small company with no pain-signal language and a terse, low-specificity message. Confirm `tier: "discard"` and `intelligence.draft_email === null`, while `dimensions`/`company_summary`/`icp_score` are still fully populated (proving the draft was generated then discarded, not skipped — check `output_tokens` is not anomalously low compared to a draft-producing case, as weak evidence the model still wrote a draft before it got discarded).

- [ ] **Step 3: Disqualifier path — hard disqualifier caps the score**

Submit a lead matching one of `config/icp.default.json`'s `hard_disqualifiers` (e.g. a personal Gmail sender with no discoverable company — reuse the free-mail-domain-null case from #6's verification). Confirm `intelligence.disqualified === true`, `disqualifier_reason` populated, `icp_score <= 10`, `tier: "discard"`, `draft_email: null` (model-level null per the prompt's own instruction, not the code-level nurture gate).

- [ ] **Step 4: Dead-letter path — force two consecutive validation failures**

Temporarily break something that reliably produces invalid output — the cheapest lever is pointing the `Claude API Call` nodes' credential at a deliberately wrong header value (invalid key) so both attempts get an auth-error response body that fails `Validate Response`'s checks. Re-import/publish/restart with the broken credential, submit a lead via the real webhook, confirm: `Intelligence Scorer`'s execution shows failed in n8n's event log, `leads.status` flips to `error`, and the `Lead Intake Pipeline failure - Intelligence Scorer` alert email is confirmed **delivered** via the Resend API's own `/emails` send log (not assumed from "no editor access to check inbox" — same standard as every prior alert-path verification in this repo). Restore the correct credential afterward and confirm a clean re-run recovers (re-submit the same or a fresh lead → reaches `scored`).

- [ ] **Step 5: Clean up test data**

Delete all test leads (Supabase rows) and any test HubSpot contacts created during verification, per the established "test leads deleted after verification" convention. Name any direct-API writes made outside a workflow's own execution explicitly in the session summary (per CLAUDE.md's credential-verification policy) — deleting test rows via a direct Supabase REST call counts.

---

### Task 8: Update docs

**Files:**
- Modify: `docs/RUNBOOK.md`
- Modify: `docs/DECISIONS.md`

- [ ] **Step 1: Add a RUNBOOK.md section "Intelligence Scorer (#29)"**

Insert after the "ICP Config Loader (#28)" section, following the established per-issue section structure (workflow description, deploy commands, verification results with **actual** evidence from Task 7 — dates, real values, real Resend send-log confirmation — not placeholder text):

```markdown
## Intelligence Scorer (#29)

`n8n/workflows/intelligence-scorer.json` (id `intelScorer0001a`) — sub-workflow. Execute Workflow Trigger (passthrough `{ id }`) → `Supabase - Get Lead` → calls `ICP Config Loader` (#28, now wired into the real pipeline for the first time) → `Render Prompt` (Code node, embeds `prompts/lead-scoring.v1.md`'s approved template with `${...}` substitution from the loaded config + lead row) → Claude API call (`claude-haiku-4-5`, HTTP Request node + Header Auth credential — no dedicated n8n Anthropic node exists) → schema-validates the JSON response → retry once on failure → dead-letter (`status=error` + alert) on a second failure → `Compute Score` (Code node: weighted sum from `config.scoring_dimensions`, disqualifier cap at 10, tier from `config.thresholds`, nurture gate discards `draft_email` when `tier === 'discard'`) → `Supabase - Mark Scored` (`status='scored'`, `leads.intelligence` jsonb).

**Model/code division of labor** (see docs/DECISIONS.md 2026-07-22): the model does judgment (per-dimension scores + evidence, company summary, draft email); code does arithmetic and policy (weighted total, disqualifier cap, tier, nurture gate) — deterministic, reproducible from `prompt_version` + `config_version` alone.

**ICP Config Loader failure inside Intelligence Scorer is a known, accepted double-alert case, not a bug**: the `Execute Workflow - ICP Config Loader` call has no `onError` override (unlike the three sub-workflow calls inside `Enrichment Orchestrator`) — if the ICP config is invalid, `ICP Config Loader` fails and fires its own alert, and `Intelligence Scorer`'s own execution then also fails and fires a second alert via the same `Lead Intake - Error Alert` workflow. This is a deliberate exception to the #23 continueRegularOutput precedent: unlike a single enrichment component failing (where the other two can still yield a usable lead), a broken ICP config makes scoring **entirely impossible** — there's no partial-success path to continue into, so suppressing the cascade would need new dead-letter semantics for a problem that isn't this lead's fault. Two emails for one root cause is an acceptable cost for a case expected to be rare (a global config break, not a per-lead failure mode).

**Wired into `Enrichment Orchestrator`**: `Supabase - Mark Enriched` (the `anyOk === true` branch) now calls `Execute Workflow - Intelligence Scorer` with `onError: "continueRegularOutput"` + `alwaysOutputData: true`, matching the three existing sub-workflow calls — a scoring failure is already self-alerted by `Intelligence Scorer`'s own dead-letter path, so the orchestrator doesn't re-alert for the same root cause (same fix class as #23's double-alert bug). Leads whose enrichment entirely failed (`anyOk === false`) never reach scoring — `status` stays `raw`/never advances past the existing enrichment alert path, unchanged from #23.

**Credentials**: `Anthropic API Key` (n8n Header Auth credential: `x-api-key` → `ANTHROPIC_API_KEY`), created directly in the n8n editor, never pasted into chat/commits. See `.env.example`.

**Deploy (CLI-only path, `git pull` on the VPS clone FIRST per the #28 drift finding):**
```bash
ssh lip "cd /home/deploy/lead-intelligence-pipeline && git pull origin main"
scp n8n/workflows/intelligence-scorer.json lip:/tmp/
ssh lip "docker cp /tmp/intelligence-scorer.json n8n-n8n-1:/tmp/intelligence-scorer.json"
ssh lip "docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/intelligence-scorer.json"
ssh lip "docker exec n8n-n8n-1 n8n publish:workflow --id=intelScorer0001a"
scp n8n/workflows/enrichment-orchestrator.json lip:/tmp/
ssh lip "docker cp /tmp/enrichment-orchestrator.json n8n-n8n-1:/tmp/enrichment-orchestrator.json"
ssh lip "docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/enrichment-orchestrator.json"
ssh lip "docker exec n8n-n8n-1 n8n publish:workflow --id=eOrcH3strAt0r01a"
ssh lip "docker compose -f ~/n8n/docker-compose.yml restart n8n"
```

**Verified end-to-end in production (<FILL IN REAL DATE>), through the real `Lead Intake` webhook:**
- <FILL IN: happy-path result — real lead id, real icp_score/tier/cost_usd values>
- <FILL IN: nurture-gate discard result — real lead id, confirmed draft_email null while dimensions populated>
- <FILL IN: disqualifier-cap result — real lead id, confirmed icp_score <= 10>
- <FILL IN: dead-letter result — confirmed status=error, confirmed Resend send-log delivery of the alert, confirmed clean recovery after restoring the credential>
- Fresh `export:workflow` for both `intelligence-scorer.json` and `enrichment-orchestrator.json` diffed clean against the committed JSON (only n8n's own bookkeeping fields differed) — <CONFIRM OR NOTE DIFFS>.
- All test leads (Supabase rows) deleted after verification.
```

- [ ] **Step 2: Add the ICP-Config-Loader-double-alert acceptance to DECISIONS.md**

Append (after the existing 2026-07-22 #29 entries already in the file):

```markdown

2026-07-22 — #29: `Intelligence Scorer`'s call to `ICP Config Loader` has no `onError` override, unlike the three sub-workflow calls inside `Enrichment Orchestrator` (#23's `continueRegularOutput` fix). Why the asymmetry: `Enrichment Orchestrator`'s components each cover one of three independent enrichment signals — one failing still leaves two others potentially usable, so continuing and alerting only once (via the failed component's own Error Workflow) is correct. A broken ICP config has no such partial-success path — nothing about scoring is possible without it — so `Intelligence Scorer`'s own execution failing too, and alerting a second time via the same `Lead Intake - Error Alert` workflow, is accepted as a known, minor cost rather than engineered around with new dead-letter semantics for a global-config-broken case that isn't any individual lead's fault.
```

- [ ] **Step 3: Commit**

```bash
git add docs/RUNBOOK.md docs/DECISIONS.md
git commit -m "docs(#29): record Intelligence Scorer runbook section and ICP-config-failure double-alert decision"
```

---

### Task 9: Issue reconciliation, close, push, board check

**Files:** none (GitHub/process step)

- [ ] **Step 1: Post the AC-reconciliation comment on issue #29**

```bash
gh issue comment 29 --body "$(cat <<'EOF'
AC reconciliation (plan-vs-reality, same pattern as #4's Service Key and #24's dedupe matching):

The AC's nurture-gate line — "leads scoring below nurture threshold get NO draft email (token cost gate)" — assumes the score is known before drafting. That's impossible under the approved one-structured-call architecture: the model scores AND drafts in a single response, and code only sees the score after the call returns. Honoring the AC literally would require a second round-trip, breaking the one-call design defended since Sprint 1, for a sub-cent (Haiku-priced) token saving.

Implemented as option A instead: the draft is always generated in the one call (the model itself nulls it only on disqualification, per its own prompt instruction); code discards/withholds the draft below the nurture threshold rather than delivering or persisting it. Same net effect for the business (nobody below-nurture gets emailed a draft) via a different mechanism. See docs/DECISIONS.md 2026-07-22 and docs/ICP-CONFIG.md's updated nurture-gate wording.

Closes #29.
EOF
)"
```

- [ ] **Step 2: Push**

```bash
git push origin main
```

- [ ] **Step 3: Close the issue**

```bash
gh issue close 29 --comment "Merged to main, deployed, verified end-to-end via the real webhook (happy path + nurture-gate discard + disqualifier cap + dead-letter/retry, all four confirmed with real evidence in docs/RUNBOOK.md). Docs updated."
```

- [ ] **Step 4: Verify board state (Definition of Done, not optional)**

```bash
gh project item-list 1 --owner nicopxm --format json | python3 -c "import json,sys; items=json.load(sys.stdin)['items']; print([i for i in items if '29' in str(i.get('content',{}).get('number',''))])"
```

Confirm #29's card shows `Done`. If GitHub's automation already handled it, this is a 5-second check; if not, move it via `gh project item-edit` (see docs/RUNBOOK.md's board commands) in the same session.

- [ ] **Step 5: Update LOG.md status line — reminder only**

Per CLAUDE.md, LOG.md is Wop's to edit — don't write it. Flag to Wop that #29 is closed so today's line (or tomorrow's Y) reflects it.
