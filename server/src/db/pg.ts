// Postgres implementation of the `Store` seam (src/db/store.ts) using the
// `postgres` (postgres.js) package.
//
// NOT integration-testable locally: this repo has no Docker/Postgres, so
// there is no automated test against a real database. Correctness is
// exercised by the deployed curl smoke tests in server/README.md, and by
// `npx tsc --noEmit` for type-level sanity. Read every method against
// src/db/store.ts's comments and the design doc
// (docs/specs/2026-08-26-shared-task-service-design.md) before changing it.
//
// Conventions used throughout:
// - Every public method opens exactly one `sql.begin()` transaction (per the
//   task brief) and does all its reads/writes against the transaction-scoped
//   `tx`, never the outer `this.sql`, so a check-then-write can never race
//   another request.
// - Rows come back from postgres.js as snake_case `Row` (`[column: string]: any`)
//   objects; `mapX` functions below translate to the camelCase row types in
//   store.ts. `timestamptz` columns come back as JS `Date`s (postgres.js's
//   built-in date parser) and are turned into ISO strings on the way out.
// - `text[]` and `jsonb` parameters MUST go through `tx.array(...)` /
//   `jsonb(tx, ...)` — a plain JS array/object passed as a bind parameter has
//   no inferred Postgres type and postgres.js falls back to `String(value)`,
//   which is wrong for both. See postgres.js's `array()`/`json()` helpers.
// - Column names interpolated directly into a template's *static* text
//   (never as a `${...}` parameter) are safe because they're always one of
//   our own hard-coded strings, never request input.

import type { Sql, TransactionSql } from "postgres";
import type {
  AgentMessageRow,
  AgentRunRow,
  ArtifactInput,
  ArtifactRow,
  ClientRow,
  CreateTaskInput,
  ExpandedTask,
  LeaseRow,
  MessageInput,
  OutcomeInput,
  Result,
  Store,
  StoreError,
  TaskContextRow,
  TaskEventRow,
  TaskFilter,
  TaskLinkJSON,
  TaskPatch,
  TaskRow,
} from "./store.ts";
import type {
  AgentRunState,
  MessageKind,
  Provider,
  TaskStage,
  TurnOutcome,
} from "../domain/stages.ts";
import { isClaimable, type QueueTask } from "../domain/queue.ts";
import {
  canReply,
  canRequestChanges,
  canTakeBack,
  decisionForOutcome,
  reviewAction,
  type ReviewActionKind,
} from "../domain/transitions.ts";

// ---------------------------------------------------------------------------
// Small pure helpers that mirror Swift logic not otherwise ported to
// src/domain (out of scope for this slice to add new domain modules — these
// are the minimum needed to call the given domain functions correctly).
// ---------------------------------------------------------------------------

/**
 * Mirrors `MeetingTaskSource.requiresAgentApproval` (Sources/MustardKit/
 * Logic/MeetingTaskSource.swift:17-19): true only for vault-harvested ledger
 * work (`source === "meeting"`), never for `"meeting-recording"` or anything
 * else. Needed to build the `QueueTask.requiresAgentApproval` input that
 * `isClaimable` (src/domain/queue.ts) requires — no TS port of
 * `MeetingTaskSource` exists in src/domain for this slice to call instead.
 */
const MEETING_LEDGER_SOURCE = "meeting";
function requiresLedgerApproval(source: string): boolean {
  return source === MEETING_LEDGER_SOURCE;
}

/**
 * Mirrors `MustardTask.isGated` / `RecommendationAction.isGated` (Sources/
 * MustardKit/Models/MustardTask.swift:111-115, Logic/RecommendationAction.swift):
 * no/empty action type -> not gated; a known action type -> its own gating;
 * an unknown/typo'd token fails closed (gated). Needed only for the
 * lease-expiry sweep's "gated action -> needs_review" routing
 * (expireLeases) — see the design doc's "Lease gap confirmed" note, which
 * says the sweeper mirrors `AgentTaskCoordinator.reconcileInterruptedRuns`.
 */
const KNOWN_ACTION_TYPES = new Set([
  "draft_email",
  "draft_slack",
  "create_task",
  "vault_note",
  "ticket_write",
  "fyi",
  "ignore",
]);
const GATED_ACTION_TYPES = new Set(["draft_email", "draft_slack", "ticket_write"]);
function isGatedActionType(actionType: string | null): boolean {
  if (!actionType) return false;
  if (!KNOWN_ACTION_TYPES.has(actionType)) return true; // fail closed
  return GATED_ACTION_TYPES.has(actionType);
}

// ---------------------------------------------------------------------------
// Row -> camelCase mapping
// ---------------------------------------------------------------------------

function iso(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  return value instanceof Date ? value.toISOString() : new Date(String(value)).toISOString();
}

function isoRequired(value: unknown): string {
  const out = iso(value);
  if (out === null) throw new Error("expected non-null timestamp column");
  return out;
}

function mapClient(row: Record<string, unknown>): ClientRow {
  return {
    id: row.id as string,
    name: row.name as string,
    kind: row.kind as ClientRow["kind"],
    provider: (row.provider as ClientRow["provider"]) ?? null,
    enabled: row.enabled as boolean,
  };
}

