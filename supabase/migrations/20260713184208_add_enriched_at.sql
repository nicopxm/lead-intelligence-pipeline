-- Issue #19: enrichment scaffolding (see docs/ARCHITECTURE.md "Enrichment record contract").
-- Marks when enrichment orchestration finished writing leads.enrichment, regardless of
-- whether individual steps came back ok/partial/failed/skipped.

alter table leads add column enriched_at timestamptz;
