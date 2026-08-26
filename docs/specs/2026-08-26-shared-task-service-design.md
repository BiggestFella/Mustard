# Shared task service and multi-agent clients — design

- **Date:** 2026-08-26
- **Status:** Draft — awaiting Leon's approval (spec gate). No implementation authorised.
- **Builds on:** `docs/handoffs/2026-08-26-shared-task-service-and-multi-agent-clients.md`,
  ADR-0003, ADR-0010, and the agent-task-sessions design
  (`docs/specs/2026-07-13-agent-task-sessions-design.md`)
- **Supersedes (proposed):** ADR-0001's "no hosted backend" decision and the CloudKit
  sync path. See "ADR changes" below — nothing is edited until Leon approves.

## Summary

Mustard gains a private, single-user, hosted **task control plane**: managed Postgres
behind a small authenticated API, plus object storage for attachments and artifacts.
Mustard on Mac (and later iOS) become clients of that service. Any of Leon's AI agent
sessions — Claude Code, Codex, Grok, Hermes/OpenClaw — can be told, via one shared
**worker skill**, to pick up queued Mustard tasks, execute them, ask questions, and
return results to Needs Review. The task contract is provider-neutral; the existing
stage machine, structured turn contract, review gates, and idempotency rules from the
2026-07-13 design carry over unchanged — they move from SwiftData-local to server-side
enforcement.

**Phase-1 worker model (per Leon, 2026-08-26):** workers are *interactive agent
sessions Leon already runs*, pulling work through the skill on their own logins. No
headless daemons, no new API billing, no per-provider adapters yet. Adapters and
routines can be added later behind the same API.

## Decisions this design encodes (from Leon, 26 Aug)

| # | Decision |
|---|---|
| 1 | Phase 1 success = any agent session can list, claim, execute, question, and complete tasks via a skill. Off-Mac daemons/adapters are later. |
| 2 | No billing change initially: each agent session runs on whatever subscription/login it already has. Metered adapters are a later, explicit add. |
| 3 | Scope eventually includes **everything** — tasks, agent runs, recommendations/triage, Gmail, meetings, calendar, notes — staged in slices; tasks + runs first. |
| 4 | Personal data leaving the Mac is accepted in principle; the security bar below applies. |
| 5 | Integration credentials: deferred. Phase-1 workers use their own connectors; tasks carry instructions and context references only, never tokens. |
| 6 | Provider capability differences: dissolved for phase 1 (all interactive sessions can ask questions and resume). A capability model is documented for later headless adapters. |
| 7 | Backend region/security bar: Leon doesn't mind — defaults chosen below (Sydney, encrypted at rest, private). |
| 8 | The `drain-agent-queue` file-bridge worker is effectively unused and will be retired once the API path covers connected work. |
| 9 | Push notifications: not needed yet. iOS uses pull/refresh until APNs is worth its Apple-Developer prerequisite (ADR-0004). |
| 10 | Backend budget assumption: ~$25/mo, zero server babysitting, managed platform. |

## Backend comparison and recommendation

Requirements: managed Postgres, object storage, an authenticated HTTPS API reachable
by agent sessions anywhere (including cloud sandboxes — so public TLS + bearer token,
not Tailscale-only), server-side enforcement of state transitions/leases/idempotency,
~$25/mo, zero patching, Sydney-preferred.

