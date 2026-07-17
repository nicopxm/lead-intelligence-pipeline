# Enrichment Orchestration (#23) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Adaptation note:** this repo's Sprint-2 workflows are n8n JSON, not a pytest/jest codebase. There is no automated test runner for n8n workflows. "Test" steps in this plan follow the pattern already established and RUNBOOKed in #20–#22: hand-author the workflow JSON, deploy via the n8n CLI (`import:workflow` / `publish:workflow` / `docker compose restart n8n`), then verify live via `Execute Workflow` test runs or real `curl` POSTs against the webhook, checking actual Supabase rows. Treat each "Deploy + verify" step the way a TDD step treats "run the test."

**Goal:** Compose the three existing enrichment sub-workflows (#20 Website Scraper, #21 Tech Stack Detector, #22 News RSS) behind one new `Enrichment Orchestrator` workflow, wire it into `Lead Intake`, and have it flip `leads.status` raw→enriched (+ `enriched_at`, + a new `enrichment_duration_ms`) whenever at least one component succeeded, or leave status at `raw` and alert when none did.

**Architecture:** `Lead Intake` fans out from `Supabase - Insert Lead` into two parallel branches: the existing HubSpot branch (unblocked, still drives the webhook response) and a new `Execute Workflow - Enrichment Orchestrator` branch (fire-and-forget from the response's point of view). The orchestrator itself runs the three sub-workflows **sequentially** (Website Scraper → Tech Stack Detector → News RSS) because Tech Stack Detector's `no_html` skip depends on `enrichment.website.raw_artifacts` already being written to Supabase by Website Scraper — parallelizing would race that dependency. News RSS has no such dependency but sequential is explicitly acceptable per the issue, and keeps the workflow to a single linear chain with no Merge node (avoiding the "node succeeds with zero output items" class of n8n gotcha already documented from #21).

**Tech Stack:** n8n (self-hosted, Docker on Hetzner), Supabase Postgres, existing sub-workflow JSONs in `n8n/workflows/`.

## Global Constraints

- Config-driven everything — no hardcoded tenant values (N/A for this issue, no new tenant-specific values introduced).
- No schema changes without a migration file (`supabase/migrations/`).
- No silent failures — every workflow gets an error path that alerts; this issue's whole point is wiring the real alert path through actual orchestration (retiring the #21/#22 harness workaround).
- n8n workflows must be re-exported to `n8n/workflows/` after every live change (Download from "..." menu, or CLI `export:workflow`) — restorable from repo.
- Secrets only in env; `.env.example` stays current (no new env vars expected this issue).
- Commits: small, imperative mood, reference `#23`.
- Legal data sources only (N/A — no new data source in this issue).
- Sprint 2 closes today (2026-07-17) per LOG.md — #24/#25 roll to Sprint 3 per the slip rule. Do not start them. Do not rush this issue's verification to squeeze them in.

## Existing IDs referenced throughout (from already-exported workflow JSON — do not re-guess these)

- Website Scraper workflow id: `pM7mW9mH5nC6nyIz`
- Tech Stack Detector workflow id: `KJwL27hbsuZ6ewng`
- News RSS workflow id: `BQ8Ye9wBJBjSpCgL`
- Lead Intake workflow id: `ql9dgCIrIKvVeukr`
- Lead Intake - Error Alert workflow id: `Yl0d71QmNV63K9MI`
- Supabase Leads credential id: `4pPsx2sAVgrzJm5n`
- New Enrichment Orchestrator workflow id (freshly minted for this issue, arbitrary 16-char alphanumeric — n8n doesn't validate the shape on create, same as #22's precedent): `eOrcH3strAt0r01a`

---

### Task 1: Migration for `enrichment_duration_ms`

**Files:**
- Create: `supabase/migrations/20260717120000_add_enrichment_duration_ms.sql`

**Interfaces:**
- Produces: `leads.enrichment_duration_ms` (integer, nullable), set by the orchestrator on every run (success or all-failed) so Sprint 4's latency dashboard has a persisted baseline, not just an n8n execution-log number that scrolls away.

- [ ] **Step 1: Write the migration**

```sql
-- Issue #23: enrichment orchestration wall-clock duration, in milliseconds.
-- Set on every orchestration run regardless of outcome (feeds Sprint 4's latency baseline).
alter table leads add column enrichment_duration_ms integer;
```

- [ ] **Step 2: Apply the migration to the Supabase project**

Run (adjust to however prior migrations in this repo were applied — no Supabase CLI is installed per this project's known constraint; use the Supabase SQL editor or whatever mechanism `20260713184208_add_enriched_at.sql` was applied with):

```bash
cat supabase/migrations/20260717120000_add_enrichment_duration_ms.sql
```

Paste the SQL into the Supabase project's SQL editor and run it. Confirm with a read-only check:

```sql
select column_name, data_type from information_schema.columns
where table_name = 'leads' and column_name = 'enrichment_duration_ms';
```
Expected: one row, `enrichment_duration_ms | integer`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260717120000_add_enrichment_duration_ms.sql
git commit -m "feat(#23): add leads.enrichment_duration_ms column"
```

---

### Task 2: Author the `Enrichment Orchestrator` workflow JSON

**Files:**
- Create: `n8n/workflows/enrichment-orchestrator.json`

**Interfaces:**
- Consumes: Execute Workflow Trigger input `{ id }` (a `leads.id` uuid) — same passthrough convention as #20/#21/#22.
- Produces: writes `leads.status`, `leads.enriched_at`, `leads.enrichment_duration_ms` directly (not `enrichment` — the three sub-workflows already own writing their own `enrichment.*` keys). Does not touch `enrichment` itself.
- Alert semantics (a judgment call made here, not left implicit — record it in Task 5's DECISIONS.md entry): "all enrichment failed" is read broadly as **none of the three components reached `ok`/`partial`** (covers a mix of `failed`+`skipped` too, e.g. no-domain-and-no-company), not literally "all three `status === 'failed'`". This matches the RUNBOOK's own framing ("an entirely unenrichable lead") and CLAUDE.md's no-silent-failures rule better than the narrower literal reading — a lead that's all `skipped`+`failed` with zero real data is exactly as unenrichable as one that's all `failed`.

- [ ] **Step 1: Write the workflow JSON**

```json
{
  "name": "Enrichment Orchestrator",
  "nodes": [
    {
      "parameters": {
        "inputSource": "passthrough"
      },
      "id": "a1b1c1d1-0001-4001-8001-000000000001",
      "name": "When Executed by Another Workflow",
      "type": "n8n-nodes-base.executeWorkflowTrigger",
      "typeVersion": 1.1,
      "position": [-1440, 160]
    },
    {
      "parameters": {
        "jsCode": "return [{ json: { id: $json.id, startedAtMs: Date.now() } }];"
      },
      "id": "a1b1c1d1-0002-4001-8001-000000000002",
      "name": "Record Start Time",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [-1216, 160]
    },
    {
      "parameters": {
        "workflowId": {
          "__rl": true,
          "value": "pM7mW9mH5nC6nyIz",
          "mode": "list",
          "cachedResultUrl": "/workflow/pM7mW9mH5nC6nyIz",
          "cachedResultName": "Website Scraper"
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
      "id": "a1b1c1d1-0003-4001-8001-000000000003",
      "name": "Execute Workflow - Website Scraper",
      "type": "n8n-nodes-base.executeWorkflow",
      "typeVersion": 1.2,
      "position": [-992, 160]
    },
    {
      "parameters": {
        "jsCode": "return [{ json: { id: $('Record Start Time').item.json.id } }];"
      },
      "id": "a1b1c1d1-0004-4001-8001-000000000004",
      "name": "Reset ID After Website",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [-768, 160]
    },
    {
      "parameters": {
        "workflowId": {
          "__rl": true,
          "value": "KJwL27hbsuZ6ewng",
          "mode": "list",
          "cachedResultUrl": "/workflow/KJwL27hbsuZ6ewng",
          "cachedResultName": "Tech Stack Detector"
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
      "id": "a1b1c1d1-0005-4001-8001-000000000005",
      "name": "Execute Workflow - Tech Stack Detector",
      "type": "n8n-nodes-base.executeWorkflow",
      "typeVersion": 1.2,
      "position": [-544, 160]
    },
    {
      "parameters": {
        "jsCode": "return [{ json: { id: $('Record Start Time').item.json.id } }];"
      },
      "id": "a1b1c1d1-0006-4001-8001-000000000006",
      "name": "Reset ID After Tech Stack",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [-320, 160]
    },
    {
      "parameters": {
        "workflowId": {
          "__rl": true,
          "value": "BQ8Ye9wBJBjSpCgL",
          "mode": "list",
          "cachedResultUrl": "/workflow/BQ8Ye9wBJBjSpCgL",
          "cachedResultName": "News RSS"
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
      "id": "a1b1c1d1-0007-4001-8001-000000000007",
      "name": "Execute Workflow - News RSS",
      "type": "n8n-nodes-base.executeWorkflow",
      "typeVersion": 1.2,
      "position": [-96, 160]
    },
    {
      "parameters": {
        "operation": "get",
        "tableId": "leads",
        "filters": {
          "conditions": [
            {
              "keyName": "id",
              "keyValue": "={{ $('Record Start Time').item.json.id }}"
            }
          ]
        }
      },
      "id": "a1b1c1d1-0008-4001-8001-000000000008",
      "name": "Supabase - Get Lead",
      "type": "n8n-nodes-base.supabase",
      "typeVersion": 1,
      "position": [128, 160],
      "credentials": {
        "supabaseApi": {
          "id": "4pPsx2sAVgrzJm5n",
          "name": "Supabase Leads"
        }
      }
    },
    {
      "parameters": {
        "jsCode": "const row = $json;\nconst enrichment = row.enrichment || {};\nconst website = enrichment.website || {};\nconst techStack = enrichment.tech_stack || {};\nconst news = enrichment.news || {};\n\nconst okStatuses = new Set(['ok', 'partial']);\nconst anyOk = [website, techStack, news].some((c) => okStatuses.has(c.status));\n\nconst startedAtMs = $('Record Start Time').item.json.startedAtMs;\nconst durationMs = Date.now() - startedAtMs;\n\nreturn [{\n  json: {\n    id: row.id,\n    anyOk,\n    durationMs\n  }\n}];"
      },
      "id": "a1b1c1d1-0009-4001-8001-000000000009",
      "name": "Compute Overall Status",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [352, 160]
    },
    {
      "parameters": {
        "conditions": {
          "options": {
            "caseSensitive": true,
            "leftValue": "",
            "typeValidation": "strict",
            "version": 2
          },
          "conditions": [
            {
              "id": "cond-any-ok",
              "leftValue": "={{ $json.anyOk }}",
              "rightValue": true,
              "operator": {
                "type": "boolean",
                "operation": "true",
                "singleValue": true
              }
            }
          ],
          "combinator": "and"
        },
        "options": {}
      },
      "id": "a1b1c1d1-0010-4001-8001-000000000010",
      "name": "Any Component OK?",
      "type": "n8n-nodes-base.if",
      "typeVersion": 2.2,
      "position": [576, 160]
    },
    {
      "parameters": {
        "operation": "update",
        "tableId": "leads",
        "filters": {
          "conditions": [
            {
              "keyName": "id",
              "condition": "eq",
              "keyValue": "={{ $json.id }}"
            }
          ]
        },
        "fieldsUi": {
          "fieldValues": [
            {
              "fieldId": "status",
              "fieldValue": "enriched"
            },
            {
              "fieldId": "enriched_at",
              "fieldValue": "={{ new Date().toISOString() }}"
            },
            {
              "fieldId": "enrichment_duration_ms",
              "fieldValue": "={{ $json.durationMs }}"
            }
          ]
        }
      },
      "id": "a1b1c1d1-0011-4001-8001-000000000011",
      "name": "Supabase - Mark Enriched",
      "type": "n8n-nodes-base.supabase",
      "typeVersion": 1,
      "position": [800, 64],
      "credentials": {
        "supabaseApi": {
          "id": "4pPsx2sAVgrzJm5n",
          "name": "Supabase Leads"
        }
      }
    },
    {
      "parameters": {
        "operation": "update",
        "tableId": "leads",
        "filters": {
          "conditions": [
            {
              "keyName": "id",
              "condition": "eq",
              "keyValue": "={{ $json.id }}"
            }
          ]
        },
        "fieldsUi": {
          "fieldValues": [
            {
              "fieldId": "enrichment_duration_ms",
              "fieldValue": "={{ $json.durationMs }}"
            }
          ]
        }
      },
      "id": "a1b1c1d1-0012-4001-8001-000000000012",
      "name": "Supabase - Record Duration Only",
      "type": "n8n-nodes-base.supabase",
      "typeVersion": 1,
      "position": [800, 288],
      "credentials": {
        "supabaseApi": {
          "id": "4pPsx2sAVgrzJm5n",
          "name": "Supabase Leads"
        }
      }
    },
    {
      "parameters": {
        "errorMessage": "=Enrichment Orchestrator: lead {{ $json.id }} finished with no usable enrichment (website/tech_stack/news all came back failed or skipped). leads.status remains 'raw', replayable after investigating the underlying cause."
      },
      "id": "a1b1c1d1-0013-4001-8001-000000000013",
      "name": "Fail Execution - All Enrichment Failed",
      "type": "n8n-nodes-base.stopAndError",
      "typeVersion": 1,
      "position": [1024, 288]
    }
  ],
  "pinData": {},
  "connections": {
    "When Executed by Another Workflow": {
      "main": [[{ "node": "Record Start Time", "type": "main", "index": 0 }]]
    },
    "Record Start Time": {
      "main": [[{ "node": "Execute Workflow - Website Scraper", "type": "main", "index": 0 }]]
    },
    "Execute Workflow - Website Scraper": {
      "main": [[{ "node": "Reset ID After Website", "type": "main", "index": 0 }]]
    },
    "Reset ID After Website": {
      "main": [[{ "node": "Execute Workflow - Tech Stack Detector", "type": "main", "index": 0 }]]
    },
    "Execute Workflow - Tech Stack Detector": {
      "main": [[{ "node": "Reset ID After Tech Stack", "type": "main", "index": 0 }]]
    },
    "Reset ID After Tech Stack": {
      "main": [[{ "node": "Execute Workflow - News RSS", "type": "main", "index": 0 }]]
    },
    "Execute Workflow - News RSS": {
      "main": [[{ "node": "Supabase - Get Lead", "type": "main", "index": 0 }]]
    },
    "Supabase - Get Lead": {
      "main": [[{ "node": "Compute Overall Status", "type": "main", "index": 0 }]]
    },
    "Compute Overall Status": {
      "main": [[{ "node": "Any Component OK?", "type": "main", "index": 0 }]]
    },
    "Any Component OK?": {
      "main": [
        [{ "node": "Supabase - Mark Enriched", "type": "main", "index": 0 }],
        [{ "node": "Supabase - Record Duration Only", "type": "main", "index": 0 }]
      ]
    },
    "Supabase - Record Duration Only": {
      "main": [[{ "node": "Fail Execution - All Enrichment Failed", "type": "main", "index": 0 }]]
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
  "versionId": "00000000-0000-4000-8000-000000000001",
  "meta": {
    "instanceId": "68dc6225d3bd91f509f1622e5bc9ca13d6bb79e6e162b7d2abe02d53fb814dcd"
  },
  "nodeGroups": [],
  "id": "eOrcH3strAt0r01a",
  "tags": []
}
```

- [ ] **Step 2: Deploy via the CLI path documented from #22 (no editor/browser access assumed)**

```bash
scp n8n/workflows/enrichment-orchestrator.json <vps-host>:/tmp/enrichment-orchestrator.json
ssh <vps-host> "docker cp /tmp/enrichment-orchestrator.json n8n-n8n-1:/tmp/enrichment-orchestrator.json"
ssh <vps-host> "docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/enrichment-orchestrator.json"
ssh <vps-host> "docker exec n8n-n8n-1 n8n publish:workflow --id=eOrcH3strAt0r01a"
ssh <vps-host> "docker compose -f ~/n8n/docker-compose.yml restart n8n"
ssh <vps-host> "docker logs n8n-n8n-1 --tail 20"
```
Expected: import succeeds (no `SQLITE_CONSTRAINT` error — the JSON already has a top-level `id`), publish succeeds, restart log shows `Enrichment Orchestrator` in the "Activated workflow" list.

- [ ] **Step 3: Confirm the Error Workflow setting round-tripped**

```bash
ssh <vps-host> "docker exec n8n-n8n-1 n8n export:workflow --id=eOrcH3strAt0r01a --output=/tmp/eo-export.json"
ssh <vps-host> "docker exec n8n-n8n-1 cat /tmp/eo-export.json" | grep -A1 errorWorkflow
```
Expected: `"errorWorkflow": "Yl0d71QmNV63K9MI"` present.

- [ ] **Step 4: Manual verification — happy path via Execute Workflow test**

Pick an existing `leads.id` from an earlier issue's verification (a real domain + company lead, e.g. one of the Stripe test leads from #20–#22). In the n8n editor's "Execute Workflow" test button on `Enrichment Orchestrator` (or, if no editor access, temporarily point a throwaway harness workflow at it the same way #22 did — see Task 4, which builds the real, permanent trigger anyway so a temporary harness may not even be needed here): supply `{ "id": "<that lead id>" }`.

Expected in Supabase after the run: `leads.status = 'enriched'`, `leads.enriched_at` set to a recent timestamp, `leads.enrichment_duration_ms` a plausible positive integer (roughly matching total scrape+fingerprint+RSS time, likely several seconds to under a minute).

- [ ] **Step 5: Commit**

```bash
git add n8n/workflows/enrichment-orchestrator.json
git commit -m "feat(#23): add Enrichment Orchestrator workflow composing #20/#21/#22"
```

---

### Task 3: Wire `Lead Intake` to trigger the orchestrator

**Files:**
- Modify: `n8n/workflows/lead-intake.json`

**Interfaces:**
- Consumes: `Enrichment Orchestrator` workflow id `eOrcH3strAt0r01a` (from Task 2).
- Produces: a parallel branch off `Supabase - Insert Lead` that does not feed into `Respond 200 - OK`, so the webhook response latency is unaffected by enrichment's up-to-45s budget.

- [ ] **Step 1: Add the new node to the nodes array**

Insert this object into `n8n/workflows/lead-intake.json`'s `"nodes"` array (position picked to sit below the existing HubSpot branch, e.g. `[-224, 240]`):

```json
{
  "parameters": {
    "workflowId": {
      "__rl": true,
      "value": "eOrcH3strAt0r01a",
      "mode": "list",
      "cachedResultUrl": "/workflow/eOrcH3strAt0r01a",
      "cachedResultName": "Enrichment Orchestrator"
    },
    "workflowInputs": {
      "mappingMode": "defineBelow",
      "value": {},
      "matchingColumns": [],
      "schema": [],
      "attemptToConvertTypes": false,
      "convertFieldsToString": true
    },
    "options": {
      "waitForSubWorkflow": false
    }
  },
  "id": "b2c2d2e2-0001-4002-8002-000000000001",
  "name": "Execute Workflow - Enrichment Orchestrator",
  "type": "n8n-nodes-base.executeWorkflow",
  "typeVersion": 1.2,
  "position": [-224, 240]
}
```

**Verified against the live n8n image** (`n8n-nodes-base@2.28.3`, `ExecuteWorkflow.node.js`, confirmed via `docker exec` on the VPS, not assumed from n8n docs): the option is `options.waitForSubWorkflow` (boolean, default `true`). When `false`, the node calls `executeWorkflow` with `doNotWaitToFinish: true` and returns `[items]` immediately without waiting for the sub-workflow's result — this makes the branch genuinely fire-and-forget rather than relying on "unconnected branches don't block the Respond node" (true in this n8n version too, but redundant belt-and-suspenders here is cheap and removes any doubt). Do **not** rely on graph topology alone for this guarantee — set the option explicitly.

- [ ] **Step 2: Fan out `Supabase - Insert Lead`'s connection to include the new node**

Change this in the `"connections"` object:

```json
"Supabase - Insert Lead": {
  "main": [
    [
      { "node": "HubSpot - Create Contact", "type": "main", "index": 0 }
    ]
  ]
},
```

to:

```json
"Supabase - Insert Lead": {
  "main": [
    [
      { "node": "HubSpot - Create Contact", "type": "main", "index": 0 },
      { "node": "Execute Workflow - Enrichment Orchestrator", "type": "main", "index": 0 }
    ]
  ]
},
```

Do **not** add a connection from the new node onward — it's a dead-end branch by design, so `Respond 200 - OK` only ever waits on the HubSpot chain.

- [ ] **Step 3: Deploy via CLI**

```bash
scp n8n/workflows/lead-intake.json <vps-host>:/tmp/lead-intake.json
ssh <vps-host> "docker cp /tmp/lead-intake.json n8n-n8n-1:/tmp/lead-intake.json"
ssh <vps-host> "docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/lead-intake.json"
ssh <vps-host> "docker exec n8n-n8n-1 n8n publish:workflow --id=ql9dgCIrIKvVeukr"
ssh <vps-host> "docker compose -f ~/n8n/docker-compose.yml restart n8n"
```
Note: this re-imports over the existing `Lead Intake` workflow (same `id`), so credentials should re-link automatically the same way #22 documented for News RSS's re-import — confirm in Step 4 below rather than assuming.

- [ ] **Step 4: Confirm credentials survived re-import**

```bash
ssh <vps-host> "docker exec n8n-n8n-1 n8n export:workflow --id=ql9dgCIrIKvVeukr --output=/tmp/li-export.json"
ssh <vps-host> "docker exec n8n-n8n-1 cat /tmp/li-export.json" | grep -B2 -A2 credentials
```
Expected: `Supabase - Insert Lead`, `Supabase - Mark Lead Error`, `HubSpot - Create Contact`, `HubSpot - Set Lead Source` all still show their credential blocks (ids `4pPsx2sAVgrzJm5n` / `9PrUwDyFRtzTJ544`). The new `Execute Workflow - Enrichment Orchestrator` node needs no credential of its own (Execute Workflow nodes call other workflows, not external APIs).

- [ ] **Step 5: Smoke-test the webhook still responds fast**

```bash
time curl -X POST https://<N8N_HOST>/webhook/lead-intake -H 'Content-Type: application/json' \
  -d '{"name":"Orchestration Test","email":"orch-test@example.com","company":"Stripe","domain":"stripe.com","source":"curl-test","message":"e2e #23","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
```
Expected: 200 response with `{"status":"ok","id":...}` returned in well under a few seconds (not 45+ seconds) — confirms `waitForSubWorkflow: false` actually works as expected in this n8n version, not just that the graph topology happens to allow it.

- [ ] **Step 6: Commit**

```bash
git add n8n/workflows/lead-intake.json
git commit -m "feat(#23): wire Lead Intake to trigger Enrichment Orchestrator"
```

---

### Task 4: End-to-end production verification (happy path + alert path)

**Files:** none (verification only; may touch Supabase data via test rows, cleaned up after).

- [ ] **Step 1: Happy-path verification — real webhook submission → enriched row**

Using the lead id/execution from Task 3 Step 5 (`orch-test@example.com`, domain `stripe.com`, company `Stripe`), wait ~30–60s for the orchestrator branch to finish, then query Supabase:

```sql
select id, status, enriched_at, enrichment_duration_ms,
       enrichment->'website'->>'status' as website_status,
       enrichment->'tech_stack'->>'status' as tech_stack_status,
       enrichment->'news'->>'status' as news_status
from leads where email = 'orch-test@example.com' order by created_at desc limit 1;
```
Expected: `status = 'enriched'`, `enriched_at` non-null and recent, `enrichment_duration_ms` a plausible positive integer, and `website_status`/`tech_stack_status`/`news_status` all populated (Stripe should come back `ok`/`ok`/`ok` based on #20–#22's own verification history against this exact domain).

- [ ] **Step 2: Alert-path verification — deliberately force an entirely-unenrichable lead**

Submit a lead with an unreachable domain (guarantees `website.status = failed` on every page → cascades to `tech_stack.status = skipped/no_html`) and no company (guarantees `news.status = skipped/no_company`):

```bash
curl -X POST https://<N8N_HOST>/webhook/lead-intake -H 'Content-Type: application/json' \
  -d '{"name":"Alert Path Test","email":"alert-test@example.com","source":"curl-test","domain":"this-domain-does-not-exist-zzqxk.invalid","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
```
(No `company` field — triggers `news`'s `no_company` skip; the bogus domain should fail DNS resolution for every page fetch.)

Wait, then check:

```sql
select id, status, enriched_at, enrichment_duration_ms,
       enrichment->'website'->>'status' as website_status,
       enrichment->'tech_stack'->'reason' as tech_stack_reason,
       enrichment->'news'->'reason' as news_reason
from leads where email = 'alert-test@example.com' order by created_at desc limit 1;
```
Expected: `status = 'raw'` (unchanged), `enriched_at` still null, `enrichment_duration_ms` populated (duration is recorded regardless of outcome), `website_status = 'failed'`, `tech_stack_reason = 'no_html'`, `news_reason = 'no_company'`.

Confirm the execution shows **failed** in n8n's Executions list for `Enrichment Orchestrator`, and confirm the `Lead Intake Pipeline failure - Enrichment Orchestrator` alert email actually arrived — check via the Resend API's own send log (`GET https://api.resend.com/emails`, same method #22 used), not assumed from "no editor access to check inbox":

```bash
curl -s https://api.resend.com/emails -H "Authorization: Bearer $RESEND_API_KEY" | head -c 2000
```
Expected: a recent entry with subject containing `Enrichment Orchestrator` and `to` = Wop's alert address, `last_event` = `delivered` (or `sent`).

This is the "verify the alert path fires through real orchestration, once, deliberately" step that retires the #21/#22 temporary harness workflow pattern — the trigger here is the real `Lead Intake` webhook, not a purpose-built harness.

- [ ] **Step 3: Clean up test data**

```sql
delete from leads where email in ('orch-test@example.com', 'alert-test@example.com');
```
Also delete the corresponding HubSpot test contacts (both leads had emails that passed HubSpot contact creation before the orchestrator branch ran, since the two branches run independently) via the HubSpot UI or API, matching the cleanup precedent from #6/#8's verification notes.

- [ ] **Step 4: No commit this step** (verification only — proceed to Task 5 for the doc updates that record these results).

---

### Task 5: Docs — RUNBOOK, DECISIONS, CLAUDE.md

**Files:**
- Modify: `docs/RUNBOOK.md`
- Modify: `docs/DECISIONS.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add an "Enrichment Orchestrator (#23)" section to `docs/RUNBOOK.md`**, immediately after the "News RSS sub-workflow (#22)" section. Include:
  - The workflow's shape and id (`n8n/workflows/enrichment-orchestrator.json`, id `eOrcH3strAt0r01a`).
  - The sequential-not-parallel rationale (Tech Stack Detector's `no_html` skip reads `enrichment.website.raw_artifacts` from Supabase, which only exists once Website Scraper's own write has landed — parallelizing would race it).
  - The "none ok = alert" semantics decision (link to the DECISIONS.md entry from Step 2).
  - The `Lead Intake` wiring: `Supabase - Insert Lead` fans out to both `HubSpot - Create Contact` and `Execute Workflow - Enrichment Orchestrator` in parallel; the orchestrator branch is a dead end (never reconnects to `Respond 200 - OK`) so the webhook response latency is unaffected by enrichment's up-to-45s budget — record the actual measured response time from Task 3 Step 5.
  - Import/deploy steps (mirror the CLI-only pattern from #22, now the standing pattern for #23 onward per the existing RUNBOOK note).
  - Verification results from Task 4 (happy path + alert path), including the actual `enrichment_duration_ms` values observed and the confirmed Resend delivery for the alert email.
  - Any new gotchas actually hit during live deployment (don't write placeholders — if none were hit, say so plainly rather than inventing one).

- [ ] **Step 2: Add dated entries to `docs/DECISIONS.md`** (use today's date, 2026-07-17), covering at minimum:
  - Sequential (not parallel) sub-workflow ordering in the orchestrator, and why.
  - The broad "none ok/partial across the three components" reading of "all enrichment failed" for the alert trigger, versus the narrower literal "all three status===failed" reading — state which was chosen and why (matches RUNBOOK's own "entirely unenrichable lead" framing from #20; a mixed failed+skipped-with-zero-ok outcome is just as unenrichable as a uniform all-failed one). **Also record the known consequence**: any lead submitted with neither `domain` nor `company` (both `website`/`tech_stack` skip on `no_domain`/`no_html`, `news` skips on `no_company`) will alert on literally every such submission, since nothing ever runs to produce `ok`/`partial` — this is an accepted tradeoff while every current lead source (the intake form, `curl-test`) always supplies at least a company name; if a future source can legitimately submit both fields empty, this alert would need a carve-out, but that's speculative and out of scope for #23.
  - `enrichment_duration_ms` added as a persisted column (not just an n8n execution-log number) specifically to give Sprint 4's latency dashboard a queryable baseline.
  - `Lead Intake`'s fan-out design (parallel dead-end branch, not blocking the webhook response) and the measured before/after response latency.

- [ ] **Step 3: Update `CLAUDE.md`'s "Current status" section** — mark #23 done with a one-line summary in the same style as #19–#22's entries (what was built, what was live-verified, date), move "Now on" to reflect Sprint 2 closing and Sprint 3 not yet started (per the instruction not to start #24/#25 — they roll, undecided sprint start is fine to leave as "Sprint 3 — not yet started, #24/#25 to be re-triaged").

- [ ] **Step 4: Commit**

```bash
git add docs/RUNBOOK.md docs/DECISIONS.md CLAUDE.md
git commit -m "docs(#23): record enrichment orchestration RUNBOOK/DECISIONS, update status"
```

---

### Task 6: Close out

**Files:** none (repo hygiene + GitHub only).

- [ ] **Step 1: Confirm working tree is clean and everything is pushed**

```bash
git status
git push origin main
```

- [ ] **Step 2: Move the issue on the board and close it**

```bash
gh issue close 23 --comment "Closes #23. Enrichment Orchestrator composes Website Scraper → Tech Stack Detector → News RSS sequentially, writes leads.status/enriched_at/enrichment_duration_ms, and alerts via the existing Lead Intake - Error Alert workflow when no component succeeds. Live-verified end-to-end via the real Lead Intake webhook (not a harness): happy path (Stripe lead → status=enriched, all three components ok, duration recorded) and alert path (unreachable domain + no company → status stays raw, alert email confirmed delivered via Resend's own send log)."
```

(If the repo's GitHub Project board doesn't auto-move on issue close, move the card to Done manually.)

- [ ] **Step 3: Do not start #24 or #25.** Sprint 2 closes today; they roll to Sprint 3 per the slip rule already noted in this morning's LOG.md line. Do not edit LOG.md — that's Wop's line to write at the next standup.

---

## Self-Review

**Spec coverage:**
- Intake → three sub-workflows composed, scraper→fingerprint sequential, news sequential (parallel not attempted, per "sequential is fine") — Task 2.
- Merge into `leads.enrichment` per contract — not needed as new work; each sub-workflow already writes its own key, orchestrator only reads the merged result back (Task 2, `Supabase - Get Lead` + `Compute Overall Status`).
- status raw→enriched + enriched_at iff ≥1 component ok/partial — Task 2 (`Any Component OK?` branch).
- all-failed → status stays raw, alert fires — Task 2 (false branch → `Fail Execution` → Error Workflow), verified live in Task 4 Step 2.
- Log wall-clock duration per lead — Task 1 (migration) + Task 2 (`Record Start Time`/`Compute Overall Status`/both Supabase update nodes).
- Retire #21/#22 harness workaround, verify alert path through real orchestration once, deliberately — Task 4 Step 2 (real webhook, not a harness).
- End-to-end verify: form submission → enriched row, populated JSONB, correct status, duration visible — Task 4 Step 1.
- Use CLI deploy path from #22 — Task 2 Step 2, Task 3 Step 3.
- Fresh exports for every touched workflow — Task 2 Step 3 (`export:workflow` confirms orchestrator), Task 3 Step 4 (confirms Lead Intake); committed JSON in both tasks *is* the fresh export target (author locally, deploy, and since these are CLI-imported rather than editor-modified, the committed file is already the source of truth — still worth a final `export:workflow` diff against committed JSON before closing, folded into Task 3 Step 4 and Task 2 Step 3).
- Close with "Closes #23", pushed — Task 6.
- Sprint closes today, don't start #24/#25 — Task 6 Step 3.

**Placeholder scan:** no TBD/TODO markers; every code step has full, runnable code; RUNBOOK/DECISIONS steps direct the author to record *actual* observed values (durations, timestamps) rather than inventing them — that's a live-verification instruction, not a placeholder.

**Type/name consistency:** `id` flows as a plain uuid string throughout every node (`Record Start Time` → `Reset ID After *` → `Supabase - Get Lead` → `Compute Overall Status` → both `Supabase - Mark Enriched`/`Supabase - Record Duration Only`). `durationMs` (camelCase, in-flight n8n field) vs. `enrichment_duration_ms` (snake_case, the actual Postgres column) are consistently distinguished — the Code node produces `durationMs`, the Supabase nodes map it to the `enrichment_duration_ms` field id. `anyOk` is used consistently as the IF node's condition field name.
