# ADR-0003 — Agent runs via the `claude` CLI subscription, not the API

**Status:** Accepted (2026-06-12); amended by
[ADR-0013](0013-hosted-task-control-plane.md) (2026-08-26) — the Mac-local
subscription runtime remains the default Claude executor, but other providers now
execute via Leon's own sessions through the task API, so "anchored to this Mac" no
longer describes the system as a whole.

## Context
For personal use Leon wants to use his **Claude Code subscription**, not pay
per-token via the Anthropic API. Claude Code supports headless invocation
(`claude -p "…" --output-format json`) that draws on the logged-in subscription.

## Decision
The agent **shells out to the `claude` CLI in headless print mode** with no API
key. `ClaudeRunner.run` spawns a `Process`; `AgentService` runs invocations
**serially** and backs off on rate-limit signals.

Two implementation details are load-bearing and were proven by real failures:
1. **Scrub the environment** — drop all `ANTHROPIC_*` and `CLAUDE*` vars before
   spawning, so a worker launched from inside a Claude Code session (which injects
   a proxy `ANTHROPIC_BASE_URL`) still authenticates against the CLI's own login.
2. **Close stdin** (`/dev/null`) — otherwise the CLI blocks waiting on the pipe.
3. `MUSTARD_CLAUDE_BIN` overrides the binary (tests use a stub script).

## Consequences
- No metered billing; uses subscription quota.
- The agent is **anchored to this Mac** (the machine with the logged-in CLI) and
  cannot move to a cloud server without re-introducing API billing. iOS never runs
  the agent — it observes the synced store.
- Tokens expire: a background sweep can 401 silently. Use `claude setup-token` for
  a long-lived headless token; `/login` refreshes an expired interactive one.
- The live subscription path can't be verified from the dev session (nested-session
  keychain limits) — verified from Leon's own terminal.
