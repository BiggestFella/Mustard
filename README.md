# Mustard

A native macOS command centre that plans your day and your AI agents' day together.
Spec: "Personal Productivity Tool — Feature Spec v2" (Obsidian). Design language:
Things 3 calm — warm off-white, hairline dividers, one blue accent.

## Run

Requires **macOS 26+** to run and the **Xcode 27 beta** toolchain to build (the
voice suite uses the modern Apple speech stack — SpeechAnalyzer and Foundation
Models). Select the beta per-shell with
`export DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer`.

```bash
swift test          # full suite: models, Logic, agent loop, parsers, voice capture
./build-app.sh      # builds build/Mustard.app (signed, double-clickable)
open build/Mustard.app
```

## What works (v0)

- **Today** — timeline of scheduled tasks, quick capture (Enter schedules onto
  today 9:00), complete/uncomplete, inbox of unscheduled tasks, carry-forward of
  open past tasks. SwiftData-persisted to `~/Library/Application Support/Mustard/`.
- **Agent** — point it at your Obsidian vault (Choose…), hit **Sweep**: Claude
  reviews the vault and proposes up to 5 tasks into the **Recommendations**
  queue. Decide each: **Approve** (agent executes now) · **Schedule** (becomes a
  task tomorrow 9:00) · **I'll do it** (becomes an inbox task) · **Deny**. Every
  execution produces an output card in the **Review** queue: **Accept · Revise ·
  Discard**. No silent completion.
- **Trust & gating** — the Agent console "Trust" menu sets how much runs without
  you: **Manual** (approve everything) · **Supervised** (auto-runs non-gated
  work, you review output) · **Trusted** (auto-runs + auto-accepts) ·
  **Autonomous**. Email/ticket/Slack actions are *always* gated regardless of
  level (shown with a lock badge). Raising trust also processes the backlog.
- **Board** — personal Kanban: Inbox · Planned · In Progress · Done · Someday
  columns, drag cards between them, per-column quick add.
- **Week** — Sunsama/Akiflow-style Mon–Sun planner: unscheduled rail on the
  left, drag a task onto a day to schedule it (keeps time-of-day, 9:00 default),
  drag back to the rail to unschedule, week paging.
- **Command bar** — ⌘K: type to capture a task (Enter), or run "Go to Today / Board / Week / Agent" / "Sweep now" — arrow keys + Enter, Esc closes.
- **Notch** — auto-shows on the built-in display: black notch-hugging strip rotating focus → waiting count; hover expands into the agent tray (inline Approve/Deny) + quick capture. ⌘⇧N toggles.
- **Scheduled sweeps** — "Auto" menu in the Agent console (hourly / 4h / daily); the app checks every minute and sweeps when due.
- **Hover panel** — ⌘⇧H: always-on-top, non-activating mini panel showing your
  current focus (or what the agent is executing) and how many items wait on you.
  Expands on hover.
- **Voice capture** — hold **⌃⌥Space** anywhere on the Mac, speak a task, release: a
  floating pill shows the live transcript (on-device speech, no audio leaves the Mac)
  and the words land as an Inbox task instantly. The agent then tidies it in the
  background — inferring a short title, description, schedule ("…on the 9th of
  August"), and area — and, when you asked it to *do* something ("email the action
  points to Matt"), proposes it in the Agent triage deck for your approval (email/
  Slack/tickets stay gated). First launch asks for Microphone + Speech permission.
  Spec: ADR-0011.

Agents run through your **Claude subscription** (`claude -p`, headless) — no API
key, no metered billing. If runs fail with 401, run `/login` inside `claude`
once (tokens expire), or mint a long-lived one with `claude setup-token`.

## Architecture

Swift Package: `MustardKit` (models, logic, agent layer, views) + thin `Mustard`
executable + `MustardTests`. SwiftData schema is CloudKit-compatible (optional
relationships, no unique constraints) so iCloud sync is a later capability flip.
`ClaudeRunner` spawns the CLI with a scrubbed env (`ANTHROPIC_*`/`CLAUDE*`
removed) and closed stdin; override the binary with `MUSTARD_CLAUDE_BIN` (tests
use a stub script).

## Next (per spec §13)

Sources beyond the vault (email/Slack/meetings) · gating + per-agent trust ·
the notch surface · Google Calendar two-way · CloudKit + iOS companion.
Plans live in `Triage-tool/docs/superpowers/plans/`.
