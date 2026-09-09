-- Mustard hosted task control plane — initial schema (ADR-0013, slice 2).
--
-- Authoritative source: docs/specs/2026-08-26-shared-task-service-design.md
-- ("Domain model (server schema, v1)", "Mapping-fidelity notes", "Stage machine",
-- "Leases and crash recovery", "Idempotency", "Authentication and clients") and
-- docs/adr/0013-hosted-task-control-plane.md. If this file and the design doc ever
-- disagree, the design doc wins — fix this migration, don't reinterpret it.
--
-- Applied via `supabase db push` (or plain `psql` against the Supabase Postgres
-- connection string) from server/supabase/migrations, in filename order. That
-- path is the Supabase CLI's default and is not optional: `db push` only reads
-- `<config-dir>/supabase/migrations`, so a migration living anywhere else is
-- silently skipped rather than reported missing.
--
-- Scope: tasks + agent runs only (staged-plan slice 2/3). Later-slice tables
-- (recommendations, gmail_*, calendar_events, meeting_*) are NOT created here —
-- they arrive in their own migrations per the staged plan, step 6.
--
-- Conventions used throughout:
--   * All primary keys are `uuid`. Tables that mirror an existing SwiftData model
--     with a stable `uid` (tasks, agent_runs, agent_messages) are expected to
--     receive that uid as the client-supplied id on insert, so identity survives
--     the cutover. Tables with no SwiftData uid today (areas, task_lists) and
--     purely server-side tables (clients, leases, idempotency_keys, artifacts)
--     mint their own. Every id column carries a `gen_random_uuid()` default so a
--     server-side insert never needs the API to generate one, but the default is
--     just a fallback — a client-supplied id always wins.
--   * Enums are `text` + a named `CHECK (... IN (...))`, snake_case values, per
--     the design doc's "Enum casing" mapping-fidelity note (the wire/API is
--     snake_case even though the current Swift raw values are camelCase).
--   * Mutable rows carry `revision integer` (bumped per write by the API layer —
--     no DB trigger, since the transition modules are the single place that owns
--     writes) plus `created_at`/`updated_at timestamptz`, and soft-delete via a
--     nullable `deleted_at` where the design doc's general soft-delete rule
--     applies. Purely append-only tables (agent_messages, task_events) skip all
--     three — they are never updated or deleted, only inserted.

create extension if not exists pgcrypto;

-- =====================================================================
-- clients — API callers: the Mac app, iOS app, and each provider worker.
-- =====================================================================
create table clients (
    id             uuid primary key default gen_random_uuid(),
    name           text not null,
    kind           text not null,
    provider       text,
    token_hash     text not null,
    scopes         text[] not null default '{}',
    enabled        boolean not null default true,
    last_seen_at   timestamptz,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),

    constraint clients_kind_check
        check (kind in ('user_app', 'worker')),
    -- Same provider vocabulary as tasks.selected_provider / agent_runs.provider;
    -- null means "not a provider-specific worker" (e.g. the Mac/iOS apps).
    constraint clients_provider_check
        check (provider is null or provider in ('claude', 'codex', 'grok', 'hermes', 'manual', 'any')),
    constraint clients_name_key unique (name),
    constraint clients_token_hash_key unique (token_hash)
);

-- =====================================================================
-- areas — top-level grouping. Area identity is its name (the routing join
-- key per the design doc), so name stays unique even though there is no
-- SwiftData uid to migrate.
-- =====================================================================
create table areas (
    id          uuid primary key default gen_random_uuid(),
    name        text not null,
    color_hex   text not null default '#2D7FF9',
    revision    integer not null default 1,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    deleted_at  timestamptz
);

-- Required by spec: "Unique index on areas(name)." Deliberately NOT scoped to
-- `where deleted_at is null` — Area identity is its name (the routing join
-- key), so a soft-deleted area's name should keep colliding with a new one
-- rather than allow silent duplicates under the same name.
create unique index areas_name_key on areas (name);

-- =====================================================================
-- task_lists — sub-grouping under an area, mirrors SwiftData TaskList.
-- =====================================================================
create table task_lists (
    id          uuid primary key default gen_random_uuid(),
    name        text not null,
    area_id     uuid references areas (id),
    revision    integer not null default 1,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    deleted_at  timestamptz
);

create index task_lists_area_id_idx on task_lists (area_id);