| Option | Shape | Cost (verify at kickoff) | Assessment |
|---|---|---|---|
| **A. Supabase (Sydney)** — recommended | Managed Postgres + Storage + Edge Functions in one project. Our own API written as a single TypeScript (Hono) app deployed to Edge Functions; PostgREST/direct table access **never exposed** — clients only see our API. | [$25/mo Pro](https://uibakery.io/blog/supabase-pricing), Sydney (AWS ap-southeast-2) available | One vendor, one bill, zero servers. Postgres + object storage + deploys included. The state machine lives in plain TypeScript modules (unit-testable, matching this repo's TDD culture), not PL/pgSQL. If Edge Function limits ever bite, the same Hono app moves to a $5 VM unchanged. |
| **B. Custom service on Fly.io + Fly Managed Postgres + Tigris** | Swift Vapor or TS API on a Fly machine, Sydney region | [Managed Postgres starts at $38/mo](https://fly.io/docs/mpg/) + machine + [Tigris storage](https://fly.io/docs/tigris/) ≈ $45+/mo | Most control; a Swift server could share contract types with MustardKit. But over budget, two more moving parts to operate, and the shared-Swift benefit is small — every client (skills, iOS, Mac) talks HTTP/JSON anyway; an OpenAPI spec covers type-sharing. |
| **C. TS API on Railway/Render + Neon Postgres + Cloudflare R2** | Three-vendor budget stack | ~$10–20/mo | Cheapest, but three vendors/regions to wire (Neon has no Sydney; nearest Singapore), three dashboards, three failure surfaces. Saves ~$10/mo over A while costing real operational simplicity. |

**Recommendation: Option A.** ADR-0001 rejected Supabase because the product was
local-first with no backend at all; that context is what's being superseded, so the
rejection doesn't carry over. The guardrail against picking by familiarity is
satisfied by the comparison: A wins on cost, region, vendor count, and ops burden,
not habit. Facts to re-verify at implementation kickoff: current Supabase Pro
inclusions, Edge Function limits (request duration, cron), backup/PITR options.

## Target architecture

```
┌─ clients ─────────────────────────────┐   ┌─ control plane (Supabase, Sydney) ─┐
│ Mustard Mac  (full client + cache)    │   │  API  (TS/Hono on Edge Functions)  │
│ Mustard iOS  (network-first, later)   ├──▶│   auth · transitions · leases ·    │
│ Agent sessions via mustard-worker     │   │   idempotency · events cursor      │
│   skill: Claude / Codex / Grok /      │   │  Postgres  (tasks, runs, messages, │
│   Hermes — their own logins           │   │   events, leases, clients)         │
│ AgentTaskCoordinator (Mac-local       │   │  Storage   (artifacts, private,    │
│   claude runtime — becomes just       │   │   presigned URLs)                  │
│   another worker in slice 5)          │   └────────────────────────────────────┘
└───────────────────────────────────────┘
```

- The **server is authoritative** for shared execution state (tasks, stages, runs,
  messages, leases, events, artifacts) once a domain is migrated.
- **SwiftData remains** the Mac's cache and workspace, synced via the event cursor +
  optimistic-concurrency writes. Device-local domains (clips, dictation, live audio
  capture) never move.
- **No event bus, no websockets** in v1: workers poll/claim, clients pull the event
  cursor, the Mac's existing 60s loop drives sync.

## Authentication and clients

Single-user private service; no signup, no OAuth ceremony.

- `clients` table: `id`, `name` ("mac-app", "ios-app", "worker-claude", …), `kind`
  (`user_app` | `worker`), `provider?`, `token_hash`, `scopes`, `enabled`,
  `last_seen_at`. Tokens are long random strings, **hashed at rest**, minted/revoked
  by an admin script; presented as `Authorization: Bearer …`.
- Scopes: `user_app` can do everything; `worker` can list/claim/append/outcome but
  **cannot** accept reviews, delete, change provider assignment, or mint clients.
- Worker tokens live in each agent's own config (e.g. the skill reads
  `~/.config/mustard/worker.json`), never in task payloads.

## Security bar (defaults — Leon can tighten)

TLS everywhere; tokens hashed; Postgres and Storage encrypted at rest (vendor
default); Sydney region; daily backups; storage objects private with short-lived
presigned URLs; append-only `task_events` as the audit trail; no analytics or
third-party data processors. Plainly stated: once the Gmail/meetings slices land,
email bodies and transcripts will live in the vendor's Postgres/Storage. If that
ever feels wrong, those slices can hold back content and store references only —
that toggle is a per-slice decision, not a rewrite.

## Domain model (server schema, v1)

Snake_case Postgres. IDs are UUIDs; existing SwiftData `uid`s migrate as the
server IDs so identity is stable across the cutover. All mutable rows carry
`revision` (int, bumped per write) and `created_at`/`updated_at`; deletes are
soft (`deleted_at`) so the event stream stays coherent.

| Table | Purpose / notable columns |
|---|---|
| `areas`, `task_lists` | grouping, mirroring SwiftData (`name`, `color_hex`, fk). Neither has a `uid` today — migration mints UUIDs; `Area` identity is currently its `name` (it's the routing join key), so keep a unique index on `name`. |
| `tasks` | full-fidelity map of `MustardTask`: `title`, `notes`, `stage`, `owner`, `selected_provider`, `priority`, `scheduled_at`, `due_at`, `is_timed`, `focus_on_day`, `estimate_minutes`, `completed_at`, `carried_forward_at`, `recurrence`, `recurred_from`, `auto_completed`, `tags text[]`, `links jsonb`, `source`/`source_url`/`source_context`/`origin_key`, `agent_approval_granted` (the ledger-task gate — must survive), `capture_state`/`capture_transcript`, `blocked_by_task_id?`, `blocked_reason`, `parent_task_id?` (subtask tree), `list_id?`, `action_type?`, `confidence?`, `revision`. Dead fields (`captureAttempts`, `captureNextAttemptAt`, legacy `statusRaw`) are not migrated. |
| `task_context` | per-task structured references a worker may use: vault note paths, URLs, artifact ids, free-text guidance. **Instructions and references only — never credentials.** Authored by Leon/the Mac app at delegation; defaults per area later. |
| `agent_runs` | one durable conversation per delegated task: `task_id`, `provider`, `state`, `provider_session_id?`, `project` (portable), `requires_connected_worker`, `attempt_count`, `resume_count`, `auto_retry_count`, `next_attempt_at?`, `last_outcome?`, `last_error?`, timestamps. **`workingDirectory` does not migrate** — it's an absolute local path; the server stores only `project`, and each worker resolves project → local path via its own config (the skill's config file). |
| `agent_messages` | append-only ordered turns: `run_id`, `seq`, `role` (human/agent/system), `kind` (delegation/question/answer/progress/result/review_feedback/recovery/error), `content`, `links jsonb`, `provider_turn_id?` |
| `artifacts` | metadata for stored files: `task_id`, `run_id?`, `kind`, `title`, `storage_key`, `mime`, `size_bytes`, `created_by` |
| `task_events` | **append-only audit + sync cursor**: `seq bigserial`, `task_id`, `run_id?`, `actor` (client id), `type`, `payload jsonb` |
| `leases` | `task_id` (one active per task, enforced by partial unique index), `client_id`, `expires_at`, `renewed_at` |
| `clients` | see Authentication |
| `idempotency_keys` | `key`, `client_id`, `route`, stored response |

`AgentDraft` (file-backed drafts under a local working directory) does not get its
own table: for server tasks, draft **content** is uploaded and becomes an
`artifacts` row, removing the local-path dependence.

Later slices add `recommendations`, `calendar_events`, `gmail_*`, `meeting_*`, and
`notes` tables, each mapped from its SwiftData model in its own slice spec. The
`Recommendation` triage loop (sweep → propose → approve) stays Mac-local until its
slice; approval continues to create tasks — which, once slice 4 lands, are server
tasks.

### Mapping-fidelity notes (from the 2026-08-26 model audit)

- **Identity:** `MustardTask`, `AgentRun`, `AgentMessage`, `MeetingRecord`(+segments,
  proposals), `ClipItem`/`ClipCollection` all carry stable string `uid`s — migrate
  as-is. `Recommendation`, `Area`, `TaskList`, `CalendarEvent`, `NoteIndexEntry`
  have **no uid**; migration mints UUIDs and adds the unique indexes SwiftData never
  could: `calendar_events(calendar_id, external_id)`, `notes(project,
  relative_path)`, recommendations' `(project, source_item_id)` dedupe key. Expect
  and de-duplicate collisions during import — nothing enforces uniqueness today.
- **Message ordering:** preserve the triple `(sequence, created_at, uid)`; queue
  ordering is `ORDER BY priority_rank, created_at, uid` — both are deterministic and
  server-reproducible.
- **Enum casing:** the turn contract is snake_case on the wire
  (`needs_input`, `requires_connected_worker`) while `TaskStage`/`AgentRunState`
  raws are camelCase. The API uses snake_case throughout; clients map. Store enums
  as `text` + CHECK, and keep the client's fail-soft decode (unknown value → safe
  default) for forward compatibility.
