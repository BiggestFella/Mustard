# ADR-0013 — Hosted single-user task control plane


**Status:** Accepted (2026-08-26). **Supersedes ADR-0001's no-hosted-backend
decision and the CloudKit sync path. Amends ADR-0003 and ADR-0004 (see below).**

## Context

Mustard's structured data is device-local SwiftData (ADR-0001), the agent is
anchored to this Mac (ADR-0003), and cross-device sync was deferred to a future
CloudKit flip. That shape cannot serve the 2026-08-26 direction: Leon wants any of
his AI agent sessions — Claude Code, Codex, Grok, Hermes/OpenClaw — to be told, via
a skill, to pick up Mustard tasks, execute them, ask questions, and return results;
and a full network-first iOS client. Both need a task store that is reachable when
the Mac is closed, with server-enforced state transitions, claims, and history.

Design: `docs/specs/2026-08-26-shared-task-service-design.md` (approved by Leon
2026-08-26). Handoff: `docs/handoffs/2026-08-26-shared-task-service-and-multi-agent-clients.md`.

## Decision

A private, single-user **hosted task control plane**: managed Postgres and object
storage behind a small authenticated HTTPS API, authoritative for shared execution
state (tasks, stages, agent runs, messages, leases, artifacts, append-only events).

- **Platform:** Supabase, Sydney region, **free tier first** — upgrade only when a
  slice needs backups or storage headroom. The API is our own TypeScript (Hono) app
  on Edge Functions; PostgREST/direct table access is never exposed.
- **Clients:** Mustard Mac (SwiftData becomes a synced cache + workspace), later a
  network-first iOS full client, and agent sessions via one provider-neutral
  `mustard-worker` skill using per-client bearer tokens.
- **Phase-1 workers are Leon's own interactive sessions** on their existing logins —
  no daemons, no new billing. Headless adapters/routines are a later, explicit add.
- **Semantics preserved:** the 11-stage pipeline, structured turn contract, Needs
  You / Needs Review gates, drafts-only outward actions, completion-uncertainty,
  and take-back rules move to server-side enforcement unchanged. No silent
  provider fallback; an unavailable provider leaves work queued and visible.
- **Notes stay in the git-backed vault repo** — the server stores note references,
  never note content. Keychain tokens, local paths, and device-local domains
  (clips, dictation, recording breadcrumbs) never migrate.

## Consequences

- **ADR-0001** is superseded for structured shared state: there is now a hosted
  backend, and the CloudKit sync path is retired (its schema disciplines — optional
  relationships, defaulted fields — remain useful and stay). The local-markdown
  vault decision stands.
- **ADR-0003** is amended, not superseded: the Mac-local subscription `claude`
  runtime remains the default Claude executor and later claims work through the
  same API as any worker. "The agent is anchored to this Mac" no longer describes
  the system as a whole.
- **ADR-0004**'s Xcode-project migration is still required for iOS, but for the app
  itself (and later APNs), not CloudKit entitlements.
- Task data (and, in later slices, email/meeting content if Leon approves content
  storage — still an open decision) lives on a hosted vendor, encrypted at rest,
  Sydney region, private single-user access.
- Free-tier realities: no managed backups (the Mac's SwiftData mirror is the
  recovery copy) and auto-pause after ~a week of zero activity.
- Rollback per slice via the `useTaskService` flag; with it off, Mustard behaves
  exactly as today.
