## Sprint 1 Retro — 2026-07-10 (Jul 2–8, closed 2 days early, 10 issues)

What worked:
- The two surface system caught real failures on both sides: Claude Code halted a missing .gitignore before secrets existed, self-reported its own `cat .env` violation, and flagged live-workflow drift before closing #7. Verification kept producing findings to the last issue (credential-edit ≠ republish; demo rehearsal caught two display gaps).

What didn't:
- Every process failure was a prose rule losing to friction: paste-mangled script (30 min), two secret echoes, workflow drift, and LOG.md itself (duplicated/missing entries — batch-written, no enforcement hook). Rules that stuck were the ones embedded structurally: check-env.sh, export-in-DoD, files-not-text.

One change next sprint:
- Process failures get structural fixes, never reminders: any repeated mistake must end as a script, a DoD line, or a CLAUDE.md "Don't" — in the same session it's caught. First application: LOG.md gets an enforcement hook — the daily line is written at session start in Claude Code (it prompts if missing), not from memory later.

## Sprint 2 Retro — 2026-07-17 (Jul 13–17; goal MET, 5/7 issues, #24/#25 rolled to S3)

What worked:
- Sub-workflow composability paid off exactly as designed: #20–#22 were independently verified before #23 touched them, so orchestration really was composition. The CLI-only deploy path (established under duress in #22) became the standing, scriptable way to ship n8n changes.
- Verification discipline compounded: every "it works" claim was checked against a real artifact (Supabase row, execution event, Resend send-log) — which caught two live orchestration bugs in #23 before any production lead was touched. An unrelated regression (#26) was filed, not fixed mid-task. Sprint 1's structural fixes held (LOG hook fired on day 2; export-in-DoD kept repo and live in sync).

What didn't:
- A component broke silently between issues: Tech Stack Detector's config-read regressed after #21's verification and sat undetected ~5 days until #23 tripped on it — nothing re-checks a closed issue's running dependencies. Relatedly, composing closed workflows surfaced n8n-runtime failure modes (error propagation across Execute Workflow, zero-output truncation) invisible in the JSON — expect composition to be real work, not assembly.
- A 2-day mid-sprint stall (Jul 15–16) ate all slack; contributing: the Clay side project launched on the sprint's highest-momentum evening. The goal issue (#23) was queued last, so the stall's cost was invisible until the final day.

One change next sprint:
- Any issue that leaves a running dependency behind (config mount, credential, external API assumption) gets one cheap scheduled re-verification a few days after close — #26 would have surfaced in hours, not days. (Planning practice, not a rule: the sprint's goal issue gets a named target day mid-sprint, written into the plan, so a stall shows as a missed date rather than silent drift.)

## Sprint 3 Retro — 2026-07-23 (Jul 20–23; goal MET, 5/5 committed issues closed — #26/#24/#28/#29/#30, plus umbrella #9; #30 closed with its human tier-agreement AC explicitly deferred to Sprint 4; 4 bugs filed to Backlog, not fixed — #34/#35/#36/#37)

What worked:
- The two-surface split held under pressure, unprompted. Claude Code hit the null-domain bug mid-verification and stopped to surface it as an architecture question rather than fixing under momentum — exactly what CLAUDE.md instructs, on the one day when fixing it would have felt faster. It also self-corrected its own "board auto-add failed 3 for 3" framing to "1 of 3, cause unconfirmed" during the investigation, filing both findings honestly rather than forcing one explanation.
- Verification produced findings to the last hour — and the last one came from the demo dry run. #29's forced malformed-response test, then #30's three batches surfacing the competitor over-trigger, the disqualifier drift, fabricated headcounts, and a latent ICP ambiguity. The competitor bug alone would have shipped straight into Sprint 4's hot alerts; a scorer that zeroes good leads makes the alert layer worthless.
- Cost became measured, not aspirational. 33 scored leads: median $0.0095, max $0.0150, 100% under target — and the max is bounded by design (#20's 4,000-char cap, #22's 5-item news cap), not by luck. #29's $0.007 headline turned out to be a sparse-lead outlier; correcting our own claim downward is worth more than the original number.

What didn't:
- Three separate bugs, one root cause: the config says what to score, never where the boundaries are or how to weigh evidence. scoring_dimensions carry key, weight, ideal, and notes; hard_disqualifiers are four bare English phrases with no definition and no validation. icp_description says "B2B companies" while its funding language implies tech-only. Nothing anywhere says a lead's self-report is weaker than a detected fact. The model filled every gap — inventing "not B2B SaaS" as a disqualifier (#35), asserting headcounts absent from the data (#36), reading a scoring ideal as a hard gate. Config-as-data only beats prose-in-a-prompt if the data is actually specified; ours was half-specified and the unspecified half is where all three bugs live.
- The spot-check took three batches and still produced no usable weight data. Each failed differently: batch 1 had zero tier variance (competitor over-trigger), batch 2 was anchored (pipeline scores seen before judging), batch 3 was off-ICP and gate-capped on 7 of 12. Two of three were preventable by writing the protocol before running the batch instead of after. The protocol now exists in RUNBOOK, written from the failures.
- An accepted tradeoff silently changed severity, and a requirement vanished with its container. #23 documented "leads with no domain and no company alert on every submission" as acceptable when the cost was a spurious email; #29 wired scoring to that same anyOk branch and converted it into lead loss, unnoticed. Separately, Sprint 2's review recording lived on #25's acceptance criteria — #25 was superseded by #30 and the requirement disappeared with it, noticed only today, incidentally. Same shape as #37's board-Status gap: recorded in one place, silently dropped when the container moved.

One change next sprint:
- Before attaching a new consumer to an existing branch, gate, status field, or config field, re-read what it actually means and confirm its previously-accepted costs still hold. Structural per the never-a-reminder rule: a CLAUDE.md DoD line — "If this issue consumes an existing branch, gate, status field, or config value, name the decision that accepted its current behavior and confirm that acceptance still holds under the new consumer." #34 would have surfaced at #29's design stage rather than two sprints later, and #25's superseding would have flagged its orphaned recording AC.