- **Transactions:** the coordinator's snapshot-mutate-save-rollback idiom becomes
  one Postgres transaction per turn/transition.
- **Lease gap confirmed:** today's mutual exclusion is the in-memory
  `AgentExecutionGate` with no persisted form, and launch-time
  `reconcileInterruptedRuns` routes orphaned `running` runs (gated action →
  Needs Review "completion uncertain", else re-queued). The server's lease-expiry
  sweeper implements exactly those semantics.
- **Stays client-side:** `AgentRetryPolicy` (backoff 60/300/900, auth-pause,
  gated-timeout → completion-uncertain) continues to govern the local claude
  runtime; the server just stores `next_attempt_at`/`auto_retry_count` and refuses
  claims before `next_attempt_at`.
- **Never migrates:** Keychain tokens (Gmail/Calendar OAuth), UserDefaults settings
  blobs, `MeetingRecord.recoveryStateRaw` (local crash breadcrumb), clip image
  blobs' macOS app provenance, `Recommendation.vaultPath` absolute paths.

Provider values: `claude`, `codex`, `grok`, `hermes`, `manual`, and **`any`** —
`any` matches Leon's phase-1 usage ("tell whichever bot to go pick up tasks");
a specific value restricts claiming to that provider. Unavailable provider ⇒ the
task simply stays `queued` with its assignment visible; no silent rerouting.

