-- Issue #24: dedupe lookup at intake now queries "domain = X" on its own when the
-- incoming lead has a domain (see docs/ARCHITECTURE.md #6 — domain takes priority
-- over email as the matching key). The existing leads_email_domain_idx (email, domain)
-- has email as its leading column, so it can't serve a domain-only WHERE efficiently.
create index leads_domain_idx on leads (domain) where domain is not null;