function mapTask(row: Record<string, unknown>): TaskRow {
  return {
    id: row.id as string,
    title: row.title as string,
    notes: row.notes as string,
    stage: row.stage as TaskRow["stage"],
    owner: row.owner as TaskRow["owner"],
    selectedProvider: (row.selected_provider as Provider) ?? null,
    priority: row.priority as TaskRow["priority"],
    scheduledAt: iso(row.scheduled_at),
    dueAt: iso(row.due_at),
    isTimed: row.is_timed as boolean,
    focusOnDay: iso(row.focus_on_day),
    estimateMinutes: row.estimate_minutes as number,
    completedAt: iso(row.completed_at),
    carriedForwardAt: iso(row.carried_forward_at),
    recurrence: (row.recurrence as string | null) ?? null,
    recurredFrom: (row.recurred_from as string | null) ?? null,
    autoCompleted: row.auto_completed as boolean,
    tags: (row.tags as string[] | null) ?? [],
    links: (row.links as TaskLinkJSON[] | null) ?? [],
    source: row.source as string,
    sourceURL: (row.source_url as string | null) ?? null,
    sourceContext: row.source_context as string,
    originKey: (row.origin_key as string | null) ?? null,
    agentApprovalGranted: row.agent_approval_granted as boolean,
    captureState: (row.capture_state as string | null) ?? null,
    captureTranscript: (row.capture_transcript as string | null) ?? null,
    blockedByTaskId: (row.blocked_by_task_id as string | null) ?? null,
    blockedReason: row.blocked_reason as string,
    parentTaskId: (row.parent_task_id as string | null) ?? null,
    listId: (row.list_id as string | null) ?? null,
    actionType: (row.action_type as string | null) ?? null,
    confidence: (row.confidence as number | null) ?? null,
    revision: row.revision as number,
    createdAt: isoRequired(row.created_at),
    updatedAt: isoRequired(row.updated_at),
    deletedAt: iso(row.deleted_at),
  };
}

function mapContext(row: Record<string, unknown>): TaskContextRow {
  return {
    taskId: row.task_id as string,
    noteRefs: (row.note_refs as unknown[] | null) ?? [],
    urls: (row.urls as string[] | null) ?? [],
    artifactIds: (row.artifact_ids as string[] | null) ?? [],
    guidance: (row.guidance as string | null) ?? null,
  };
}

function mapRun(row: Record<string, unknown>): AgentRunRow {
  return {
    id: row.id as string,
    taskId: row.task_id as string,
    provider: row.provider as Provider,
    state: row.state as AgentRunState,
    providerSessionId: (row.provider_session_id as string | null) ?? null,
    project: row.project as string,
    requiresConnectedWorker: row.requires_connected_worker as boolean,
    attemptCount: row.attempt_count as number,
    resumeCount: row.resume_count as number,
    autoRetryCount: row.auto_retry_count as number,
    nextAttemptAt: iso(row.next_attempt_at),
    lastOutcome: (row.last_outcome as string | null) ?? null,
    lastError: (row.last_error as string | null) ?? null,
    startedAt: iso(row.started_at),
    lastActivityAt: isoRequired(row.last_activity_at),
    completedAt: iso(row.completed_at),
    revision: row.revision as number,
  };
}

function mapMessage(row: Record<string, unknown>): AgentMessageRow {
  return {
    id: row.id as string,
    runId: row.run_id as string,
    seq: row.seq as number,
    role: row.role as AgentMessageRow["role"],
    kind: row.kind as MessageKind,
    content: row.content as string,
    links: (row.links as TaskLinkJSON[] | null) ?? [],
    providerTurnId: (row.provider_turn_id as string | null) ?? null,
    createdAt: isoRequired(row.created_at),
  };
}

function mapArtifact(row: Record<string, unknown>): ArtifactRow {
  return {
    id: row.id as string,
    taskId: row.task_id as string,
    runId: (row.run_id as string | null) ?? null,
    kind: row.kind as string,
    title: row.title as string,
    storageKey: row.storage_key as string,
    mime: (row.mime as string | null) ?? null,
    sizeBytes: row.size_bytes === null || row.size_bytes === undefined ? null : Number(row.size_bytes),
    createdBy: (row.created_by as string | null) ?? null,
    createdAt: isoRequired(row.created_at),
  };
}

function mapLease(row: Record<string, unknown>): LeaseRow {
  return {
    id: row.id as string,
    taskId: row.task_id as string,
    clientId: row.client_id as string,
    createdAt: isoRequired(row.created_at),
    renewedAt: iso(row.renewed_at),
    expiresAt: isoRequired(row.expires_at),
    released: row.released as boolean,
  };
}

function mapEvent(row: Record<string, unknown>): TaskEventRow {
  return {
    seq: Number(row.seq),
    taskId: row.task_id as string,
    runId: (row.run_id as string | null) ?? null,
    actor: (row.actor as string | null) ?? null,
    type: row.type as string,
    payload: (row.payload as Record<string, unknown> | null) ?? {},
    createdAt: isoRequired(row.created_at),
  };
}

// ---------------------------------------------------------------------------
// Shared transaction-scoped helpers
// ---------------------------------------------------------------------------

/**
 * Wraps `tx.json(...)` with a loose parameter type. postgres.js's own
 * `JSONValue` type requires plain index-signature objects/arrays, which our
 * named row/DTO interfaces (e.g. `TaskLinkJSON[]`) don't structurally match
 * even though they're valid JSON at runtime — this is a type-level-only gap
 * in postgres.js's typings, not a runtime concern.
 */
function jsonb(tx: TransactionSql, value: unknown) {
  return tx.json(value as Parameters<TransactionSql["json"]>[0]);
}

interface EventInput {
  taskId: string;
  runId: string | null;
  actor: string | null;
  type: string;
  payload: Record<string, unknown>;
}

async function insertEvent(tx: TransactionSql, input: EventInput, now: Date): Promise<TaskEventRow> {
  const rows = await tx`
    insert into task_events (task_id, run_id, actor, type, payload, created_at)
    values (${input.taskId}, ${input.runId}, ${input.actor}, ${input.type}, ${jsonb(tx, input.payload)}, ${now})
    returning *
  `;
  return mapEvent(rows[0] as Record<string, unknown>);
}