### Stage machine

The server enforces the existing 11-stage `TaskStage` pipeline verbatim
(`Models/TaskStage.swift`): `inbox, planned, scheduled, forAgent, needsApproval,
queued, inProgress, needsInput, needsReview, blocked, done` (snake_case on the
wire). The delegated-work path:

```
inbox/planned/scheduled → forAgent/queued → (claim) inProgress
  → needsInput  ──reply──▶ queued (same run; same provider session where resumable)
  → needsReview ──accept──▶ done │ request changes ─▶ queued │ take back ─▶ planned
  cancelled ─▶ planned (owner reverts to me)  ·  requires_connected_worker ─▶ queued (flagged)
```

The full transition matrix ports from the existing pure units —
`Logic/AgentTaskTransition.swift` (outcome → stage/run-state), `PersonalBoard`'s
approve/move rules (including the ledger `agentApprovalGranted` grant/revoke on
lane moves), and the delegate-legality set — into the server's tested transition
module. Those files are the spec; no semantics change.

Rules preserved verbatim from the existing design:
- The **server, not the model, owns stage changes** — workers report structured
  outcomes; the API maps them to transitions. Unknown/malformed outcome = failure,
  never completion.
- Every completed delegated task lands in **Needs Review**. No silent completion,
  regardless of trust.
- A question releases the task's lease so other work proceeds.
- Take-back preserves the run and transcript; redelegation continues the
  conversation identity.
- Outward actions (email/Slack/ticket) remain drafts-only/always-gated per the
  worker contract; the server cannot enforce what a session does externally, but the
  contract, review gate, and audit trail are unchanged.

### Leases and crash recovery

