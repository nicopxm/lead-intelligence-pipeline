2026-07-02 — Sprint 1 runs Jul 2–10 (first sprint absorbs setup).
2026-07-02 — Supabase = source of truth; HubSpot write-only downstream. Why: we control the Postgres schema and query it freely for dashboard/metrics; HubSpot Free's API limits and rigid data model make it a poor primary store. Also keeps the pipeline CRM-agnostic (Phase 2 client could use a different CRM — only the delivery layer changes).
2026-07-02 — Budget: ~€5/mo Hetzner + ~$10 domain + ~$5-15 Claude API total. Rejected Oracle free tier (reliability risk) and going domainless (breaks Resend + demo credibility). Cost target is $/lead measured, not $0 spend.
2026-07-02 — Domain: nicopxm.me via Porkbun (at-cost, free WHOIS privacy, DNS colocated). n8n at n8n.<yourdomain>; root domain reserved for intake form + Resend sender identity.
2026-07-02 — Considered Railway over Hetzner VPS. Rejected: usage pricing punishes always-on n8n, and self-hosted VPS ops is a deliberate portfolio asset (issue #2 runbook = interview material). Hetzner stands.