/** Loads the full ExpandedTask graph inside the caller's transaction. */
async function loadExpandedTask(tx: TransactionSql, taskId: string): Promise<Result<ExpandedTask>> {
  const taskRows = await tx`select * from tasks where id = ${taskId} and deleted_at is null`;
  const taskRow = taskRows[0] as Record<string, unknown> | undefined;
  if (!taskRow) return { ok: false, error: "not_found" };

  const contextRows = await tx`select * from task_context where task_id = ${taskId}`;
  const runRows = await tx`select * from agent_runs where task_id = ${taskId}`;
  const runRow = runRows[0] as Record<string, unknown> | undefined;

  const messageRows = runRow
    ? await tx`select * from agent_messages where run_id = ${runRow.id as string} order by seq asc`
    : [];
  const artifactRows = await tx`select * from artifacts where task_id = ${taskId} order by created_at asc`;
  const leaseRows = await tx`select * from leases where task_id = ${taskId} and released = false`;

  return {
    ok: true,
    value: {
      task: mapTask(taskRow),
      context: contextRows[0] ? mapContext(contextRows[0] as Record<string, unknown>) : null,
      run: runRow ? mapRun(runRow) : null,
      messages: (messageRows as Record<string, unknown>[]).map(mapMessage),
      artifacts: (artifactRows as Record<string, unknown>[]).map(mapArtifact),
      lease: leaseRows[0] ? mapLease(leaseRows[0] as Record<string, unknown>) : null,
    },
  };
}

/** Fragments joined with a literal comma, for dynamic SET/WHERE lists (postgres.js "Building queries" pattern). */
function joinComma(tx: TransactionSql, fragments: ReturnType<TransactionSql>[]) {
  return fragments.flatMap((f, i) => (i === 0 ? [f] : [tx`,`, f]));
}
function joinAnd(tx: TransactionSql, fragments: ReturnType<TransactionSql>[]) {
  return fragments.flatMap((f, i) => (i === 0 ? [f] : [tx`and`, f]));
}

/**
 * How a run's `completed_at` should move when its state changes to `state`.
 * `touch: false` means "leave completed_at exactly as it is". Mirrors the
 * intuition that a run is "completed" (has a completedAt) exactly while its
 * state is `completed` or `cancelled`, and is cleared when work resumes
 * (`queued`/`running`) — `needs_input`/`failed`/`interrupted` don't move it
 * either way (interface gives no signal either way for those transitions).
 */
function completedAtForState(state: AgentRunState, now: Date): { touch: boolean; value: Date | null } {
  switch (state) {
    case "completed":
    case "cancelled":
      return { touch: true, value: now };
    case "queued":
    case "running":
      return { touch: true, value: null };
    default:
      return { touch: false, value: null };
  }
}

async function findActiveLease(tx: TransactionSql, taskId: string): Promise<Record<string, unknown> | undefined> {
  const rows = await tx`select * from leases where task_id = ${taskId} and released = false for update`;
  return rows[0] as Record<string, unknown> | undefined;
}

/** Verifies `client` currently holds the task's live lease; only enforced for `worker` clients (`user_app` appends freely per store.ts). */
function leaseFailure(
  leaseRow: Record<string, unknown> | undefined,
  clientId: string,
  now: Date,
): StoreError | null {
  if (!leaseRow) return "lease_required";
  if (leaseRow.client_id !== clientId) return "lease_required";
  if (new Date(leaseRow.expires_at as string) < now) return "lease_expired";
  return null;
}

// ---------------------------------------------------------------------------
// PgStore
// ---------------------------------------------------------------------------

export class PgStore implements Store {
  constructor(private readonly sql: Sql) {}

  // ---- auth ----

