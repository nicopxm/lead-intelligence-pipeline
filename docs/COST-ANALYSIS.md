# Cost per lead: v1 → v2

Sprint 5's #44 regression accidentally became a controlled A/B. Five retained fixture leads — Raycast, Framer, Photoroom, Sanity, Superhuman — got scored twice, six weeks apart, once under each prompt version. I pulled both sets of numbers straight from production and lined them up.

Total cost across the five went from $0.0560 (v1) to $0.0766 (v2), a 1.37x increase. Almost all of that is output tokens, not input: input only grew 1.13x, output grew 1.68x. That split makes sense once you remember Haiku prices output at 5x input — a token that moves from "not generated" to "generated" costs five times what a token moving from "not read" to "read" does.

## Per-lead breakdown

| Company | v1 tokens (in/out) | v1 cost | v2 tokens (in/out) | v2 cost | Δ cost | Δ % |
|---|---|---|---|---|---|---|
| Raycast | 5,390 / 1,128 | $0.0110 | 6,681 / 1,729 | $0.0153 | +$0.0043 | +38.9% |
| Framer | 6,820 / 961 | $0.0116 | 8,135 / 1,777 | $0.0170 | +$0.0054 | +46.4% |
| Photoroom | 6,287 / 993 | $0.0113 | 6,274 / 1,572 | $0.0141 | +$0.0029 | +25.6% |
| Sanity | 6,767 / 1,151 | $0.0125 | 7,936 / 1,507 | $0.0155 | +$0.0029 | +23.6% |
| Superhuman | 6,848 / 552 | $0.0096 | 7,237 / 1,473 | $0.0146 | +$0.0050 | +52.0% |
| **Total** | 32,112 / 4,785 | **$0.0560** | 36,263 / 8,058 | **$0.0766** | +$0.0205 | +36.6% |

All five stay under the $0.02/lead ceiling. The worst single lead is Framer at $0.0170 — about 15% of headroom left under the cap, down from roughly 25% under v1. That's the number I'd watch if the prompt grows again.

## What actually changed, and why it's worth the extra cost

v1 disqualified all five of these leads on sight — Raycast, Framer, and Sanity as "obvious competitor," Superhuman the same, Photoroom on a headcount call — and skipped the draft for every one, since v1 never drafts for a disqualified lead. Under v2, with #44's code-list disqualifier replacing the model's own competitor judgment, none of these five auto-disqualify on name recognition anymore: Raycast scores hot, Framer scores review, Sanity scores nurture. All three now carry a real draft email. Photoroom and Superhuman still land in discard, but on their actual scored dimensions, not a competitor guess.

That's what the cost increase buys. v2 grounds every score with evidence and reasoning before it commits to a verdict, requires a source quote for any headcount claim, and drafts unconditionally instead of pre-judging and skipping. #36's fabricated-fact bugs — invented headcounts, invented second entities — don't reproduce anymore because the model has to show its work before it gets to a verdict. Three of five fixtures that v1 silently threw away now get scored on their merits, and three of them now generate a draft that never existed before. A wrongly-discarded hot lead costs a lot more than the extra $0.003–0.005/lead. Grounding over cost is the right trade here.

## What keeps this bounded

None of this is open-ended, and that's by design, not luck:

- **Enrichment input is capped at the scrape.** `website-scraper-fetch-page.json` truncates each page to 4,000 characters (`CHAR_CAP = 4000`) across up to 3 pages (home/about/pricing) — a hard ceiling on how much scraped text can ever reach the prompt, no matter how verbose the target site is (#20).
- **News is capped at 5 items.** `news-rss.json` sorts by recency and slices to the top 5 (`.slice(0, 5)`) before anything gets attached to the lead record (#22).
- **One Haiku call per lead, retry only on failure.** The scorer calls Claude once. A second attempt fires only when the first response fails schema validation — a clean run, which is nearly all of them, never pays for a retry.

Cost is a function of enrichment richness, not model verbosity or an open-ended prompt. The ceiling is set by what we chose to scrape, not by what the model decides to write.

## Cost and latency together

The unit economics story isn't just "under 2 cents a lead." #42's end-to-end verification measured a real hot lead going form-submit to `delivered` in ~34 seconds — well inside the 90-second target — using the same v2 scoring that produces the $0.014–$0.017 range above. Fast and cheap together is the actual claim; a slow cheap pipeline or a fast expensive one wouldn't tell the same story.

## Methodology note

v1 and v2 both trace to the same five Supabase lead rows, but only v1 survived in `leads.intelligence`. The 2026-08-03 regression resubmitted these leads inside the 30-day dedupe window, so #24's dedupe gate updated intake fields (hence the `updated_at` bump on all five rows) without re-running the Intelligence Scorer — the v1 blob was never overwritten. I pulled the v2 numbers from n8n's own execution store instead: the `execution_data` table for workflow `intelScorer0001a`, 8 executions between 23:16–23:17 on 2026-08-03, still intact and un-purged. Read directly via `docker exec` and n8n's bundled `sqlite3`/`flatted` packages, read-only, nothing modified. Every number above is the model's own reported `usage.input_tokens` / `usage.output_tokens`, not a re-derivation.

One correction to the record while I was in there: #44's closing note cited Superhuman ($0.01460) as the worst-case v2 cost. The actual worst case in this dataset is Framer at $0.01702 — still under $0.02, but worth fixing in the citation trail.