-- =====================================================================
-- tasks — full-fidelity map of MustardTask (Sources/MustardKit/Models/MustardTask.swift).
-- Dead fields (captureAttempts, captureNextAttemptAt, legacy statusRaw) are not
-- migrated, per the design doc's mapping-fidelity note.
-- =====================================================================
create table tasks (
    id                        uuid primary key default gen_random_uuid(),

    title                     text not null default '',
    notes                     text not null default '',

    stage                     text not null default 'inbox',
    owner                     text not null default 'me',
    -- Provider assignment for this task (routing target for claim eligibility;
    -- see "Provider values" in the design doc — an unavailable provider simply
    -- leaves the task queued and visible, no silent reroute). This has no
    -- corresponding SwiftData field today: it's new, server-only state backing
    -- `POST /v1/tasks/{id}/provider`. Null = unassigned.
    selected_provider         text,

    priority                  text not null default 'normal',
    scheduled_at              timestamptz,
    due_at                    timestamptz,
    is_timed                  boolean not null default false,
    -- startOfDay a task is starred as a focus intention for; stored as a full
    -- timestamptz (like every other Date field here) rather than a bare `date`
    -- so day-boundary semantics stay exactly what the client's Calendar computed.
    focus_on_day              timestamptz,
    estimate_minutes          integer not null default 30,
    completed_at              timestamptz,
    carried_forward_at        timestamptz,

    recurrence                text,
    recurred_from             text,
    auto_completed            boolean not null default false,

    tags                      text[] not null default '{}',
    links                     jsonb not null default '[]',

    source                    text not null default 'manual',
    source_url                text,
    source_context            text not null default '',
    origin_key                text,

    -- The ledger-task gate — must survive the cutover verbatim.
    agent_approval_granted    boolean not null default false,

    capture_state             text,
    capture_transcript        text,

    blocked_by_task_id        uuid references tasks (id),
    blocked_reason            text not null default '',
    parent_task_id            uuid references tasks (id),
    list_id                   uuid references task_lists (id),

    -- Uncontrolled text pending the recommendations slice: RecommendationAction's
    -- vocabulary isn't part of this migration's scope, so no CHECK here.
    action_type               text,
    confidence                double precision,

    revision                  integer not null default 1,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now(),
    deleted_at                timestamptz,

    constraint tasks_stage_check check (stage in (
        'inbox', 'planned', 'scheduled', 'for_agent', 'needs_approval',
        'queued', 'in_progress', 'needs_input', 'needs_review', 'blocked', 'done'
    )),
    constraint tasks_owner_check check (owner in ('me', 'agent')),
    constraint tasks_selected_provider_check check (
        selected_provider is null
        or selected_provider in ('claude', 'codex', 'grok', 'hermes', 'manual', 'any')
    ),
    -- Not in the task's explicit CHECK list, but genuine enums on MustardTask
    -- today (Sources/MustardKit/Models/Enums.swift) — constrained for the same
    -- reason the seven required enums are.
    constraint tasks_priority_check check (priority in ('low', 'normal', 'high', 'urgent')),
    constraint tasks_recurrence_check check (
        recurrence is null or recurrence in ('daily', 'weekdays', 'weekly', 'monthly')
    ),
    constraint tasks_capture_state_check check (
        capture_state is null or capture_state in ('raw', 'cleaned', 'failed')
    )
);

create index tasks_stage_idx on tasks (stage);
create index tasks_owner_stage_idx on tasks (owner, stage);
create index tasks_updated_at_idx on tasks (updated_at);
create index tasks_list_id_idx on tasks (list_id);
create index tasks_parent_task_id_idx on tasks (parent_task_id);
create index tasks_blocked_by_task_id_idx on tasks (blocked_by_task_id);

