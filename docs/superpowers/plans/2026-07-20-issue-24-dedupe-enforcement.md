# Issue #24 — Dedupe Enforcement (30-day update-not-insert at intake) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resubmitting a lead within 30 days updates the existing Supabase row and HubSpot contact in place instead of creating a duplicate, and does not re-trigger enrichment; resubmitting after 30 days updates in place AND re-triggers enrichment; a same-email-different-domain resubmission is treated as a brand-new lead.

**Architecture:** `Lead Intake` gains a dedupe-lookup stage between validation and the DB write: compute the matching key (domain when non-null, else email — this order, not a flat OR, is what makes the job-change edge case work), look up the most recent matching row via Supabase `getAll`, then branch into INSERT (no prior match) vs UPDATE (prior match, with a >30-day check gating re-enrichment). Both branches converge into one normalizing node so every downstream consumer (HubSpot upsert, Respond 200, error alert, Enrichment Orchestrator trigger) has one stable reference point regardless of which branch ran.

**Tech Stack:** n8n (self-hosted, workflow JSON in `n8n/workflows/lead-intake.json`), Supabase Postgres (via n8n's native Supabase node, PostgREST filters), HubSpot (via n8n's native HubSpot node — already upserts by email, see Task 2 finding).

## Global Constraints

- Dedupe window is exactly 30 days, measured from the matched row's `updated_at`.
- Matching key: domain when the incoming payload's domain is non-null; email only when domain is null. This is NOT `email OR domain` — same email + different (both non-null) domain must NOT match (ARCHITECTURE.md decision #6's job-change edge case).
- A ≤30-day match: UPDATE row (`message` appended if different, `submitted_at`/`source` refreshed), must NOT fire the Enrichment Orchestrator.
- A >30-day match: UPDATE row (same field refresh) AND fires the Enrichment Orchestrator (status reset to `raw` first, since it's a new buying event).
- No match: INSERT (existing behavior, unchanged) and fires the Enrichment Orchestrator.
- No silent failures: nothing in this change may introduce a path where 0 upstream items silently kills execution (the repo has hit this class of bug twice already — #21, #23). Every new Supabase lookup node that can legitimately return 0 rows must set `alwaysOutputData: true`.
- n8n `alwaysOutputData: true` on zero output emits exactly one item with `json: {}` — confirmed by reading n8n core (`workflow-execute.ts`), not assumed. Downstream code must treat presence of `match.id` as the signal, not assume any other field survived.
- Workflow JSON edits happen live in the n8n editor (per RUNBOOK: "always fix in the live editor then re-export, don't hand-edit the JSON [as the final source]") — the JSON in this plan is the import payload / starting point, not guaranteed pixel-perfect; fix live, then re-export and diff against what's committed here before closing the issue.
- Per CLAUDE.md DoD: fresh export of the workflow after live verification, diffed against the committed JSON, before closing #24.

---

## Investigation findings (read before starting — these resolve ambiguity in the issue text)

1. **HubSpot already upserts.** `HubSpot - Create Contact`'s saved JSON has no `"operation"` key, which means it's on the node's default — and the HubSpot node's contact-resource default operation is `upsert` ("Create a new contact, or update the current one if it already exists"), confirmed by reading n8n's `ContactDescription.ts` source. **This means the "HubSpot upsert behavior verified consistent" acceptance criterion needs verification, not a code change.** Do not add HubSpot-side branching logic for this.
2. **Matching logic must be domain-priority-with-email-fallback, not `email OR domain`.** A flat OR would break the explicit job-change edge case in ARCHITECTURE.md #6 (same email, different domain → new lead). Task 2 implements this as a boolean branch (`Has Domain?`) into two separate single-condition Supabase lookups (`Find Lead By Domain` / `Find Lead By Email`) rather than one node with a dynamically-expressioned `keyName` — the Supabase node's `keyName` field is normally column-picker-driven, and whether it accepts an expression wasn't worth staking correctness on when two static, unambiguous nodes are just as simple.
3. **`alwaysOutputData: true` emits `{ json: {} }` on zero results, not a passthrough of input data** — read directly from `packages/core/src/execution-engine/workflow-execute.ts` (`nodeSuccessData[0] = [{ json: {}, pairedItem }]`). Any code that needs the original lead payload after a possibly-empty lookup must reference the upstream node by name (`$('Compute Dedupe Key').item.json...`), never assume it survived on `$json`. This is the same class of gotcha as #21/#23 — see docs/RUNBOOK.md's existing notes on zero-item chains.

---

## Task 1: Supabase migration — index for domain-only lookups

**Files:**
- Create: `supabase/migrations/20260720140000_add_leads_domain_idx.sql`

**Interfaces:**
- Produces: `leads_domain_idx` — a partial btree index on `leads(domain)` for `domain is not null`.

- [ ] **Step 1: Write the migration**

```sql
-- Issue #24: dedupe lookup at intake now queries "domain = X" on its own when the
-- incoming lead has a domain (see docs/ARCHITECTURE.md #6 — domain takes priority
-- over email as the matching key). The existing leads_email_domain_idx (email, domain)
-- has email as its leading column, so it can't serve a domain-only WHERE efficiently.
create index leads_domain_idx on leads (domain) where domain is not null;
```

- [ ] **Step 2: Apply it**

No local Supabase CLI (per memory: Homebrew perms issue, `sb_secret_` keys in use). Paste the SQL into the Supabase dashboard's SQL Editor and run it, per the existing RUNBOOK deploy process (`docs/RUNBOOK.md` §"Apply migrations").

- [ ] **Step 3: Verify**

In the Supabase SQL Editor:
```sql
select indexname, indexdef from pg_indexes where tablename = 'leads';
```
Expected: `leads_domain_idx` present alongside `leads_email_domain_idx` and the primary key index.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260720140000_add_leads_domain_idx.sql
git commit -m "feat(#24): add partial index for domain-only dedupe lookups"
```

---

## Task 2: Rewrite `n8n/workflows/lead-intake.json` — dedupe lookup, branch, and normalize

**Files:**
- Modify: `n8n/workflows/lead-intake.json` (full file — new nodes inserted between `Is Valid?` and the existing `Supabase - Insert Lead`/`HubSpot - Create Contact`/`Execute Workflow - Enrichment Orchestrator` chain; four existing nodes get their cross-node expression references repointed)

**Interfaces:**
- Produces: a `Normalize Lead Record` node whose output `{ id, name, email, company, domain, source, reenrich }` is the single stable reference point every downstream node uses instead of `Supabase - Insert Lead`.

### New nodes to add

**`Compute Dedupe Key`** (Code, runs after `Is Valid?`'s true branch, before the old `Supabase - Insert Lead`):
```js
const item = $input.item.json;
return [{
  json: {
    ...item,
    has_domain: !!item.domain
  }
}];
```

**`Has Domain?`** (If, boolean check matching the existing `Is Valid?` node's style):
```json
{
  "conditions": {
    "options": { "caseSensitive": true, "leftValue": "", "typeValidation": "strict", "version": 2 },
    "conditions": [
      {
        "id": "cond-has-domain",
        "leftValue": "={{ $json.has_domain }}",
        "rightValue": true,
        "operator": { "type": "boolean", "operation": "true", "singleValue": true }
      }
    ],
    "combinator": "and"
  },
  "options": {}
}
```
True (output 0) → `Supabase - Find Lead By Domain`. False (output 1) → `Supabase - Find Lead By Email`.

**`Supabase - Find Lead By Domain`** (Supabase, `getAll`, `alwaysOutputData: true` at the node level — required so a 0-row result still emits one item instead of silently killing the branch):
```json
{
  "operation": "getAll",
  "tableId": "leads",
  "returnAll": false,
  "limit": 1,
  "orderBy": "updated_at.desc",
  "filters": {
    "conditions": [
      { "keyName": "domain", "condition": "eq", "keyValue": "={{ $json.domain }}" }
    ]
  }
}
```
Credentials: same `supabaseApi` block (`id: 4pPsx2sAVgrzJm5n`, `name: Supabase Leads`) as `Supabase - Insert Lead`.

**`Supabase - Find Lead By Email`** (identical shape, `alwaysOutputData: true`):
```json
{
  "operation": "getAll",
  "tableId": "leads",
  "returnAll": false,
  "limit": 1,
  "orderBy": "updated_at.desc",
  "filters": {
    "conditions": [
      { "keyName": "email", "condition": "eq", "keyValue": "={{ $json.email }}" }
    ]
  }
}
```

Both feed into:

**`Decide Dedupe Action`** (Code, runs once per item — receives exactly one item either way per the `alwaysOutputData` guarantee):
```js
const lead = $('Compute Dedupe Key').item.json;
const match = $input.item.json; // {} if no match found (alwaysOutputData zero-result shape)
const hasMatch = !!match.id;

let action, reenrich, existing_id, existing_status;
let message = lead.message;

if (!hasMatch) {
  action = 'insert';
  reenrich = true;
} else {
  action = 'update';
  existing_id = match.id;
  existing_status = match.status;
  const daysSince = (Date.now() - new Date(match.updated_at).getTime()) / 86400000;
  reenrich = daysSince > 30;

  if (match.message && lead.message && match.message !== lead.message) {
    message = `${match.message}\n---\n${lead.message}`;
  } else if (!lead.message && match.message) {
    message = match.message;
  }
}

return [{
  json: {
    name: lead.name,
    email: lead.email,
    company: lead.company,
    domain: lead.domain,
    source: lead.source,
    message,
    submitted_at: lead.submitted_at,
    action,
    reenrich,
    existing_id,
    existing_status
  }
}];
```

**`Insert or Update?`** (If, string equality — matches the "operation": "equals" pattern already used in `tech-stack-detector.json`):
```json
{
  "conditions": {
    "options": { "caseSensitive": true, "leftValue": "", "typeValidation": "strict", "version": 2 },
    "conditions": [
      {
        "id": "cond-is-insert",
        "leftValue": "={{ $json.action }}",
        "rightValue": "insert",
        "operator": { "type": "string", "operation": "equals" }
      }
    ],
    "combinator": "and"
  },
  "options": {}
}
```
True (output 0) → existing `Supabase - Insert Lead` node (parameters unchanged). False (output 1) → new `Supabase - Update Lead`.

**`Supabase - Update Lead`** (Supabase, `update`):
```json
{
  "operation": "update",
  "tableId": "leads",
  "filters": {
    "conditions": [
      { "keyName": "id", "condition": "eq", "keyValue": "={{ $json.existing_id }}" }
    ]
  },
  "fieldsUi": {
    "fieldValues": [
      { "fieldId": "message", "fieldValue": "={{ $json.message }}" },
      { "fieldId": "submitted_at", "fieldValue": "={{ $json.submitted_at }}" },
      { "fieldId": "source", "fieldValue": "={{ $json.source }}" },
      { "fieldId": "status", "fieldValue": "={{ $json.reenrich ? 'raw' : $json.existing_status }}" }
    ]
  }
}
```
Credentials: same `supabaseApi` block.

Both `Supabase - Insert Lead` and `Supabase - Update Lead` feed into:

**`Normalize Lead Record`** (Code, runs once per item — deliberately does NOT trust the Supabase Insert/Update node's own returned shape for `id`, since that depends on PostgREST `Prefer: return=representation` behavior that isn't verified for the `update` operation; pulls from `Decide Dedupe Action` instead, which is already known-good):
```js
const decision = $('Decide Dedupe Action').item.json;
const id = decision.action === 'insert' ? $input.item.json.id : decision.existing_id;

return [{
  json: {
    id,
    name: decision.name,
    email: decision.email,
    company: decision.company,
    domain: decision.domain,
    source: decision.source,
    reenrich: decision.reenrich
  }
}];
```

**`Should Reenrich?`** (If, boolean, same style as `Has Domain?`):
```json
{
  "conditions": {
    "options": { "caseSensitive": true, "leftValue": "", "typeValidation": "strict", "version": 2 },
    "conditions": [
      {
        "id": "cond-reenrich",
        "leftValue": "={{ $json.reenrich }}",
        "rightValue": true,
        "operator": { "type": "boolean", "operation": "true", "singleValue": true }
      }
    ],
    "combinator": "and"
  },
  "options": {}
}
```
True (output 0) → existing `Execute Workflow - Enrichment Orchestrator` node (parameters unchanged — still `waitForSubWorkflow: false`, still a deliberate dead end). False (output 1) → no connection (dead end; this is the cost-guard path).

### Existing nodes whose expressions must be repointed

All four currently read `$('Supabase - Insert Lead').item.json...`, which will error (`no data found for referenced node`) whenever an item took the Update branch instead, since that node never executed for that item. Repoint all four to `$('Normalize Lead Record').item.json...`:

- `HubSpot - Create Contact` — rename to `HubSpot - Upsert Contact` (it already performs upsert by default; the rename documents that fact instead of implying it's create-only). Change:
  - `email`: `={{ $('Normalize Lead Record').item.json.email }}`
  - `additionalFields.companyName`: `={{ $('Normalize Lead Record').item.json.company }}`
  - `additionalFields.firstName`: `={{ $('Normalize Lead Record').item.json.name.split(' ')[0] }}`
  - `additionalFields.lastName`: `={{ $('Normalize Lead Record').item.json.name.split(' ').slice(1).join(' ') }}`
- `Respond 200 - OK` — `responseBody`: `={{ { "status": "ok", "id": $('Normalize Lead Record').item.json.id } }}`
- `Fail Execution - HubSpot Error` — `errorMessage`: `=HubSpot contact upsert failed for lead {{ $('Normalize Lead Record').item.json.id }} ({{ $('Normalize Lead Record').item.json.email }}): {{ $json.error ? $json.error.toString() : JSON.stringify($json) }}. Lead marked status=error in Supabase, replayable after fix.`
- `Supabase - Mark Lead Error` — `filters.conditions[0].keyValue`: `={{ $('Normalize Lead Record').item.json.id }}`
- `HubSpot - Set Lead Source` — `jsonBody`: `={{ { "properties": { "lead_source": $('Normalize Lead Record').item.json.source } } }}`
- Rename the incoming connection edge from `HubSpot - Create Contact` to `HubSpot - Upsert Contact` throughout `connections`.

### Full connection graph after this task

```
Webhook - Lead Intake → Validate Payload → Is Valid?
Is Valid? [true]  → Compute Dedupe Key → Has Domain?
Is Valid? [false] → Respond 400 - Invalid

Has Domain? [true]  → Supabase - Find Lead By Domain
Has Domain? [false] → Supabase - Find Lead By Email
Supabase - Find Lead By Domain → Decide Dedupe Action
Supabase - Find Lead By Email  → Decide Dedupe Action

Decide Dedupe Action → Insert or Update?
Insert or Update? [true=insert]  → Supabase - Insert Lead
Insert or Update? [false=update] → Supabase - Update Lead
Supabase - Insert Lead → Normalize Lead Record
Supabase - Update Lead → Normalize Lead Record

Normalize Lead Record → HubSpot - Upsert Contact
Normalize Lead Record → Should Reenrich?

Should Reenrich? [true]  → Execute Workflow - Enrichment Orchestrator   (dead end, fire-and-forget, unchanged)
Should Reenrich? [false] → (dead end — cost guard: no re-enrichment)

HubSpot - Upsert Contact [main]  → HubSpot - Set Lead Source → Respond 200 - OK
HubSpot - Upsert Contact [error] → Supabase - Mark Lead Error → Fail Execution - HubSpot Error
```

- [ ] **Step 1: Write the new `n8n/workflows/lead-intake.json`** with all nodes/connections above, using the UUIDs below for the new nodes (existing node IDs/params stay untouched except the five repointed expressions and the one rename):

| Node | id |
|---|---|
| Compute Dedupe Key | `e3d0f78f-bf8d-482c-86c0-e9cae769104d` |
| Has Domain? | `8e323835-0b87-4fc6-ba63-eb2a280d086c` |
| Supabase - Find Lead By Domain | `d77e3539-c76d-4ff1-b9a5-f3f69cdbc987` |
| Supabase - Find Lead By Email | `b1a12467-370a-4490-b779-9048929311df` |
| Decide Dedupe Action | `52901cd9-446f-43d0-9bcf-0cff90c04670` |
| Insert or Update? | `1124303e-3df3-4c57-a478-e14ad972da0b` |
| Supabase - Update Lead | `bcabdc32-5f8c-4a27-917a-6844d6ef5507` |
| Normalize Lead Record | `04854fb6-45c4-4c0b-bb05-8ea407d8dce8` |
| Should Reenrich? | `5d0d1281-45b3-4309-8214-09e450d064bf` |

Keep the workflow-level `id` (`ql9dgCIrIKvVeukr`), `versionId`, `meta`, `settings` (including `errorWorkflow: Yl0d71QmNV63K9MI`) unchanged — this is an update to the existing workflow, not a new one.

- [ ] **Step 2: Validate the JSON parses and every connection target name exists**

```bash
python3 -c "
import json
with open('n8n/workflows/lead-intake.json') as f:
    data = json.load(f)
names = {n['name'] for n in data['nodes']}
for src, conns in data['connections'].items():
    assert src in names, f'unknown source {src}'
    for branch in conns.get('main', []):
        for c in branch:
            assert c['node'] in names, f'unknown target {c[\"node\"]} from {src}'
print('OK:', len(data['nodes']), 'nodes,', len(data['connections']), 'wired sources')
"
```
Expected: `OK: 20 nodes, ...` with no assertion error (11 original + 9 new: Compute Dedupe Key, Has Domain?, Supabase - Find Lead By Domain, Supabase - Find Lead By Email, Decide Dedupe Action, Insert or Update?, Supabase - Update Lead, Normalize Lead Record, Should Reenrich?).

- [ ] **Step 3: Commit**

```bash
git add n8n/workflows/lead-intake.json
git commit -m "feat(#24): add dedupe lookup/branch to Lead Intake workflow JSON"
```

Note: this commit is the *starting point* for the live import, not the final committed state — Task 5 re-exports after live verification and fixes (per RUNBOOK precedent, resource-locator/credential fields and any node-shape quirks the editor silently changes on import need to be reconciled before this is the final commit).

---

## Task 3: Deploy — import into the live n8n instance

**Files:** none (infra step, no repo changes)

- [ ] **Step 1: Move the board card to In Progress**

#24 is already on the board (project 1, item id `PVTI_lAHOBqSzx84BcUc0zgyr464`), currently in "Sprint". Move it before making live changes:

```bash
gh project item-edit --project-id PVT_kwHOBqSzx84BcUc0 \
  --id PVTI_lAHOBqSzx84BcUc0zgyr464 \
  --field-id PVTSSF_lAHOBqSzx84BcUc0zhW-KN0 \
  --single-select-option-id c8c11125
```

- [ ] **Step 2: Copy the workflow JSON to the VPS and import** (same CLI-only path used for #22/#23, per `docs/RUNBOOK.md`):

```bash
scp n8n/workflows/lead-intake.json <vps-host>:/tmp/
ssh <vps-host> "docker cp /tmp/lead-intake.json n8n-n8n-1:/tmp/lead-intake.json"
ssh <vps-host> "docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/lead-intake.json"
```
Since this re-imports the existing workflow id (`ql9dgCIrIKvVeukr`), the Supabase/HubSpot credentials should re-link automatically (matching ids, per the #22 precedent already confirmed live).

- [ ] **Step 3: Open the workflow in the n8n editor and fix anything import didn't preserve**

Per RUNBOOK's standing gotcha, resource-locator/dropdown-driven fields can come back empty after import even when the exported JSON had values. Check each new/changed node:
- `Supabase - Find Lead By Domain` / `By Email` / `Update Lead`: reselect the `Supabase Leads` credential if it shows unlinked; confirm `tableId` shows `leads` (this one is a plain string field in this node version, so it likely survives, but verify).
- `HubSpot - Upsert Contact`: confirm `HubSpot Service Key` credential is linked.
- Confirm `Execute Workflow - Enrichment Orchestrator`'s workflow picker still points at `Enrichment Orchestrator` and `options.waitForSubWorkflow` is still `false` (unchanged node, but re-verify post-import since this exact setting was the subject of a #23 gotcha).

- [ ] **Step 4: Publish and restart**

```bash
ssh <vps-host> "docker exec n8n-n8n-1 n8n publish:workflow --id=ql9dgCIrIKvVeukr"
ssh <vps-host> "docker compose -f ~/n8n/docker-compose.yml restart n8n"
ssh <vps-host> "docker logs n8n-n8n-1 --tail 20"
```
Expected: `Lead Intake` appears in the "Activated workflow" list in the logs.

---

## Task 4: Live verification — within-30-days resubmit (no re-enrichment)

**Files:** none

- [ ] **Step 1: Submit a fresh test lead through the real webhook** (not a manual editor test run — per RUNBOOK's #21 gotcha, manual runs don't exercise the same path and error workflows don't fire from them):

```bash
curl -s -X POST https://n8n.nicopxm.me/webhook/lead-intake \
  -H "Content-Type: application/json" \
  -d '{"name":"Dedupe Test","email":"dedupe-test-24@example.com","company":"Dedupe Test Co","domain":"dedupetest24.example.com","source":"manual_test","message":"first submission","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
```
Expected: `{"status":"ok","id":"<uuid>"}`. Note the `id`.

- [ ] **Step 2: In Supabase, confirm one row, status progressing toward enriched**

```sql
select id, status, submitted_at, updated_at, enriched_at from leads where email = 'dedupe-test-24@example.com';
```
Expected: exactly one row, `status` moves to `enriched` within ~10s (orchestrator ran, since this is a genuinely new lead).

- [ ] **Step 3: Resubmit the same lead within minutes, with a different message**

```bash
curl -s -X POST https://n8n.nicopxm.me/webhook/lead-intake \
  -H "Content-Type: application/json" \
  -d '{"name":"Dedupe Test","email":"dedupe-test-24@example.com","company":"Dedupe Test Co","domain":"dedupetest24.example.com","source":"manual_test","message":"second submission","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
```
Expected: `{"status":"ok","id":"<same-uuid-as-step-1>"}`.

- [ ] **Step 4: Confirm still exactly one Supabase row, message appended, no status regression to `raw`**

```sql
select id, status, message, submitted_at, updated_at from leads where email = 'dedupe-test-24@example.com';
```
Expected: one row, `id` unchanged, `message` = `"first submission\n---\nsecond submission"`, `submitted_at` refreshed to the second call's timestamp, `status` still `enriched` (not reset — this was the ≤30-day path, no re-enrichment).

- [ ] **Step 5: Confirm zero new orchestrator executions from the resubmit**

In the n8n editor, Executions tab, filter to `Enrichment Orchestrator`. Expected: exactly one execution total for this lead's `id` (from step 1), none triggered by step 3's resubmit. This is the cost-guard proof — absence of a second execution is the evidence, per the issue's framing.

- [ ] **Step 6: Confirm one HubSpot contact, not two**

Via the HubSpot UI or API, search contacts by `dedupe-test-24@example.com`. Expected: exactly one contact; its properties reflect the latest submission (name/company from the most recent upsert call).

---

## Task 5: Live verification — >30-day resubmit (re-enrichment fires)

**Files:** none

- [ ] **Step 1: Backdate the test lead's timestamps directly in Supabase** (don't wait a month):

```sql
update leads
set updated_at = now() - interval '31 days',
    submitted_at = now() - interval '31 days',
    status = 'enriched'
where email = 'dedupe-test-24@example.com';
```

- [ ] **Step 2: Resubmit the same lead again through the real webhook**

```bash
curl -s -X POST https://n8n.nicopxm.me/webhook/lead-intake \
  -H "Content-Type: application/json" \
  -d '{"name":"Dedupe Test","email":"dedupe-test-24@example.com","company":"Dedupe Test Co","domain":"dedupetest24.example.com","source":"manual_test","message":"third submission after 31 days","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
```
Expected: `{"status":"ok","id":"<same-uuid>"}`.

- [ ] **Step 3: Confirm still one row, status reset to `raw` then re-progressed to `enriched`**

```sql
select id, status, message, enriched_at, updated_at from leads where email = 'dedupe-test-24@example.com';
```
Expected: one row (same `id`), `message` has the third submission appended, `status` is `enriched` again with a fresh `enriched_at` (newer than the first run's).

- [ ] **Step 4: Confirm a second orchestrator execution fired**

n8n Executions tab, `Enrichment Orchestrator`, filtered to this lead's `id`. Expected: exactly two executions total now — one from Task 4 Step 1, one from this step. This proves the >30-day re-enrichment path actually fires (not just "doesn't crash").

- [ ] **Step 5: Confirm same email + different domain is NOT treated as a dedupe match**

```bash
curl -s -X POST https://n8n.nicopxm.me/webhook/lead-intake \
  -H "Content-Type: application/json" \
  -d '{"name":"Dedupe Test","email":"dedupe-test-24@example.com","company":"New Co","domain":"differentcompany24.example.com","source":"manual_test","message":"job change","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
```
```sql
select id, email, domain from leads where email = 'dedupe-test-24@example.com';
```
Expected: **two** rows now for this email — the original (`dedupetest24.example.com`) and a brand-new one (`differentcompany24.example.com`) — confirming the job-change edge case creates a new lead rather than updating the existing one.

- [ ] **Step 6: Clean up test data**

Delete the two test rows from Supabase and both test contacts from HubSpot (matching the precedent set in #6's verification — test leads/contacts always deleted after verification).

```sql
delete from leads where email = 'dedupe-test-24@example.com';
```

---

## Task 6: Fresh export, docs, close

**Files:**
- Modify: `n8n/workflows/lead-intake.json` (fresh export, only if the live editor diverged from Task 2's committed version)
- Modify: `docs/RUNBOOK.md` (dedupe operational notes)
- Modify: `docs/DECISIONS.md` (one-liner)
- Modify: `CLAUDE.md` (current status section)

- [ ] **Step 1: Fresh export and diff**

In the n8n editor: `Lead Intake` → "..." menu → Download. Save over `n8n/workflows/lead-intake.json`, then:
```bash
git diff n8n/workflows/lead-intake.json
```
Reconcile any drift (credential re-links, node-shape normalization n8n applied on import) — this diff is expected to be non-empty per the standing RUNBOOK caveat; review it's only the expected reconciliation, not a functional regression.

- [ ] **Step 2: Update `docs/RUNBOOK.md`**

Add a subsection under the `Lead Intake` operational notes documenting: the domain-priority-then-email matching rule, the `alwaysOutputData: {}`-on-zero-results n8n behavior (now a second confirmed instance of this class of gotcha, after #21/#23), and the verification steps run in Tasks 4/5 with their dates and results.

- [ ] **Step 3: Update `docs/DECISIONS.md`**

One line: date, "dedupe matches on domain when non-null else email (not both), because a flat OR broke the ARCHITECTURE #6 job-change edge case", link to this plan.

- [ ] **Step 4: Update `CLAUDE.md` current status**

Append #24's completion to the Sprint 3 status line per the existing running-log convention.

- [ ] **Step 5: Commit and push**

```bash
git add n8n/workflows/lead-intake.json docs/RUNBOOK.md docs/DECISIONS.md CLAUDE.md
git commit -m "docs(#24): record dedupe enforcement verification, close out

Closes #24"
git push
```

- [ ] **Step 6: Verify board state**

```bash
gh project item-list 1 --owner nicopxm --format json
```
Confirm #24's card (item id `PVTI_lAHOBqSzx84BcUc0zgyr464`) shows `"status": "Done"`, matching its closed issue state — per CLAUDE.md's final-step requirement, don't assume automation handled it. If not, move it explicitly:
```bash
gh project item-edit --project-id PVT_kwHOBqSzx84BcUc0 \
  --id PVTI_lAHOBqSzx84BcUc0zgyr464 \
  --field-id PVTSSF_lAHOBqSzx84BcUc0zhW-KN0 \
  --single-select-option-id 2dad2258
```
