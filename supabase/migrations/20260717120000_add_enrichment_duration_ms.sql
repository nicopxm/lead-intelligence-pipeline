-- Issue #23: enrichment orchestration wall-clock duration, in milliseconds.
-- Set on every orchestration run regardless of outcome (feeds Sprint 4's latency baseline).
alter table leads add column enrichment_duration_ms integer;