  async getClientByTokenHash(tokenHash: string): Promise<ClientRow | null> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`select * from clients where token_hash = ${tokenHash} and enabled = true`;
      return rows[0] ? mapClient(rows[0] as Record<string, unknown>) : null;
    });
  }

  async touchClientSeen(clientId: string, now: Date): Promise<void> {
    await this.sql.begin(async (tx) => {
      await tx`update clients set last_seen_at = ${now}, updated_at = ${now} where id = ${clientId}`;
    });
  }

  // ---- idempotency ----

  async getIdempotent(
    clientId: string,
    key: string,
    route: string,
  ): Promise<{ status: number; response: unknown } | null> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`
        select status, response from idempotency_keys
        where client_id = ${clientId} and key = ${key} and route = ${route}
      `;
      const row = rows[0] as Record<string, unknown> | undefined;
      return row ? { status: row.status as number, response: row.response } : null;
    });
  }

  async putIdempotent(
    clientId: string,
    key: string,
    route: string,
    status: number,
    response: unknown,
  ): Promise<void> {
    await this.sql.begin(async (tx) => {
      await tx`
        insert into idempotency_keys (client_id, key, route, status, response)
        values (${clientId}, ${key}, ${route}, ${status}, ${jsonb(tx, response as object)})
        on conflict (client_id, key, route) do nothing
      `;
    });
  }

  // ---- tasks ----

  async createTask(input: CreateTaskInput, actor: string, now: Date): Promise<Result<TaskRow>> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`
        insert into tasks (
          id, title, notes, stage, owner, selected_provider, priority,
          scheduled_at, estimate_minutes, tags, links, source, list_id
        ) values (
          ${input.id ?? tx`gen_random_uuid()`},
          ${input.title},
          ${input.notes ?? ""},
          ${input.stage ?? "inbox"},
          ${input.owner ?? "me"},
          ${input.selectedProvider ?? null},
          ${input.priority ?? "normal"},
          ${input.scheduledAt ?? null},
          ${input.estimateMinutes ?? 30},
          ${tx.array(input.tags ?? [])},
          ${jsonb(tx, input.links ?? [])},
          ${input.source ?? "manual"},
          ${input.listId ?? null}
        )
        returning *
      `;
      const taskRow = rows[0] as Record<string, unknown>;
      const taskId = taskRow.id as string;

      if (input.context) {
        await tx`
          insert into task_context (task_id, note_refs, urls, artifact_ids, guidance)
          values (
            ${taskId},
            ${jsonb(tx, input.context.noteRefs ?? [])},
            ${jsonb(tx, input.context.urls ?? [])},
            ${jsonb(tx, input.context.artifactIds ?? [])},
            ${input.context.guidance ?? null}
          )
        `;
      }

      // `project` has no home on `tasks` (it belongs to agent_runs). When the
      // caller supplies one at creation time (typically a direct
      // owner=agent delegation), pre-create the run so the project is already
      // resolvable at first claim — claimTask has no project parameter, so
      // this is the only place it can be captured. Mirrors memory.ts.
      let runId: string | null = null;
      if (input.project !== undefined) {
        const provider =
          input.selectedProvider && input.selectedProvider !== "any" ? input.selectedProvider : "claude";
        const runRows = await tx`
          insert into agent_runs (task_id, provider, state, project)
          values (${taskId}, ${provider}, 'queued', ${input.project})
          returning id
        `;
        runId = (runRows[0] as Record<string, unknown>).id as string;
      }

      await insertEvent(tx, { taskId, runId, actor, type: "task_created", payload: {} }, now);

      return { ok: true, value: mapTask(taskRow) };
    });
  }

  async listTasks(filter: TaskFilter, now: Date): Promise<TaskRow[]> {
    return this.sql.begin(async (tx) => {
      const conditions: ReturnType<TransactionSql>[] = [tx`deleted_at is null`];
      if (filter.stage) conditions.push(tx`stage = ${filter.stage}`);
      if (filter.owner) conditions.push(tx`owner = ${filter.owner}`);
      if (filter.provider) conditions.push(tx`selected_provider = ${filter.provider}`);
      if (filter.updatedAfter) conditions.push(tx`updated_at > ${new Date(filter.updatedAfter)}`);

      if (filter.claimableBy) {
        // Mirrors src/domain/queue.ts's `isClaimable` predicate, evaluated in
        // SQL: owner/stage/blocked here, ledger approval via
        // `requiresLedgerApproval` (MeetingTaskSource.swift), and the run's
        // requiresConnectedWorker/backoff gates via a correlated subquery
        // (no run row at all is claimable — those two gates only ever
        // *restrict*, they never require a run to exist).
        conditions.push(tx`owner = 'agent'`);
        conditions.push(tx`stage in ('for_agent', 'queued')`);
        conditions.push(tx`blocked_by_task_id is null`);
        conditions.push(tx`not (source = ${MEETING_LEDGER_SOURCE} and agent_approval_granted = false)`);
        conditions.push(
          tx`(selected_provider is null or selected_provider = 'any' or selected_provider = ${filter.claimableBy})`,
        );
        conditions.push(tx`
          not exists (
            select 1 from agent_runs r
            where r.task_id = tasks.id
              and (r.requires_connected_worker = true or (r.next_attempt_at is not null and r.next_attempt_at > ${now}))
          )
        `);
      }

      const where = joinAnd(tx, conditions);
      const limit = filter.limit ?? 200;

      // Claimable listings order like the agent queue (src/domain/queue.ts's
      // `compareQueueOrder`: priority rank, then createdAt, then id); a plain
      // listing has no such ordering requirement, so it's most-recently
      // touched first.
      const rows = filter.claimableBy
        ? await tx`
            select * from tasks where ${where}
            order by
              case priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 when 'low' then 3 else 4 end,
              created_at asc,
              id asc
            limit ${limit}
          `
        : await tx`select * from tasks where ${where} order by updated_at desc limit ${limit}`;

      return (rows as Record<string, unknown>[]).map(mapTask);
    });
  }

  async getTask(taskId: string): Promise<Result<ExpandedTask>> {
    return this.sql.begin(async (tx) => loadExpandedTask(tx, taskId));
  }

  async updateTask(
    taskId: string,
    patch: TaskPatch,
    ifRevision: number,
    actor: string,
    now: Date,
  ): Promise<Result<TaskRow>> {
    return this.sql.begin(async (tx) => {
      const fragments: ReturnType<TransactionSql>[] = [];
      if (patch.title !== undefined) fragments.push(tx`title = ${patch.title}`);
      if (patch.notes !== undefined) fragments.push(tx`notes = ${patch.notes}`);
      if (patch.stage !== undefined) fragments.push(tx`stage = ${patch.stage}`);
      if (patch.owner !== undefined) fragments.push(tx`owner = ${patch.owner}`);
      if (patch.priority !== undefined) fragments.push(tx`priority = ${patch.priority}`);
      if (patch.scheduledAt !== undefined) fragments.push(tx`scheduled_at = ${patch.scheduledAt}`);
      if (patch.dueAt !== undefined) fragments.push(tx`due_at = ${patch.dueAt}`);
      if (patch.estimateMinutes !== undefined) fragments.push(tx`estimate_minutes = ${patch.estimateMinutes}`);
      if (patch.tags !== undefined) fragments.push(tx`tags = ${tx.array(patch.tags)}`);
      if (patch.links !== undefined) fragments.push(tx`links = ${jsonb(tx, patch.links)}`);
      if (patch.listId !== undefined) fragments.push(tx`list_id = ${patch.listId}`);
      if (patch.blockedReason !== undefined) fragments.push(tx`blocked_reason = ${patch.blockedReason}`);
      fragments.push(tx`revision = ${ifRevision + 1}`);
      fragments.push(tx`updated_at = ${now}`);

      const setClause = joinComma(tx, fragments);
      const rows = await tx`
        update tasks set ${setClause}
        where id = ${taskId} and revision = ${ifRevision} and deleted_at is null
        returning *
      `;

      if (rows.length === 0) {
        const existing = await tx`select id from tasks where id = ${taskId} and deleted_at is null`;
        return existing.length === 0
          ? ({ ok: false, error: "not_found" } as const)
          : ({ ok: false, error: "revision_conflict" } as const);
      }

      const taskRow = rows[0] as Record<string, unknown>;
      await insertEvent(tx, { taskId, runId: null, actor, type: "task_updated", payload: { patch } }, now);
      return { ok: true, value: mapTask(taskRow) };
    });
  }

  async setProvider(taskId: string, provider: Provider | null, actor: string, now: Date): Promise<Result<TaskRow>> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`
        update tasks
        set selected_provider = ${provider}, revision = revision + 1, updated_at = ${now}
        where id = ${taskId} and deleted_at is null
        returning *
      `;
      if (rows.length === 0) return { ok: false, error: "not_found" };
      const taskRow = rows[0] as Record<string, unknown>;
      await insertEvent(tx, { taskId, runId: null, actor, type: "provider_set", payload: { provider } }, now);
      return { ok: true, value: mapTask(taskRow) };
    });
  }

  // ---- worker loop ----

  async claimTask(
    taskId: string,
    client: ClientRow,
    ttlSeconds: number,
    now: Date,
  ): Promise<Result<{ lease: LeaseRow; task: ExpandedTask }>> {
    return this.sql.begin(async (tx) => {
      const taskRows = await tx`select * from tasks where id = ${taskId} and deleted_at is null for update`;
      const taskRow = taskRows[0] as Record<string, unknown> | undefined;
      if (!taskRow) return { ok: false, error: "not_found" };

      const runRows = await tx`select * from agent_runs where task_id = ${taskId} for update`;
      let runRow = runRows[0] as Record<string, unknown> | undefined;

      // Lazily release an expired lease. Per this slice's brief, the inline
      // claim-time release is the simple "back to queued / run interrupted"
      // form — the fuller gated-vs-not routing (needs_review on a gated
      // action) is the periodic expireLeases() sweep's job, not claim's.
      const activeLease = await findActiveLease(tx, taskId);
      let taskStage = taskRow.stage as TaskStage;
      if (activeLease) {
        const expired = new Date(activeLease.expires_at as string) < now;
        if (!expired) return { ok: false, error: "already_leased" };

        await tx`update leases set released = true where id = ${activeLease.id as string}`;
        await insertEvent(
          tx,
          { taskId, runId: (runRow?.id as string) ?? null, actor: null, type: "lease_expired", payload: {} },
          now,
        );
        if (runRow) {
          const updated = await tx`
            update agent_runs set state = 'interrupted', last_error = ${"Lease expired; run interrupted."}, updated_at = ${now}
            where id = ${runRow.id as string}
            returning *
          `;
          runRow = updated[0] as Record<string, unknown>;
        }
        taskStage = "queued";
        await tx`update tasks set stage = 'queued', updated_at = ${now} where id = ${taskId}`;
      }

      // Provider compatibility: a client with no provider can never claim; a
      // task with no selected provider (or 'any') matches any
      // provider-carrying worker; otherwise it's an exact match.
      if (client.provider === null) {
        return { ok: false, error: "not_claimable", detail: "client has no provider" };
      }
      const selectedProvider = taskRow.selected_provider as Provider | null;
      if (selectedProvider !== null && selectedProvider !== "any" && selectedProvider !== client.provider) {
        return { ok: false, error: "not_claimable", detail: "provider mismatch" };
      }

      const queueTask: QueueTask = {
        uid: taskId,
        owner: taskRow.owner as QueueTask["owner"],
        stage: taskStage,
        isBlocked: taskRow.blocked_by_task_id !== null,
        priority: taskRow.priority as QueueTask["priority"],
        createdAt: isoRequired(taskRow.created_at),
        requiresAgentApproval: requiresLedgerApproval(taskRow.source as string),
        agentApprovalGranted: taskRow.agent_approval_granted as boolean,
        run: runRow
          ? {
              requiresConnectedWorker: runRow.requires_connected_worker as boolean,
              nextAttemptAt: iso(runRow.next_attempt_at),
            }
          : null,
      };
      if (!isClaimable(queueTask, now)) {
        return { ok: false, error: "not_claimable" };
      }

      const expiresAt = new Date(now.getTime() + ttlSeconds * 1000);
      let newLeaseRow: Record<string, unknown>;
      try {
        const inserted = await tx`
          insert into leases (task_id, client_id, expires_at) values (${taskId}, ${client.id}, ${expiresAt})
          returning *
        `;
        newLeaseRow = inserted[0] as Record<string, unknown>;
      } catch (err) {
        if (isUniqueViolation(err)) return { ok: false, error: "already_leased" };
        throw err;
      }

      let updatedRunRow: Record<string, unknown>;
      if (!runRow) {
        const inserted = await tx`
          insert into agent_runs (task_id, provider, state, attempt_count, resume_count, started_at, last_activity_at)
          values (${taskId}, ${client.provider}, 'running', 1, 0, ${now}, ${now})
          returning *
        `;
        updatedRunRow = inserted[0] as Record<string, unknown>;
      } else {
        const resumeInc = runRow.provider_session_id ? 1 : 0;
        const updated = await tx`
          update agent_runs
          set state = 'running',
              attempt_count = attempt_count + 1,
              resume_count = resume_count + ${resumeInc},
              started_at = coalesce(started_at, ${now}),
              last_activity_at = ${now},
              updated_at = ${now}
          where id = ${runRow.id as string}
          returning *
        `;
        updatedRunRow = updated[0] as Record<string, unknown>;
      }

      await tx`update tasks set stage = 'in_progress', updated_at = ${now} where id = ${taskId}`;
      await insertEvent(
        tx,
        { taskId, runId: updatedRunRow.id as string, actor: client.id, type: "task_claimed", payload: {} },
        now,
      );

      const expanded = await loadExpandedTask(tx, taskId);
      if (!expanded.ok) return expanded;
      return { ok: true, value: { lease: mapLease(newLeaseRow), task: expanded.value } };
    });
  }

  async renewLease(leaseId: string, clientId: string, ttlSeconds: number, now: Date): Promise<Result<LeaseRow>> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`select * from leases where id = ${leaseId} for update`;
      const leaseRow = rows[0] as Record<string, unknown> | undefined;
      if (!leaseRow) return { ok: false, error: "not_found" };
      if (leaseRow.client_id !== clientId) return { ok: false, error: "lease_required" };
      if (leaseRow.released) return { ok: false, error: "lease_expired" };
      if (new Date(leaseRow.expires_at as string) < now) return { ok: false, error: "lease_expired" };

      const expiresAt = new Date(now.getTime() + ttlSeconds * 1000);
      const updated = await tx`
        update leases set expires_at = ${expiresAt}, renewed_at = ${now} where id = ${leaseId} returning *
      `;
      const taskId = leaseRow.task_id as string;
      await insertEvent(tx, { taskId, runId: null, actor: clientId, type: "lease_renewed", payload: {} }, now);
      return { ok: true, value: mapLease(updated[0] as Record<string, unknown>) };
    });
  }

  async releaseLease(leaseId: string, clientId: string, now: Date): Promise<Result<void>> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`select * from leases where id = ${leaseId} for update`;
      const leaseRow = rows[0] as Record<string, unknown> | undefined;
      if (!leaseRow) return { ok: false, error: "not_found" };
      if (leaseRow.client_id !== clientId) return { ok: false, error: "lease_required" };
      if (leaseRow.released) return { ok: true, value: undefined };

      await tx`update leases set released = true where id = ${leaseId}`;
      const taskId = leaseRow.task_id as string;
      await insertEvent(tx, { taskId, runId: null, actor: clientId, type: "lease_released", payload: {} }, now);
      return { ok: true, value: undefined };
    });
  }

  async expireLeases(now: Date): Promise<TaskEventRow[]> {
    return this.sql.begin(async (tx) => {
      const leaseRows = await tx`select * from leases where released = false and expires_at < ${now} for update`;
      const events: TaskEventRow[] = [];

      for (const leaseRow of leaseRows as Record<string, unknown>[]) {
        const taskId = leaseRow.task_id as string;
        const taskRows = await tx`select * from tasks where id = ${taskId} for update`;
        const taskRow = taskRows[0] as Record<string, unknown> | undefined;
        if (!taskRow) continue; // FK guarantees this shouldn't happen

        const runRows = await tx`select * from agent_runs where task_id = ${taskId} for update`;
        const runRow = runRows[0] as Record<string, unknown> | undefined;

        await tx`update leases set released = true where id = ${leaseRow.id as string}`;

        // Mirrors AgentTaskCoordinator.reconcileInterruptedRuns's two
        // reachable branches per the design doc's "Lease gap confirmed"
        // note: a gated action's completion is uncertain (-> needs_review,
        // run failed, matching decisionForOutcome("completion_uncertain"));
        // anything else just goes back to the queue with the run marked
        // interrupted (the DB's dedicated state for exactly this case).
        const gated = isGatedActionType(taskRow.action_type as string | null);
        const newTaskStage: TaskStage = gated ? "needs_review" : "queued";
        const newRunState: AgentRunState = gated ? "failed" : "interrupted";

        await tx`
          update tasks set stage = ${newTaskStage}, revision = revision + 1, updated_at = ${now} where id = ${taskId}
        `;
        if (runRow) {
          const lastError = gated
            ? "Lease expired mid-turn; completion uncertain."
            : "Lease expired; run interrupted.";
          const completedAtFragment = gated ? tx`, completed_at = ${now}` : tx``;
          await tx`
            update agent_runs
            set state = ${newRunState}, last_error = ${lastError}, updated_at = ${now} ${completedAtFragment}
            where id = ${runRow.id as string}
          `;
        }

        const event = await insertEvent(
          tx,
          { taskId, runId: (runRow?.id as string) ?? null, actor: null, type: "lease_expired", payload: { gated } },
          now,
        );
        events.push(event);
      }

      return events;
    });
  }

  // ---- conversation ----

  async appendMessage(
    taskId: string,
    client: ClientRow,
    input: MessageInput,
    now: Date,
  ): Promise<Result<AgentMessageRow>> {
    return this.sql.begin(async (tx) => {
      const taskRows = await tx`select id from tasks where id = ${taskId} and deleted_at is null for update`;
      if (!taskRows[0]) return { ok: false, error: "not_found" };

      const runRows = await tx`select * from agent_runs where task_id = ${taskId} for update`;
      const runRow = runRows[0] as Record<string, unknown> | undefined;
      if (!runRow) return { ok: false, error: "illegal_transition", detail: "no active run for task" };

      if (client.kind === "worker") {
        const activeLease = await findActiveLease(tx, taskId);
        const failure = leaseFailure(activeLease, client.id, now);
        if (failure) return { ok: false, error: failure };
      }

      const runId = runRow.id as string;
      const seqRows = await tx`select coalesce(max(seq), 0) as max from agent_messages where run_id = ${runId}`;
      const nextSeq = Number((seqRows[0] as Record<string, unknown>).max) + 1;

      const inserted = await tx`
        insert into agent_messages (run_id, seq, role, kind, content, links, provider_turn_id)
        values (
          ${runId}, ${nextSeq}, ${input.role}, ${input.kind}, ${input.content},
          ${jsonb(tx, input.links ?? [])}, ${input.providerTurnId ?? null}
        )
        returning *
      `;
      await tx`update agent_runs set last_activity_at = ${now}, updated_at = ${now} where id = ${runId}`;
      await insertEvent(tx, { taskId, runId, actor: client.id, type: "message_appended", payload: { kind: input.kind } }, now);

      return { ok: true, value: mapMessage(inserted[0] as Record<string, unknown>) };
    });
  }

  async applyOutcome(
    taskId: string,
    client: ClientRow,
    input: OutcomeInput,
    now: Date,
  ): Promise<Result<ExpandedTask>> {
    return this.sql.begin(async (tx) => {
      const taskRows = await tx`select * from tasks where id = ${taskId} and deleted_at is null for update`;
      const taskRow = taskRows[0] as Record<string, unknown> | undefined;
      if (!taskRow) return { ok: false, error: "not_found" };

      const runRows = await tx`select * from agent_runs where task_id = ${taskId} for update`;
      const runRow = runRows[0] as Record<string, unknown> | undefined;
      if (!runRow) return { ok: false, error: "illegal_transition", detail: "no active run for task" };

      const activeLease = await findActiveLease(tx, taskId);
      if (client.kind === "worker") {
        const failure = leaseFailure(activeLease, client.id, now);
        if (failure) return { ok: false, error: failure };
      }

      const decision = decisionForOutcome(input.outcome);
      const runId = runRow.id as string;

      // Message kind + content: "question" joins questions[]; "result" and
      // "error" per the brief; the three outcomes without an explicit named
      // kind get the closest fit (progress for the two non-terminal/neutral
      // outcomes, error for completion_uncertain since its run ends
      // `failed` just like a genuine failure).
      const kind = messageKindForOutcome(input.outcome);
      const content =
        input.outcome === "needs_input" && input.questions && input.questions.length > 0
          ? input.questions.join("\n")
          : input.outcome === "completed" && input.summary
            ? input.summary
            : input.message;

      const seqRows = await tx`select coalesce(max(seq), 0) as max from agent_messages where run_id = ${runId}`;
      const nextSeq = Number((seqRows[0] as Record<string, unknown>).max) + 1;
      await tx`
        insert into agent_messages (run_id, seq, role, kind, content, links, provider_turn_id)
        values (${runId}, ${nextSeq}, 'agent', ${kind}, ${content}, ${jsonb(tx, input.links ?? [])}, ${input.providerTurnId ?? null})
      `;

      // completed merges links onto the task.
      const mergedLinks =
        input.outcome === "completed" && input.links && input.links.length > 0
          ? [...((taskRow.links as TaskLinkJSON[] | null) ?? []), ...input.links]
          : ((taskRow.links as TaskLinkJSON[] | null) ?? []);

      const taskOwnerFragment = decision.taskOwner ? tx`, owner = ${decision.taskOwner}` : tx``;
      await tx`
        update tasks
        set stage = ${decision.taskStage}, links = ${jsonb(tx, mergedLinks)}, revision = revision + 1, updated_at = ${now}
            ${taskOwnerFragment}
        where id = ${taskId}
      `;

      const completedAt = completedAtForState(decision.runState, now);
      const lastError =
        input.outcome === "failed" || input.outcome === "completion_uncertain" ? (input.errorCategory ?? input.message) : null;
      const providerSessionFragment =
        input.providerSessionId !== undefined ? tx`, provider_session_id = ${input.providerSessionId}` : tx``;
      const completedAtFragment = completedAt.touch ? tx`, completed_at = ${completedAt.value}` : tx``;
      await tx`
        update agent_runs
        set state = ${decision.runState},
            last_outcome = ${input.outcome},
            last_error = ${lastError},
            requires_connected_worker = ${decision.requiresConnectedWorker},
            last_activity_at = ${now},
            updated_at = ${now}
            ${providerSessionFragment}
            ${completedAtFragment}
        where id = ${runId}
      `;

      if (activeLease && !activeLease.released) {
        await tx`update leases set released = true where id = ${activeLease.id as string}`;
      }

      await insertEvent(tx, { taskId, runId, actor: client.id, type: "outcome_reported", payload: { outcome: input.outcome } }, now);

      return loadExpandedTask(tx, taskId);
    });
  }

  async reply(taskId: string, content: string, actor: string, now: Date): Promise<Result<ExpandedTask>> {
    return this.sql.begin(async (tx) => {
      if (!content || content.trim() === "") {
        return { ok: false, error: "illegal_transition", detail: "reply content is empty" };
      }

      const taskRows = await tx`select * from tasks where id = ${taskId} and deleted_at is null for update`;
      const taskRow = taskRows[0] as Record<string, unknown> | undefined;
      if (!taskRow) return { ok: false, error: "not_found" };

      const runRows = await tx`select * from agent_runs where task_id = ${taskId} for update`;
      const runRow = runRows[0] as Record<string, unknown> | undefined;
      if (!runRow) return { ok: false, error: "illegal_transition", detail: "no active run for task" };

      const legal = canReply(
        taskRow.owner as "me" | "agent",
        taskRow.stage as TaskStage,
        runRow.state as AgentRunState,
      );
      if (!legal) return { ok: false, error: "illegal_transition" };

      const runId = runRow.id as string;
      const seqRows = await tx`select coalesce(max(seq), 0) as max from agent_messages where run_id = ${runId}`;
      const nextSeq = Number((seqRows[0] as Record<string, unknown>).max) + 1;
      await tx`
        insert into agent_messages (run_id, seq, role, kind, content)
        values (${runId}, ${nextSeq}, 'human', 'answer', ${content})
      `;

      await tx`update tasks set stage = 'queued', revision = revision + 1, updated_at = ${now} where id = ${taskId}`;
      await tx`update agent_runs set state = 'queued', last_activity_at = ${now}, updated_at = ${now} where id = ${runId}`;
      await insertEvent(tx, { taskId, runId, actor, type: "reply_posted", payload: {} }, now);

      return loadExpandedTask(tx, taskId);
    });
  }

  async review(
    taskId: string,
    action: ReviewActionKind,
    feedback: string | undefined,
    actor: string,
    now: Date,
  ): Promise<Result<ExpandedTask>> {
    return this.sql.begin(async (tx) => {
      const taskRows = await tx`select * from tasks where id = ${taskId} and deleted_at is null for update`;
      const taskRow = taskRows[0] as Record<string, unknown> | undefined;
      if (!taskRow) return { ok: false, error: "not_found" };

      const runRows = await tx`select * from agent_runs where task_id = ${taskId} for update`;
      const runRow = runRows[0] as Record<string, unknown> | undefined;

      const owner = taskRow.owner as "me" | "agent";
      const stage = taskRow.stage as TaskStage;
      const legal =
        action === "accept"
          ? stage === "needs_review"
          : action === "request_changes"
            ? canRequestChanges(owner, stage)
            : canTakeBack(owner, stage);
      if (!legal) return { ok: false, error: "illegal_transition" };

      const result = reviewAction(action, { requiresAgentApproval: requiresLedgerApproval(taskRow.source as string) });

      const ownerFragment = result.owner ? tx`, owner = ${result.owner}` : tx``;
      const completedAtFragment = result.stage === "done" ? tx`, completed_at = ${now}` : tx``;
      const grantFragment =
        result.agentApprovalGranted !== undefined ? tx`, agent_approval_granted = ${result.agentApprovalGranted}` : tx``;
      await tx`
        update tasks
        set stage = ${result.stage}, revision = revision + 1, updated_at = ${now}
            ${ownerFragment} ${completedAtFragment} ${grantFragment}
        where id = ${taskId}
      `;

      if (result.runState && runRow) {
        const completedAt = completedAtForState(result.runState, now);
        const completedAtRunFragment = completedAt.touch ? tx`, completed_at = ${completedAt.value}` : tx``;
        await tx`
          update agent_runs
          set state = ${result.runState}, last_activity_at = ${now}, updated_at = ${now} ${completedAtRunFragment}
          where id = ${runRow.id as string}
        `;
      }

      if (feedback && feedback.trim() !== "" && runRow) {
        const runId = runRow.id as string;
        const seqRows = await tx`select coalesce(max(seq), 0) as max from agent_messages where run_id = ${runId}`;
        const nextSeq = Number((seqRows[0] as Record<string, unknown>).max) + 1;
        await tx`
          insert into agent_messages (run_id, seq, role, kind, content)
          values (${runId}, ${nextSeq}, 'human', 'review_feedback', ${feedback})
        `;
      }

      await insertEvent(
        tx,
        { taskId, runId: (runRow?.id as string) ?? null, actor, type: `review_${action}`, payload: { action, feedback: feedback ?? null } },
        now,
      );

      return loadExpandedTask(tx, taskId);
    });
  }

  // ---- artifacts ----

  async createArtifact(input: ArtifactInput, actor: string, now: Date): Promise<Result<ArtifactRow>> {
    return this.sql.begin(async (tx) => {
      const taskRows = await tx`select id from tasks where id = ${input.taskId} and deleted_at is null`;
      if (!taskRows[0]) return { ok: false, error: "not_found" };

      const inserted = await tx`
        insert into artifacts (task_id, run_id, kind, title, storage_key, mime, size_bytes, created_by, created_at)
        values (
          ${input.taskId}, ${input.runId ?? null}, ${input.kind}, ${input.title}, ${input.storageKey},
          ${input.mime ?? null}, ${input.sizeBytes ?? null}, ${actor}, ${now}
        )
        returning *
      `;
      const artifactRow = inserted[0] as Record<string, unknown>;
      await insertEvent(
        tx,
        {
          taskId: input.taskId,
          runId: input.runId ?? null,
          actor,
          type: "artifact_created",
          payload: { artifactId: artifactRow.id, kind: input.kind },
        },
        now,
      );
      return { ok: true, value: mapArtifact(artifactRow) };
    });
  }

  async getArtifact(artifactId: string): Promise<ArtifactRow | null> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`select * from artifacts where id = ${artifactId}`;
      return rows[0] ? mapArtifact(rows[0] as Record<string, unknown>) : null;
    });
  }

  // ---- sync cursor ----

  async listEvents(afterSeq: number, limit: number): Promise<TaskEventRow[]> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`select * from task_events where seq > ${afterSeq} order by seq asc limit ${limit}`;
      return (rows as Record<string, unknown>[]).map(mapEvent);
    });
  }
}

function messageKindForOutcome(outcome: TurnOutcome): MessageKind {
  switch (outcome) {
    case "needs_input":
      return "question";
    case "completed":
      return "result";
    case "failed":
      return "error";
    case "completion_uncertain":
      return "error";
    case "cancelled":
    case "requires_connected_worker":
      return "progress";
  }
}

/** SQLSTATE 23505 = unique_violation (postgres.js's `PostgresError.code`). */
function isUniqueViolation(err: unknown): boolean {
  return typeof err === "object" && err !== null && "code" in err && (err as { code: unknown }).code === "23505";
}
