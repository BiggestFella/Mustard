# ADR-0001 — SwiftData + CloudKit, no hosted backend

**Status:** Superseded by [ADR-0013](0013-hosted-task-control-plane.md) (2026-08-26)
for structured shared state — a hosted task control plane is now authoritative and
the CloudKit sync path is retired. SwiftData remains as the Mac's local cache, and
the local-markdown vault decision stands.

## Context
The predecessor (a local web "Triage Cockpit") stored tasks as Obsidian markdown
and ran an Express server. An early brainstorm leaned toward Supabase/Postgres + a
Node worker. But the product is **personal, local-first**, wants offline use, and
should sync to a future iOS app without running or paying for servers. Leon also
wanted to keep the knowledge base as local markdown.

## Decision
Persist structured app data (tasks, recommendations, outputs, calendar events) in
**SwiftData**, designed to enable **CloudKit** (iCloud) sync later. **No hosted
backend, no Supabase, no Node server.** The Obsidian vault stays local markdown and
is the agent's working area, not the app's database.

CloudKit-compatibility is honoured from day one: all relationships optional, all
stored properties defaulted/optional, no unique constraints — so enabling sync is a
capability flip, not a data migration.

## Consequences
- Free, private, offline-first sync path via the user's own iCloud.
- iOS becomes a client of the same store with no server to build.
- The agent worker cannot live in the cloud (it's Mac-local anyway — see ADR-0003).
- The fully-tested Node worker from the predecessor is discarded as off-path.
- Enabling CloudKit needs entitlements → forces an Xcode project later (ADR-0004).