- `POST /tasks/{id}/claim` atomically inserts a lease (TTL default 15 min) where no
  live lease exists and stage is claimable; returns 409 otherwise.
- Workers renew via heartbeat; an expired lease makes the task claimable again and
  logs a `lease_expired` event — a crashed session never wedges a task.
- Worker-driven mutations require the live lease; stale claims are rejected.

### Idempotency and completion-uncertainty

- `Idempotency-Key` header on task creation and outcome posts; replays return the
  stored response.
- The task UID remains the idempotency key workers embed in external creations
  (Shortcut/Jira metadata), exactly as today.
- A timeout during an external action reports `completion_uncertain` in the outcome
  and goes to Needs Review — never blind-retried.

## API surface (v1)

REST/JSON under `/v1`, bearer auth, `If-Match: <revision>` for optimistic
concurrency on PATCH (409 on mismatch). Full request/response schemas are an
implementation-slice deliverable (OpenAPI document, from which the Swift client is
generated).

```
POST   /v1/tasks                       create (Idempotency-Key)
GET    /v1/tasks?stage=&provider=&owner=&updated_after=
GET    /v1/tasks/{id}?expand=context,run,messages,artifacts
PATCH  /v1/tasks/{id}                  edit fields (If-Match)
POST   /v1/tasks/{id}/provider         assign/reassign provider
POST   /v1/tasks/{id}/claim            worker claim → lease
POST   /v1/leases/{id}/renew|release
POST   /v1/tasks/{id}/messages         append progress/question/etc. (lease req.)
POST   /v1/tasks/{id}/outcome          structured turn result:
                                       completed | needs_input | failed |
                                       cancelled | requires_connected_worker |
                                       completion_uncertain
POST   /v1/tasks/{id}/reply            Leon answers a question → queued
POST   /v1/tasks/{id}/review           accept | request_changes | take_back
POST   /v1/artifacts                   register + presigned upload URL
GET    /v1/artifacts/{id}/download     presigned download URL
GET    /v1/events?after={seq}&limit=   sync/audit cursor
GET    /v1/me · GET /v1/health
```

The transition matrix, lease rules, and outcome mapping live in pure TypeScript
modules with unit tests (the server-side analogue of `Logic/`); handlers are thin.

## The worker skill

One provider-neutral `mustard-worker` skill (markdown + the API), installable in any
of Leon's agent environments. It:

1. Reads the worker token and a project → local-working-directory map from local
   config (`~/.config/mustard/worker.json`) — the server never stores local paths.
2. Lists claimable tasks for its provider identity (or `any`).
3. Claims one, fetches full context (task, `task_context`, prior conversation,
   artifact links), heartbeats while working.
4. Obeys the behavioral contract carried over from the 07-13 design: work only the
   assigned task, ask focused questions instead of fabricating scope, drafts-only
   for outward actions, verify artifacts, report through the structured outcome.
5. Posts messages/outcome; uploads artifacts via presigned URLs.

Because phase-1 workers are interactive sessions, "resume after Needs You" means:
any session (same provider) re-claims the task and receives the durable transcript;
the provider-session id is best-effort (a Claude session can resume its own,
another can reconstruct from the transcript — the `recovery` message kind already
models this).

The skill lives in a **new, secret-free repo** (the existing vault repo has tracked
secrets and is unpushable), so Codex/Hermes/Grok environments can fetch it.

## Mac client changes

- **SyncEngine** (new, `MustardKit`): pull `GET /events` from a stored cursor on the
  existing 60s loop; apply to SwiftData. Push local mutations with `If-Match`; on
  409, refetch and surface the conflict (server wins by default; the local edit is
  offered for re-apply). Rows gain `serverRevision` + `syncState`. Pure
  diff/apply/conflict logic is TDD'd; transport is injected like `ClaudeRun`.
- **Mac offline** (recommended default): edits queue and replay on reconnect —
  Leon's Mac stays usable offline; conflicts surface rather than silently merge.
