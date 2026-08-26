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
  IdempotencyReservation,
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
} from "../domain/stages.ts";
import {
  compareQueueOrder,
  computeIsBlocked,
  isClaimable,
  providerMatches,
  requiresLedgerApproval,
  type QueueTask,
} from "../domain/queue.ts";
import {
  agentApprovalGrantForMove,
  approveTarget,
  canReply,
  canRequestChanges,
  canTakeBack,
  decisionForOutcome,
  freshAttemptRunReset,
  isGatedActionType,
  messageKindForOutcome,
  reviewAction,
  type ApproveContext,
  type ReviewActionKind,
} from "../domain/transitions.ts";
import {
  EVENT_APPROVED,
  EVENT_LEASE_EXPIRED,
  EVENT_LEASE_RELEASED,
  EVENT_LEASE_RENEWED,
  EVENT_MESSAGE_APPENDED,
  EVENT_OUTCOME_APPLIED,
  EVENT_PROVIDER_ASSIGNED,
  EVENT_REPLIED,
  EVENT_REVIEWED,
  EVENT_TASK_CLAIMED,
  EVENT_TASK_CREATED,
  EVENT_TASK_UPDATED,
  approvedPayload,
  leaseExpiredPayload,
  leaseReleasedPayload,
  leaseRenewedPayload,
  messageAppendedPayload,
  outcomeAppliedPayload,
  providerAssignedPayload,
  repliedPayload,
  reviewedPayload,
  taskClaimedPayload,
  taskCreatedPayload,
  taskUpdatedPayload,
} from "../domain/events.ts";

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
  // `object`, not `Record<string, unknown>` — see store.ts's TaskEventRow
  // comment: payloads come from src/domain/events.ts's typed builders, which
  // have no index signature.
  payload: object;
}

async function insertEvent(tx: TransactionSql, input: EventInput, now: Date): Promise<TaskEventRow> {
  const rows = await tx`
    insert into task_events (task_id, run_id, actor, type, payload, created_at)
    values (${input.taskId}, ${input.runId}, ${input.actor}, ${input.type}, ${jsonb(tx, input.payload)}, ${now})
    returning *
  `;
  return mapEvent(rows[0] as Record<string, unknown>);
}

/**
 * Loads the full ExpandedTask graph inside the caller's transaction.
 * `context`/`run`/`artifacts`/`lease` don't depend on one another, so they're
 * fired together via `Promise.all` and pipelined by postgres.js over the
 * transaction's one connection, rather than four sequential round trips;
 * `messages` genuinely depends on `run`'s id, so it stays a separate,
 * dependent query after the batch resolves.
 */
