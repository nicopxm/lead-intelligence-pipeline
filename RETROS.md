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