- **AgentTaskCoordinator** keeps its serial local slot and claude runtime, but in
  slice 5 claims work through the API like any worker (client `worker-claude-local`),
  so a skill session and the local runtime can never double-claim. Its retry policy
  (`AgentRetryPolicy`) is unchanged; auth-pause stays local.
- **Feature flag** `useTaskService`: off ⇒ today's fully local behavior. The flag is
  the rollback for every slice.
- **File bridge retirement:** once `requires_connected_worker` work can be claimed
  by a connected session through the API, `BridgeExport`/outbox/results and
  `drain-agent-queue` are retired (Leon confirms it's already unused).

## iOS client (later slice)

Network-first full client against the same API: board, task detail with
conversation, delegation, reply, review, artifacts. Requires the SPM → Xcode
project migration (ADR-0004) for a shippable app; **CloudKit is no longer needed** —
the service replaces it as the sync mechanism, which is a cheaper path to iOS than
CloudKit was (no entitlement-driven schema constraints). Push notifications
deferred (decision 9); a foreground refresh + badge poll suffices initially.

## ADR changes (proposed — nothing edited yet)

| ADR | Proposed change |
|---|---|
| **ADR-0001** | Superseded by new **ADR-0013 — Hosted single-user task control plane**: managed Postgres + API + object storage is authoritative for shared execution state; SwiftData becomes the Mac cache; CloudKit sync path retired. The local-markdown vault decision **stands**. |
| **ADR-0003** | Amended, not superseded: the Mac-local subscription claude runtime remains the default Claude executor; other providers execute via Leon's own sessions through the worker skill. The "agent is anchored to this Mac" consequence no longer holds for the system as a whole. |
| **ADR-0004** | Rewritten rationale: the Xcode project is still needed for a real iOS app, but for the app itself (and later APNs), not CloudKit entitlements. |
| **ADR-0010** | Semantics preserved; the board queue's transport becomes the API. The file-bridge phases it deferred are retired rather than completed. |
| CLAUDE.md / architecture.md | Updated after the relevant slices land, not before. |

## Staged plan

Each slice ends green (`swift test`, `swift build`, `./build-ios.sh` when shared
code changes; server: its own test suite + deployed health check) and is
independently revertible.

1. **Approval gate (Leon):** this design + ADR-0013 text. *(the only blocker)*
2. **Control plane skeleton:** Supabase project (Sydney); schema migrations; auth;
   transition/lease/idempotency modules TDD'd; events cursor; deploy; smoke tests
   via curl.
3. **Vertical slice — the phase-1 goal:** `mustard-worker` skill in a real Claude
   Code session: create task via API → claim → progress → question → reply →
   outcome → Needs Review, all verified end-to-end. Then repeat the same skill in
   one non-Claude session (Codex or Hermes) to prove provider-neutrality.
4. **Mac sync:** SyncEngine behind `useTaskService`; board/Today render server
   tasks; delegation from the Mac creates server tasks. One-time migration pushes
   existing tasks/runs (uid-keyed, additive, reversible).
5. **Local runtime on the API:** AgentTaskCoordinator claims via API; file bridge
   retired.
6. **Domain slices (each with its own short spec):** recommendations/triage →
   Gmail → calendar → meetings → notes.
7. **iOS full client** (needs ADR-0004's Xcode migration first).

## Open decisions for Leon

1. **Approve the direction + Option A (Supabase Sydney, ~$25/mo)** — this is also
   the billing acceptance.
2. **Approve the ADR-0013 supersession** as tabled above.
3. **Data-content toggle for later slices:** are email bodies and meeting
   transcripts allowed in the hosted DB when those slices arrive, or references
   only? (Not blocking slices 2–5.)
4. **Mac offline edits:** recommended yes (queue + replay + surfaced conflicts) —
   confirm.

Everything else in the handoff's open list is resolved in this document or
explicitly deferred with its trigger named.