async function loadExpandedTask(tx: TransactionSql, taskId: string): Promise<Result<ExpandedTask>> {
  const taskRows = await tx`select * from tasks where id = ${taskId} and deleted_at is null`;
  const taskRow = taskRows[0] as Record<string, unknown> | undefined;
  if (!taskRow) return { ok: false, error: "not_found" };

  const [contextRows, runRows, artifactRows, leaseRows] = await Promise.all([
    tx`select * from task_context where task_id = ${taskId}`,
    tx`select * from agent_runs where task_id = ${taskId}`,
    tx`select * from artifacts where task_id = ${taskId} order by created_at asc`,
    tx`select * from leases where task_id = ${taskId} and released = false`,
  ]);
  const runRow = runRows[0] as Record<string, unknown> | undefined;

  const messageRows = runRow
    ? await tx`select * from agent_messages where run_id = ${runRow.id as string} order by seq asc`
    : [];

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

  async reserveIdempotent(clientId: string, key: string, route: string, now: Date): Promise<IdempotencyReservation> {
    return this.sql.begin(async (tx) => {
      const inserted = await tx`
        insert into idempotency_keys (client_id, key, route, state, created_at)
        values (${clientId}, ${key}, ${route}, 'pending', ${now})
        on conflict (client_id, key, route) do nothing
        returning id
      `;
      if (inserted.length > 0) return { status: "reserved" };

      const rows = await tx`
        select state, status, response from idempotency_keys
        where client_id = ${clientId} and key = ${key} and route = ${route}
      `;
      const row = rows[0] as Record<string, unknown>;
      if (row.state === "pending") return { status: "in_flight" };
      return { status: "complete", response: { status: row.status as number, response: row.response } };
    });
  }

  async completeIdempotent(clientId: string, key: string, route: string, status: number, response: unknown): Promise<void> {
    await this.sql.begin(async (tx) => {
      await tx`
        update idempotency_keys
        set state = 'complete', status = ${status}, response = ${jsonb(tx, response as object)}
        where client_id = ${clientId} and key = ${key} and route = ${route}
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

      await insertEvent(tx, { taskId, runId, actor, type: EVENT_TASK_CREATED, payload: taskCreatedPayload(taskRow.title as string, taskRow.stage as TaskStage) }, now);

      return { ok: true, value: mapTask(taskRow) };
    });
  }

  async listTasks(filter: TaskFilter, now: Date): Promise<TaskRow[]> {
    return this.sql.begin(async (tx) => {
      if (filter.claimableBy) return this.listClaimableTasks(tx, filter, now);

      const conditions: ReturnType<TransactionSql>[] = [tx`deleted_at is null`];
      if (filter.stage) conditions.push(tx`stage = ${filter.stage}`);
      if (filter.owner) conditions.push(tx`owner = ${filter.owner}`);
      if (filter.provider) conditions.push(tx`selected_provider = ${filter.provider}`);
      if (filter.updatedAfter) conditions.push(tx`updated_at > ${new Date(filter.updatedAfter)}`);

      const where = joinAnd(tx, conditions);
      const limit = filter.limit ?? 200;
      const rows = await tx`select * from tasks where ${where} order by updated_at desc limit ${limit}`;
      return (rows as Record<string, unknown>[]).map(mapTask);
    });
  }

  /**
   * The `claimableBy` branch of `listTasks`. Rewritten (item C/D4 of the
   * fix pass) to load owner/stage-filtered candidate rows — joined once to
   * each candidate's blocker task (for `computeIsBlocked`'s "blocker
   * exists and isn't done" condition, which the old SQL never checked) and
   * its run (for `isClaimable`'s connected-worker/backoff gates) — then run
   * every candidate through the SAME domain predicates `claimTask` uses
   * (`isClaimable`, `providerMatches`), rather than a hand-rolled SQL
   * mirror of them that had already drifted (missing `blockedReason`,
   * ledger-approval spelled out ad hoc). This is the single source of
   * truth the task brief calls for; loading candidates by owner/stage and
   * filtering in TS is fine at this data scale per the brief.
   */
  private async listClaimableTasks(tx: TransactionSql, filter: TaskFilter, now: Date): Promise<TaskRow[]> {
    const claimableBy = filter.claimableBy!;
    const conditions: ReturnType<TransactionSql>[] = [
      tx`t.deleted_at is null`,
      tx`t.owner = 'agent'`,
      tx`t.stage in ('for_agent', 'queued')`,
    ];
    if (filter.stage) conditions.push(tx`t.stage = ${filter.stage}`);
    if (filter.owner) conditions.push(tx`t.owner = ${filter.owner}`);
    if (filter.provider) conditions.push(tx`t.selected_provider = ${filter.provider}`);
    if (filter.updatedAfter) conditions.push(tx`t.updated_at > ${new Date(filter.updatedAfter)}`);
    const where = joinAnd(tx, conditions);

    const rows = await tx`
      select
        t.*,
        b.stage as blocker_stage,
        r.id as run_id,
        r.requires_connected_worker as run_requires_connected_worker,
        r.next_attempt_at as run_next_attempt_at
      from tasks t
      left join tasks b on b.id = t.blocked_by_task_id
      left join agent_runs r on r.task_id = t.id
      where ${where}
    `;

    const candidates = (rows as Record<string, unknown>[]).map((row) => {
      const task = mapTask(row);
      const isBlocked = computeIsBlocked({
        blockedByTaskId: task.blockedByTaskId,
        blockerStage: (row.blocker_stage as TaskStage | null) ?? null,
        blockedReason: task.blockedReason,
      });
      const queueTask: QueueTask = {
        uid: task.id,
        owner: task.owner,
        stage: task.stage,
        isBlocked,
        priority: task.priority,
        createdAt: task.createdAt,
        requiresAgentApproval: requiresLedgerApproval(task.source),
        agentApprovalGranted: task.agentApprovalGranted,
        run:
          row.run_id !== null && row.run_id !== undefined
            ? {
                requiresConnectedWorker: row.run_requires_connected_worker as boolean,
                nextAttemptAt: iso(row.run_next_attempt_at),
              }
            : null,
      };
      return { task, queueTask };
    });

    const claimable = candidates.filter(
      ({ task, queueTask }) => isClaimable(queueTask, now) && providerMatches(task.selectedProvider, claimableBy),
    );
    claimable.sort((a, b) => compareQueueOrder(a.queueTask, b.queueTask));

    const limit = filter.limit ?? 200;
    return claimable.slice(0, limit).map(({ task }) => task);
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
      if (patch.stage !== undefined) {
        fragments.push(tx`stage = ${patch.stage}`);
        // A board-lane move on a ledger-imported meeting task grants/revokes
        // the Do/Don't approval bit alongside the stage change (mirrors
        // PersonalBoard.move, PersonalBoard.swift:72-75). Locked read (not
        // just the outer row lock from `revision =` below, which only takes
        // effect once we already know the new value) so a concurrent PATCH
        // can't race the grant computation.
        const currentRows = await tx`
          select source, agent_approval_granted from tasks
          where id = ${taskId} and deleted_at is null
          for update
        `;
        const current = currentRows[0] as Record<string, unknown> | undefined;
        if (current) {
          const newGrant = agentApprovalGrantForMove(
            requiresLedgerApproval(current.source as string),
            current.agent_approval_granted as boolean,
            patch.stage,
          );
          fragments.push(tx`agent_approval_granted = ${newGrant}`);
        }
      }
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
      await insertEvent(tx, { taskId, runId: null, actor, type: EVENT_TASK_UPDATED, payload: taskUpdatedPayload(patch) }, now);
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
      await insertEvent(tx, { taskId, runId: null, actor, type: EVENT_PROVIDER_ASSIGNED, payload: providerAssignedPayload(provider) }, now);
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
          { taskId, runId: (runRow?.id as string) ?? null, actor: null, type: EVENT_LEASE_EXPIRED, payload: leaseExpiredPayload(activeLease.id as string) },
          now,
        );
        if (runRow) {
          const updated = await tx`
            update agent_runs
            set state = 'interrupted', last_error = ${"Lease expired; run interrupted."}, revision = revision + 1, updated_at = ${now}
            where id = ${runRow.id as string}
            returning *
          `;
          runRow = updated[0] as Record<string, unknown>;
        }
        taskStage = "queued";
        await tx`update tasks set stage = 'queued', revision = revision + 1, updated_at = ${now} where id = ${taskId}`;
      }

      // Provider compatibility: a client with no provider can never claim; a
      // task with no selected provider (or 'any') matches any
      // provider-carrying worker; otherwise it's an exact match.
      if (client.provider === null) {
        return { ok: false, error: "not_claimable", detail: "client has no provider" };
      }
      const selectedProvider = taskRow.selected_provider as Provider | null;
      if (!providerMatches(selectedProvider, client.provider)) {
        return { ok: false, error: "not_claimable", detail: "provider mismatch" };
      }

      // Blocked-ness: mirrors src/domain/queue.ts's `computeIsBlocked`
      // exactly (a blocker task that exists and isn't `done`, OR a non-empty
      // `blockedReason`) — the old inline check here only looked at
      // `blocked_by_task_id is not null`, ignoring both the blocker's actual
      // stage and `blockedReason` entirely.
      const blockedByTaskId = taskRow.blocked_by_task_id as string | null;
      let blockerStage: TaskStage | null = null;
      if (blockedByTaskId) {
        const blockerRows = await tx`select stage from tasks where id = ${blockedByTaskId}`;
        blockerStage = (blockerRows[0] as Record<string, unknown> | undefined)?.stage as TaskStage | undefined ?? null;
      }
      const isBlocked = computeIsBlocked({
        blockedByTaskId,
        blockerStage,
        blockedReason: taskRow.blocked_reason as string,
      });

      const queueTask: QueueTask = {
        uid: taskId,
        owner: taskRow.owner as QueueTask["owner"],
        stage: taskStage,
        isBlocked,
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
              revision = revision + 1,
              updated_at = ${now}
          where id = ${runRow.id as string}
          returning *
        `;
        updatedRunRow = updated[0] as Record<string, unknown>;
      }

      await tx`update tasks set stage = 'in_progress', revision = revision + 1, updated_at = ${now} where id = ${taskId}`;
      await insertEvent(
        tx,
        { taskId, runId: updatedRunRow.id as string, actor: client.id, type: EVENT_TASK_CLAIMED, payload: taskClaimedPayload(newLeaseRow.id as string, updatedRunRow.id as string) },
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
      await insertEvent(tx, { taskId, runId: null, actor: clientId, type: EVENT_LEASE_RENEWED, payload: leaseRenewedPayload(leaseId) }, now);
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
      await insertEvent(tx, { taskId, runId: null, actor: clientId, type: EVENT_LEASE_RELEASED, payload: leaseReleasedPayload(leaseId) }, now);
      return { ok: true, value: undefined };
    });
  }

  /**
   * Sweeps every unreleased, past-expiry lease. Mirrors
   * `AgentTaskCoordinator.reconcileInterruptedRuns` per the design doc's
   * "Lease gap confirmed" note: a gated action's completion is uncertain
   * (-> `needs_review`, run `failed`, matching
   * `decisionForOutcome("completion_uncertain")`); anything else just goes
   * back to the queue with the run marked `interrupted`.
   *
   * Efficiency (item I of the fix pass): partially set-based. The per-lease
   * task/run SELECTs are hoisted into ONE joined SELECT (locking every
   * candidate lease row), and the leases/tasks/runs UPDATEs are each done as
   * ONE bulk statement (tasks and runs split into two — gated vs ungated —
   * bulk UPDATEs apiece) using `in ${tx(ids)}` rather than one UPDATE per
   * lease. The `task_events` INSERTs are deliberately NOT batched into a
   * single multi-row insert: this file's header comment already documents
   * that a `jsonb` column bound from a plain JS value/array has no inferred
   * Postgres type and silently stringifies wrong unless it goes through
   * `jsonb()`/`tx.array()` — postgres.js's array-of-objects insert helper
   * (`sql([{...}, ...])`) doesn't have a documented per-row jsonb-column
   * story, and there's no local Postgres here to verify one against, so
   * batching the event insert was judged too risky to ship unverified. Each
   * event is still inserted individually via the existing `insertEvent`
   * helper, which already handles `jsonb` correctly.
   */
  async expireLeases(now: Date): Promise<TaskEventRow[]> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`
        select l.id as lease_id, l.task_id, t.action_type, r.id as run_id
        from leases l
        join tasks t on t.id = l.task_id
        left join agent_runs r on r.task_id = l.task_id
        where l.released = false and l.expires_at < ${now}
        for update of l
      `;
      if (rows.length === 0) return [];

      const leaseRows = rows as Record<string, unknown>[];
      const leaseIds = leaseRows.map((r) => r.lease_id as string);
      await tx`update leases set released = true where id in ${tx(leaseIds)}`;

      const gatedTaskIds: string[] = [];
      const ungatedTaskIds: string[] = [];
      const gatedRunIds: string[] = [];
      const ungatedRunIds: string[] = [];
      for (const row of leaseRows) {
        const gated = isGatedActionType(row.action_type as string | null);
        (gated ? gatedTaskIds : ungatedTaskIds).push(row.task_id as string);
        const runId = row.run_id as string | null;
        if (runId) (gated ? gatedRunIds : ungatedRunIds).push(runId);
      }

      if (gatedTaskIds.length > 0) {
        await tx`
          update tasks set stage = 'needs_review', revision = revision + 1, updated_at = ${now}
          where id in ${tx(gatedTaskIds)}
        `;
      }
      if (ungatedTaskIds.length > 0) {
        await tx`
          update tasks set stage = 'queued', revision = revision + 1, updated_at = ${now}
          where id in ${tx(ungatedTaskIds)}
        `;
      }
      if (gatedRunIds.length > 0) {
        await tx`
          update agent_runs
          set state = 'failed',
              last_error = ${"Lease expired mid-turn; completion uncertain."},
              completed_at = ${now},
              revision = revision + 1,
              updated_at = ${now}
          where id in ${tx(gatedRunIds)}
        `;
      }
      if (ungatedRunIds.length > 0) {
        await tx`
          update agent_runs
          set state = 'interrupted',
              last_error = ${"Lease expired; run interrupted."},
              revision = revision + 1,
              updated_at = ${now}
          where id in ${tx(ungatedRunIds)}
        `;
      }

      const events: TaskEventRow[] = [];
      for (const row of leaseRows) {
        const event = await insertEvent(
          tx,
          {
            taskId: row.task_id as string,
            runId: (row.run_id as string | null) ?? null,
            actor: null,
            type: EVENT_LEASE_EXPIRED,
            payload: leaseExpiredPayload(row.lease_id as string),
          },
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
      await tx`update agent_runs set last_activity_at = ${now}, revision = revision + 1, updated_at = ${now} where id = ${runId}`;
      const insertedMessage = mapMessage(inserted[0] as Record<string, unknown>);
      await insertEvent(tx, { taskId, runId, actor: client.id, type: EVENT_MESSAGE_APPENDED, payload: messageAppendedPayload(insertedMessage.id, insertedMessage.kind) }, now);

      return { ok: true, value: insertedMessage };
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

      const kind = messageKindForOutcome(input.outcome);
      const content =
        input.outcome === "needs_input" && input.questions && input.questions.length > 0
          ? input.questions.join("\n")
          : input.outcome === "completed" && input.summary !== undefined
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
      // Swift's `AgentRun.lastError` holds the verbatim runtime output, not a
      // category label — mirror that exactly (memory.ts already did).
      // `errorCategory` moves to the `outcome_applied` event payload instead.
      const lastError = input.outcome === "failed" || input.outcome === "completion_uncertain" ? input.message : null;
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
            revision = revision + 1,
            updated_at = ${now}
            ${providerSessionFragment}
            ${completedAtFragment}
        where id = ${runId}
      `;

      if (activeLease && !activeLease.released) {
        await tx`update leases set released = true where id = ${activeLease.id as string}`;
      }

      await insertEvent(
        tx,
        {
          taskId,
          runId,
          actor: client.id,
          type: EVENT_OUTCOME_APPLIED,
          payload: outcomeAppliedPayload(input.outcome, decision.taskStage, decision.runState, input.errorCategory),
        },
        now,
      );

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
      // Mirrors `queueHumanTurn`'s reset block (AgentTaskCoordinator.swift:
      // 772-778) — a human-driven turn is a fresh attempt: clear any backoff/
      // retry budget and stale error alongside the state transition.
      const reset = freshAttemptRunReset();
      await tx`
        update agent_runs
        set state = 'queued',
            requires_connected_worker = ${reset.requiresConnectedWorker},
            completed_at = ${reset.completedAt},
            last_error = ${reset.lastError},
            next_attempt_at = ${reset.nextAttemptAt},
            auto_retry_count = ${reset.autoRetryCount},
            last_activity_at = ${now},
            revision = revision + 1,
            updated_at = ${now}
        where id = ${runId}
      `;
      await insertEvent(tx, { taskId, runId, actor, type: EVENT_REPLIED, payload: repliedPayload(content) }, now);

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

      if (action === "approve") {
        const stage = taskRow.stage as TaskStage;
        const owner = taskRow.owner as "me" | "agent";
        const ctx: ApproveContext = {
          isExistenceTriage: requiresLedgerApproval(taskRow.source as string) && owner === "me",
          isGated: isGatedActionType(taskRow.action_type as string | null),
          owner,
        };
        const target = approveTarget(stage, ctx);
        if (!target) return { ok: false, error: "illegal_transition" };

        const newGrant = agentApprovalGrantForMove(
          requiresLedgerApproval(taskRow.source as string),
          taskRow.agent_approval_granted as boolean,
          target,
        );
        const completedAtFragment = target === "done" ? tx`, completed_at = ${now}` : tx``;
        await tx`
          update tasks
          set stage = ${target}, agent_approval_granted = ${newGrant}, revision = revision + 1, updated_at = ${now}
              ${completedAtFragment}
          where id = ${taskId}
        `;

        await insertEvent(
          tx,
          { taskId, runId: (runRow?.id as string) ?? null, actor, type: EVENT_APPROVED, payload: approvedPayload(stage, target) },
          now,
        );

        return loadExpandedTask(tx, taskId);
      }

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
      // TODO(slice 6): recurrence cascade on accept — TaskCompletion.complete/
      // RecurrenceEngine has no server port; the Mac client owns next-instance
      // creation until then.

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
        // Mirrors `queueHumanTurn`'s reset block (AgentTaskCoordinator.swift:
        // 772-778): request_changes is a human-driven fresh attempt, so any
        // backoff/retry budget from a prior failed attempt is cleared.
        const resetFragment =
          action === "request_changes"
            ? (() => {
                const reset = freshAttemptRunReset();
                return tx`,
                  requires_connected_worker = ${reset.requiresConnectedWorker},
                  next_attempt_at = ${reset.nextAttemptAt},
                  auto_retry_count = ${reset.autoRetryCount}`;
              })()
            : tx``;
        await tx`
          update agent_runs
          set state = ${result.runState}, last_activity_at = ${now}, revision = revision + 1, updated_at = ${now}
              ${completedAtRunFragment} ${resetFragment}
          where id = ${runRow.id as string}
        `;
      }

      if (action === "take_back") {
        // A take-back can happen from queued/in_progress, where a lease may
        // still be held — reclaiming the task from the agent must free it.
        // Mirrors memory.ts's take_back lease release.
        const activeLease = await findActiveLease(tx, taskId);
        if (activeLease && !activeLease.released) {
          await tx`update leases set released = true where id = ${activeLease.id as string}`;
          await insertEvent(
            tx,
            { taskId, runId: (runRow?.id as string) ?? null, actor, type: EVENT_LEASE_RELEASED, payload: leaseReleasedPayload(activeLease.id as string) },
            now,
          );
        }
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
        { taskId, runId: (runRow?.id as string) ?? null, actor, type: EVENT_REVIEWED, payload: reviewedPayload(action) },
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

/** SQLSTATE 23505 = unique_violation (postgres.js's `PostgresError.code`). */
function isUniqueViolation(err: unknown): boolean {
  return typeof err === "object" && err !== null && "code" in err && (err as { code: unknown }).code === "23505";
}
