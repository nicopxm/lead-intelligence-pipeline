-- Issue #40: persist the HubSpot contact id returned at create time (the `vid` field
-- from the legacy-shaped Create/Update Contact response), so the Intelligence Scorer's
-- HubSpot delivery step can write score/summary/note back to the same contact without
-- ever reading HubSpot back — keeps the write-only-downstream principle from
-- 20260703163152_create_leads.sql intact.
--
-- No uniqueness constraint: per #24's accepted job-change asymmetry, two `leads` rows
-- (different domains, same person) can share one HubSpot contact id.
alter table leads add column hubspot_contact_id text;
