## Sprint 1 Retro — 2026-07-10 (Jul 2–8, closed 2 days early, 10 issues)

What worked:
- The two surface system caught real failures on both sides: Claude Code halted a missing .gitignore before secrets existed, self-reported its own `cat .env` violation, and flagged live-workflow drift before closing #7. Verification kept producing findings to the last issue (credential-edit ≠ republish; demo rehearsal caught two display gaps).

What didn't:
- Every process failure was a prose rule losing to friction: paste-mangled script (30 min), two secret echoes, workflow drift, and LOG.md itself (duplicated/missing entries — batch-written, no enforcement hook). Rules that stuck were the ones embedded structurally: check-env.sh, export-in-DoD, files-not-text.

One change next sprint:
- Process failures get structural fixes, never reminders: any repeated mistake must end as a script, a DoD line, or a CLAUDE.md "Don't" — in the same session it's caught. First application: LOG.md gets an enforcement hook — the daily line is written at session start in Claude Code (it prompts if missing), not from memory later.