-- =====================================================================
-- task_context — per-task structured references a worker may use. Modeled
-- 1:1 with tasks (PK = task_id) because the design doc describes it as
-- singular per-task context ("per-task structured references"), authored by
-- Leon/the Mac app at delegation time — not a multi-row list. Revisit if a
-- later slice needs several context entries per task.
--
-- Instructions and references only — never credentials.
-- =====================================================================
create table task_context (
    task_id       uuid primary key references tasks (id),
    note_refs     jsonb not null default '[]',
    urls          jsonb not null default '[]',
    artifact_ids  jsonb not null default '[]',
    guidance      text,
    revision      integer not null default 1,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- =====================================================================
-- agent_runs — one durable conversation per delegated task. `project` is the
-- portable identifier a worker resolves to a local path via its own config;
-- `workingDirectory` (an absolute local path) does not migrate.
-- =====================================================================
create table agent_runs (
    id                          uuid primary key default gen_random_uuid(),
    task_id                     uuid not null references tasks (id),

    provider                    text not null default 'claude',
    state                       text not null default 'queued',
    provider_session_id         text,
    project                     text not null default '',

    requires_connected_worker   boolean not null default false,
    attempt_count               integer not null default 0,
    resume_count                integer not null default 0,
    auto_retry_count            integer not null default 0,
    next_attempt_at             timestamptz,

    -- Free-form outcome of the last turn (completed / needs_input / failed /
    -- cancelled / requires_connected_worker / completion_uncertain per the API
    -- surface's outcome contract). Not CHECK-constrained: that vocabulary is
    -- owned by the TypeScript outcome-mapping module, not this migration, and
    -- wasn't in the task's explicit enum list.
    last_outcome                text,
    last_error                  text,

    started_at                  timestamptz,
    last_activity_at            timestamptz not null default now(),
    completed_at                timestamptz,

    revision                    integer not null default 1,
    created_at                  timestamptz not null default now(),
    updated_at                  timestamptz not null default now(),

    constraint agent_runs_provider_check
        check (provider in ('claude', 'codex', 'grok', 'hermes', 'manual', 'any')),
    constraint agent_runs_state_check check (state in (
        'queued', 'running', 'needs_input', 'completed', 'failed', 'cancelled', 'interrupted'
    )),
    -- One run per task.
    constraint agent_runs_task_id_key unique (task_id)
);

create index agent_runs_state_idx on agent_runs (state);

-- =====================================================================
-- agent_messages — append-only ordered turns. Immutable by convention: the
-- API only ever inserts, never updates or deletes a row here, so there is no
-- revision/updated_at/deleted_at.
-- =====================================================================
create table agent_messages (
    id                 uuid primary key default gen_random_uuid(),
    run_id             uuid not null references agent_runs (id),
    seq                integer not null,
    role               text not null,
    kind               text not null,
    content            text not null default '',
    links              jsonb not null default '[]',
    provider_turn_id   text,
    created_at         timestamptz not null default now(),

    constraint agent_messages_role_check check (role in ('human', 'agent', 'system')),
    constraint agent_messages_kind_check check (kind in (
        'delegation', 'question', 'answer', 'progress', 'result',
        'review_feedback', 'recovery', 'error'
    )),
    constraint agent_messages_run_id_seq_key unique (run_id, seq)
);

-- =====================================================================
-- artifacts — metadata for stored files (content lives in object storage;
-- this row is the pointer + provenance).
-- =====================================================================
create table artifacts (
    id            uuid primary key default gen_random_uuid(),
    task_id       uuid not null references tasks (id),
    run_id        uuid references agent_runs (id),
    kind          text not null,
    title         text not null default '',
    storage_key   text not null,
    mime          text,
    size_bytes    bigint,
    created_by    uuid references clients (id),
    created_at    timestamptz not null default now()
);

create index artifacts_task_id_idx on artifacts (task_id);
create index artifacts_run_id_idx on artifacts (run_id);

-- =====================================================================
-- task_events — append-only audit trail AND the sync cursor (`seq` is the
-- monotonic cursor GET /v1/events?after={seq} walks). Never updated/deleted.
-- =====================================================================
create table task_events (
    seq         bigserial primary key,
    task_id     uuid not null references tasks (id),
    run_id      uuid references agent_runs (id),
    -- Client that caused the event. Nullable: some events (e.g. a lease-expiry
    -- sweep) are system-generated with no calling client.
    actor       uuid references clients (id),
    type        text not null,
    payload     jsonb not null default '{}',
    created_at  timestamptz not null default now()
);

create index task_events_task_id_idx on task_events (task_id);

-- =====================================================================
-- leases — worker claims. Enforces at most one ACTIVE lease per task.
--
-- Design choice (spec asked for "the simplest correct design, documented in a
-- comment"): expired rows are kept for audit rather than deleted, and
-- uniqueness is scoped by a `released` boolean rather than by `expires_at`.
-- A lease blocks a new claim only while `released = false`; the partial
-- unique index below then guarantees at most one such row per task at the DB
-- level. Whether an unreleased lease has actually expired is a runtime check
-- (`expires_at < now()`) done by the claim/renew handlers and by the expiry
-- sweeper, which flips `released = true` on rows it reaps (logging a
-- `lease_expired` task_event) — the DB constraint doesn't need to know about
-- time, only about "is this row still the active one".
-- =====================================================================
create table leases (
    id           uuid primary key default gen_random_uuid(),
    task_id      uuid not null references tasks (id),
    client_id    uuid not null references clients (id),
    created_at   timestamptz not null default now(),
    renewed_at   timestamptz,
    expires_at   timestamptz not null,
    released     boolean not null default false
);

create unique index leases_active_task_id_key
    on leases (task_id)
    where released = false;

create index leases_client_id_idx on leases (client_id);

-- =====================================================================
-- idempotency_keys — replay protection for POSTs that carry an
-- Idempotency-Key header (task creation, outcome posts).
-- =====================================================================
create table idempotency_keys (
    id          uuid primary key default gen_random_uuid(),
    key         text not null,
    client_id   uuid not null references clients (id),
    route       text not null,
    response    jsonb,
    status      integer,
    created_at  timestamptz not null default now(),

    constraint idempotency_keys_client_key_route_key unique (client_id, key, route)
);
