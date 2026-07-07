import { z } from "zod";

// Domains that identify a personal inbox, not a company — never used as
// the derived company domain (docs: issue #6 acceptance criteria).
const FREE_EMAIL_DOMAINS = new Set([
  "gmail.com",
  "googlemail.com",
  "yahoo.com",
  "hotmail.com",
  "outlook.com",
  "live.com",
  "msn.com",
  "aol.com",
  "icloud.com",
  "me.com",
  "protonmail.com",
  "proton.me",
  "mail.com",
  "gmx.com",
  "yandex.com",
  "zoho.com",
  "hey.com",
  "fastmail.com",
]);

const DOMAIN_REGEX = /^(?!-)[a-z0-9-]+(\.[a-z0-9-]+)+$/i;

export const leadFormSchema = z.object({
  name: z.string().trim().min(1, "Name is required").max(200),
  email: z.email("Enter a valid email address").trim().max(320),
  company: z.string().trim().max(200).optional().or(z.literal("")),
  domain: z
    .string()
    .trim()
    .toLowerCase()
    .regex(DOMAIN_REGEX, "Enter a valid domain, e.g. acme.com")
    .max(253)
    .optional()
    .or(z.literal("")),
  message: z.string().trim().max(5000).optional().or(z.literal("")),
});

export type LeadFormInput = z.infer<typeof leadFormSchema>;

export interface LeadIntakePayload {
  name: string;
  email: string;
  company: string | null;
  domain: string | null;
  source: "website_form";
  message: string | null;
  timestamp: string;
}

// Free-mail domains never become the "company domain" — leave it null so
// enrichment doesn't try to scrape gmail.com as if it were the prospect's site.
export function deriveDomain(email: string, providedDomain?: string): string | null {
  const explicit = providedDomain?.trim().toLowerCase();
  if (explicit) return explicit;

  const emailDomain = email.split("@")[1]?.toLowerCase();
  if (!emailDomain || FREE_EMAIL_DOMAINS.has(emailDomain)) return null;
  return emailDomain;
}

export function buildLeadIntakePayload(input: LeadFormInput): LeadIntakePayload {
  return {
    name: input.name,
    email: input.email,
    company: input.company || null,
    domain: deriveDomain(input.email, input.domain),
    source: "website_form",
    message: input.message || null,
    timestamp: new Date().toISOString(),
  };
}
