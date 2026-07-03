-- Issue #3: leads table, migration-first (see docs/ARCHITECTURE.md, docs/DECISIONS.md)
-- Source of truth for the pipeline. HubSpot is write-only downstream (never read back).

create type lead_status as enum ('raw', 'enriched', 'scored', 'delivered', 'error');

create table leads (
  id uuid primary key default gen_random_uuid(),

  -- intake payload (universal webhook schema: {name, email, company, domain, source, message, timestamp})
  name text not null,
  email text not null,
  company text,
  domain text,
  source text not null,
  message text,
  submitted_at timestamptz not null,

  -- pipeline state
  status lead_status not null default 'raw',

  -- reserved for later sprints: enrichment writes scrape/tech-stack/news results here,
  -- intelligence writes the Claude JSON output (score, reasoning, signals, risks, draft_email) here.
  enrichment jsonb not null default '{}'::jsonb,
  intelligence jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Dedupe strategy (see docs/ARCHITECTURE.md #6): same email+domain within 30 days = UPDATE, not INSERT.
-- Enforcement (the actual upsert logic) lands in the intake workflow in Sprint 2 (issue tracked in backlog);
-- this index only makes the lookup that decision depends on fast.
-- Edge case: same email, different domain (job change) is treated as a new lead — domain is the enrichment key.
create index leads_email_domain_idx on leads (email, domain);

-- updated_at bump on every row change (application code never sets updated_at directly).
create function set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger leads_set_updated_at
  before update on leads
  for each row
  execute function set_updated_at();

-- RLS: enabled with zero policies, so PostgREST/anon and authenticated roles get zero access by default.
-- The service-role key bypasses RLS entirely (Supabase's design), which is the only key n8n/Next.js
-- server-side code will use to read/write this table — never expose it to the browser.
alter table leads enable row level security;
