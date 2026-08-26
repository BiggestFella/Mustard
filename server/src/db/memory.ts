// In-memory Store implementation (ADR-0013, slice 2 skeleton). Synchronous
// Map-backed state wrapped in `async` methods so it satisfies the Store
// interface identically to the future pg.ts implementation. Every mutating
// method is single-threaded JS, so "one atomic operation" (store.ts's
// top-of-file comment) is free here — there is no interleaving to guard
// against, unlike pg.ts which will need a real transaction.
//
// Legality checks always call the pure functions in src/domain/* rather
// than re-deriving the rules locally, per store.ts's instruction that
// implementations "call those pure functions INSIDE the transaction so a
// check-then-write can never race."
//
// Simplification documented up front (see expireLeases): this slice has no
// action-gating information (that arrives with the recommendations slice),
// so every expired lease routes its task back to `queued` with the run
// marked `interrupted`, rather than distinguishing a gated completion-
// uncertain path.

import type {
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
import type { AgentMessageRow, AgentRunRow } from "./store.ts";
import type { Provider } from "../domain/stages.ts";
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
  compareQueueOrder,
  computeIsBlocked,
  isClaimable,
  providerMatches,
  requiresLedgerApproval,
  type QueueTask,
} from "../domain/queue.ts";
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
import type { ClientScope } from "../auth.ts";

// ---------------------------------------------------------------------------
// Seeding helpers (test-facing convenience, not part of the Store contract)
// ---------------------------------------------------------------------------

export interface SeedClientInput {
  id?: string;
  tokenHash: string;
  name: string;
  kind: ClientScope;
  provider?: Provider | null;
  enabled?: boolean;
}

export interface MemoryStoreSeed {
  clients?: SeedClientInput[];
}

// ---------------------------------------------------------------------------
// Small pure helpers
// ---------------------------------------------------------------------------

function idempotencyKey(clientId: string, key: string, route: string): string {
  return `${clientId}\u0000${key}\u0000${route}`;
}

function mergeLinks(existing: TaskLinkJSON[], incoming: TaskLinkJSON[] | undefined): TaskLinkJSON[] {
  if (!incoming || incoming.length === 0) return existing;
  const byUrl = new Map<string, TaskLinkJSON>();
  for (const link of existing) byUrl.set(link.url, link);
  for (const link of incoming) byUrl.set(link.url, link); // incoming wins on a url collision
  return [...byUrl.values()];
}

// ---------------------------------------------------------------------------
// MemoryStore
// ---------------------------------------------------------------------------

export class MemoryStore implements Store {
  private tasks = new Map<string, TaskRow>();
  private contexts = new Map<string, TaskContextRow>(); // taskId -> context
  private runs = new Map<string, AgentRunRow>(); // runId -> run
  private runByTask = new Map<string, string>(); // taskId -> runId
  private messages = new Map<string, AgentMessageRow[]>(); // runId -> messages
  private messageSeq = new Map<string, number>(); // runId -> next seq
  private artifacts = new Map<string, ArtifactRow>();
  private leases = new Map<string, LeaseRow>();
  private activeLeaseByTask = new Map<string, string>(); // taskId -> leaseId (unreleased)
  private events: TaskEventRow[] = [];
  private eventSeq = 0;
  private clients = new Map<string, ClientRow>();
  private clientsByTokenHash = new Map<string, string>(); // tokenHash -> clientId
  private lastSeenAt = new Map<string, string>(); // clientId -> ISO (ClientRow has no field for it)
  private idempotency = new Map<
    string,
    { state: "pending" } | { state: "complete"; status: number; response: unknown }
  >();

  constructor(seed?: MemoryStoreSeed) {
    for (const c of seed?.clients ?? []) {
      this.registerClient(c);
    }
  }

  /** Test/bootstrap convenience: register a client + its token hash. */
  registerClient(input: SeedClientInput): ClientRow {
    const id = input.id ?? crypto.randomUUID();
    const row: ClientRow = {
      id,
      name: input.name,
      kind: input.kind,
      provider: input.provider ?? null,
      enabled: input.enabled ?? true,
    };
    this.clients.set(id, row);
    this.clientsByTokenHash.set(input.tokenHash, id);
    return row;
  }

  // -------------------------------------------------------------------
  // internal helpers
  // -------------------------------------------------------------------

  private appendEvent(
    taskId: string,
    runId: string | null,
    actor: string | null,
    type: string,
    payload: object,
    now: Date = new Date(),
  ): TaskEventRow {
    this.eventSeq += 1;
    const row: TaskEventRow = {
      seq: this.eventSeq,
      taskId,
      runId,
      actor,
      type,
      payload,
      createdAt: now.toISOString(),
    };
    this.events.push(row);
    return row;
  }

  private getRunForTask(taskId: string): AgentRunRow | null {
    const runId = this.runByTask.get(taskId);
    if (!runId) return null;
    return this.runs.get(runId) ?? null;
  }

  private computeIsBlocked(task: TaskRow): boolean {
    const blocker = task.blockedByTaskId ? this.tasks.get(task.blockedByTaskId) : undefined;
    return computeIsBlocked({
      blockedByTaskId: task.blockedByTaskId,
      blockerStage: blocker ? blocker.stage : null,
      blockedReason: task.blockedReason,
    });
  }

  private toQueueTask(task: TaskRow, run: AgentRunRow | null): QueueTask {
    return {
      uid: task.id,
      owner: task.owner,
      stage: task.stage,
      isBlocked: this.computeIsBlocked(task),
      priority: task.priority,
      createdAt: task.createdAt,
      requiresAgentApproval: requiresLedgerApproval(task.source),
      agentApprovalGranted: task.agentApprovalGranted,
      run: run ? { requiresConnectedWorker: run.requiresConnectedWorker, nextAttemptAt: run.nextAttemptAt } : null,
    };
  }

  private expand(taskId: string): ExpandedTask {
    const task = this.tasks.get(taskId);
    if (!task) throw new Error(`MemoryStore.expand: unknown task ${taskId}`);
    const context = this.contexts.get(taskId) ?? null;
    const runId = this.runByTask.get(taskId);
    const run = runId ? this.runs.get(runId) ?? null : null;
    const messages = runId ? [...(this.messages.get(runId) ?? [])].sort((a, b) => a.seq - b.seq) : [];
    const artifacts = [...this.artifacts.values()].filter((a) => a.taskId === taskId);
    const activeLeaseId = this.activeLeaseByTask.get(taskId);
    const lease = activeLeaseId ? this.leases.get(activeLeaseId) ?? null : null;
    return { task, context, run, messages, artifacts, lease };
  }

  private appendRunMessage(run: AgentRunRow, message: Omit<AgentMessageRow, "id" | "runId" | "seq">, now: Date): AgentMessageRow {
    const seq = (this.messageSeq.get(run.id) ?? 0) + 1;
    this.messageSeq.set(run.id, seq);
    const row: AgentMessageRow = { id: crypto.randomUUID(), runId: run.id, seq, ...message };
    const list = this.messages.get(run.id) ?? [];
    list.push(row);
    this.messages.set(run.id, list);
    return row;
  }

  /**
   * Sweeps every unreleased, past-expiry lease. Shared by the lazy sweep
   * `claimTask` performs and the public `expireLeases`.
   *
   * Mirrors pg.ts's `expireLeases` gated-vs-not routing (which mirrors
   * `AgentTaskCoordinator.reconcileInterruptedRuns` per the design doc's
   * "Lease gap confirmed" note): a gated action's completion is uncertain
   * (-> `needs_review`, run `failed`, matching
   * `decisionForOutcome("completion_uncertain")`); anything else just goes
   * back to the queue with the run marked `interrupted`.
   */
  private sweepExpiredLeases(now: Date): TaskEventRow[] {
    const expiredEvents: TaskEventRow[] = [];
    for (const lease of this.leases.values()) {
      if (lease.released) continue;
      if (new Date(lease.expiresAt).getTime() > now.getTime()) continue;

      lease.released = true;
      if (this.activeLeaseByTask.get(lease.taskId) === lease.id) {
        this.activeLeaseByTask.delete(lease.taskId);
      }

      const task = this.tasks.get(lease.taskId);
      let runId: string | null = null;
      if (task) {
        const gated = isGatedActionType(task.actionType);
        task.stage = gated ? "needs_review" : "queued";
        task.revision += 1;
        task.updatedAt = now.toISOString();

        const run = this.getRunForTask(lease.taskId);
        if (run) {
          run.state = gated ? "failed" : "interrupted";
          run.lastError = gated
            ? "Lease expired mid-turn; completion uncertain."
            : "Lease expired; run interrupted.";
          if (gated) run.completedAt = now.toISOString();
          run.lastActivityAt = now.toISOString();
          run.revision += 1;
          runId = run.id;
        }
      }

      const event = this.appendEvent(lease.taskId, runId, null, EVENT_LEASE_EXPIRED, leaseExpiredPayload(lease.id), now);
      expiredEvents.push(event);
    }
    return expiredEvents;
  }

  /**
   * Verifies `client` currently holds the task's live, unexpired lease.
   * Only enforced for `worker` clients — `user_app` appends/reports freely
   * per store.ts's contract. Shared by `appendMessage` and `applyOutcome`,
   * which previously copy-pasted this check WITHOUT the expiry test (pg.ts's
   * `leaseFailure` already had it) — collapsed into one helper here.
   */
  private leaseFailure(taskId: string, client: ClientRow, now: Date): StoreError | null {
    if (client.kind !== "worker") return null;
    const activeLeaseId = this.activeLeaseByTask.get(taskId);
    const lease = activeLeaseId ? this.leases.get(activeLeaseId) : undefined;
    if (!lease || lease.clientId !== client.id) return "lease_required";
    if (new Date(lease.expiresAt).getTime() <= now.getTime()) return "lease_expired";
    return null;
  }

  // -------------------------------------------------------------------
  // auth
  // -------------------------------------------------------------------

  async getClientByTokenHash(tokenHash: string): Promise<ClientRow | null> {
    const clientId = this.clientsByTokenHash.get(tokenHash);
    if (!clientId) return null;
    return this.clients.get(clientId) ?? null;
  }

  async touchClientSeen(clientId: string, now: Date): Promise<void> {
    this.lastSeenAt.set(clientId, now.toISOString());
  }

  // -------------------------------------------------------------------
  // idempotency
  // -------------------------------------------------------------------

  async reserveIdempotent(clientId: string, key: string, route: string, _now: Date): Promise<IdempotencyReservation> {
    const k = idempotencyKey(clientId, key, route);
    const existing = this.idempotency.get(k);
    if (!existing) {
      this.idempotency.set(k, { state: "pending" });
      return { status: "reserved" };
    }
    if (existing.state === "pending") return { status: "in_flight" };
    return { status: "complete", response: { status: existing.status, response: existing.response } };
  }

  async completeIdempotent(clientId: string, key: string, route: string, status: number, response: unknown): Promise<void> {
    this.idempotency.set(idempotencyKey(clientId, key, route), { state: "complete", status, response });
  }

  // -------------------------------------------------------------------
  // tasks
  // -------------------------------------------------------------------

  async createTask(input: CreateTaskInput, actor: string, now: Date): Promise<Result<TaskRow>> {
    const id = input.id ?? crypto.randomUUID();
    const nowIso = now.toISOString();

    const task: TaskRow = {
      id,
      title: input.title,
      notes: input.notes ?? "",
      stage: input.stage ?? "inbox",
      owner: input.owner ?? "me",
      selectedProvider: input.selectedProvider ?? null,
      priority: input.priority ?? "normal",
      scheduledAt: input.scheduledAt ?? null,
      dueAt: null,
      isTimed: false,
      focusOnDay: null,
      estimateMinutes: input.estimateMinutes ?? 30,
      completedAt: null,
      carriedForwardAt: null,
      recurrence: null,
      recurredFrom: null,
      autoCompleted: false,
      tags: input.tags ?? [],
      links: input.links ?? [],
      source: input.source ?? "manual",
      sourceURL: null,
      sourceContext: "",
      originKey: null,
      agentApprovalGranted: false,
      captureState: null,
      captureTranscript: null,
      blockedByTaskId: null,
      blockedReason: "",
      parentTaskId: null,
      listId: input.listId ?? null,
      actionType: null,
      confidence: null,
      revision: 1,
      createdAt: nowIso,
      updatedAt: nowIso,
      deletedAt: null,
    };
    this.tasks.set(id, task);

    if (input.context) {
      const context: TaskContextRow = {
        taskId: id,
        noteRefs: input.context.noteRefs,
        urls: input.context.urls,
        artifactIds: input.context.artifactIds,
        guidance: input.context.guidance,
      };
      this.contexts.set(id, context);
    }

    // `project` has no home on TaskRow (it belongs to agent_runs). When the
    // caller supplies one at creation time (typically a direct
    // owner=agent/stage=for_agent|queued delegation), pre-create the run so
    // `project` is already resolvable by the time a worker claims the task —
    // claimTask has no `project` parameter, so this is the only place it can
    // be captured before the first claim.
    if (input.project !== undefined) {
      const runId = crypto.randomUUID();
      const provider: Provider =
        task.selectedProvider && task.selectedProvider !== "any" ? task.selectedProvider : "claude";
      const run: AgentRunRow = {
        id: runId,
        taskId: id,
        provider,
        state: "queued",
        providerSessionId: null,
        project: input.project,
        requiresConnectedWorker: false,
        attemptCount: 0,
        resumeCount: 0,
        autoRetryCount: 0,
        nextAttemptAt: null,
        lastOutcome: null,
        lastError: null,
        startedAt: null,
        lastActivityAt: nowIso,
        completedAt: null,
        revision: 1,
      };
      this.runs.set(runId, run);
      this.runByTask.set(id, runId);
    }

    this.appendEvent(id, this.runByTask.get(id) ?? null, actor, EVENT_TASK_CREATED, taskCreatedPayload(task.title, task.stage), now);
    return { ok: true, value: task };
  }

  async listTasks(filter: TaskFilter, now: Date): Promise<TaskRow[]> {
    let results = [...this.tasks.values()].filter((t) => !t.deletedAt);

    if (filter.stage) results = results.filter((t) => t.stage === filter.stage);
    if (filter.owner) results = results.filter((t) => t.owner === filter.owner);
    if (filter.provider) results = results.filter((t) => t.selectedProvider === filter.provider);
    if (filter.updatedAfter) {
      const afterMs = new Date(filter.updatedAfter).getTime();
      results = results.filter((t) => new Date(t.updatedAt).getTime() > afterMs);
    }

    if (filter.claimableBy) {
      const claimableBy = filter.claimableBy;
      results = results.filter((t) => {
        const run = this.getRunForTask(t.id);
        if (!isClaimable(this.toQueueTask(t, run), now)) return false;
        return providerMatches(t.selectedProvider, claimableBy);
      });
      results.sort((a, b) =>
        compareQueueOrder(this.toQueueTask(a, this.getRunForTask(a.id)), this.toQueueTask(b, this.getRunForTask(b.id))),
      );
    } else {
      results.sort((a, b) => {
        const diff = new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime();
        if (diff !== 0) return diff;
        return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
      });
    }

    if (filter.limit !== undefined) results = results.slice(0, filter.limit);
    return results;
  }

  async getTask(taskId: string): Promise<Result<ExpandedTask>> {
    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };
    return { ok: true, value: this.expand(taskId) };
  }

  async updateTask(taskId: string, patch: TaskPatch, ifRevision: number, actor: string, now: Date): Promise<Result<TaskRow>> {
    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };
    if (task.revision !== ifRevision) return { ok: false, error: "revision_conflict" };

    if (patch.title !== undefined) task.title = patch.title;
    if (patch.notes !== undefined) task.notes = patch.notes;
    if (patch.stage !== undefined) {
      task.stage = patch.stage;
      // A board-lane move on a ledger-imported meeting task grants/revokes
      // the Do/Don't approval bit alongside the stage change (mirrors
      // PersonalBoard.move, PersonalBoard.swift:72-75) — the PATCH route has
      // no separate "approve" verb of its own, so this is the only place a
      // plain stage-drag can flip the grant.
      task.agentApprovalGranted = agentApprovalGrantForMove(
        requiresLedgerApproval(task.source),
        task.agentApprovalGranted,
        patch.stage,
      );
    }
    if (patch.owner !== undefined) task.owner = patch.owner;
    if (patch.priority !== undefined) task.priority = patch.priority;
    if (patch.scheduledAt !== undefined) task.scheduledAt = patch.scheduledAt;
    if (patch.dueAt !== undefined) task.dueAt = patch.dueAt;
    if (patch.estimateMinutes !== undefined) task.estimateMinutes = patch.estimateMinutes;
    if (patch.tags !== undefined) task.tags = patch.tags;
    if (patch.links !== undefined) task.links = patch.links;
    if (patch.listId !== undefined) task.listId = patch.listId;
    if (patch.blockedReason !== undefined) task.blockedReason = patch.blockedReason;

    task.revision += 1;
    task.updatedAt = now.toISOString();

    this.appendEvent(taskId, this.runByTask.get(taskId) ?? null, actor, EVENT_TASK_UPDATED, taskUpdatedPayload(patch), now);
    return { ok: true, value: task };
  }

  async setProvider(taskId: string, provider: Provider | null, actor: string, now: Date): Promise<Result<TaskRow>> {
    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };

    task.selectedProvider = provider;
    task.revision += 1;
    task.updatedAt = now.toISOString();

    this.appendEvent(taskId, this.runByTask.get(taskId) ?? null, actor, EVENT_PROVIDER_ASSIGNED, providerAssignedPayload(provider), now);
    return { ok: true, value: task };
  }

  // -------------------------------------------------------------------
  // worker loop
  // -------------------------------------------------------------------

  async claimTask(
    taskId: string,
    client: ClientRow,
    ttlSeconds: number,
    now: Date,
  ): Promise<Result<{ lease: LeaseRow; task: ExpandedTask }>> {
    this.sweepExpiredLeases(now);

    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };

    if (this.activeLeaseByTask.has(taskId)) {
      return { ok: false, error: "already_leased" };
    }

    if (client.provider === null) {
      return { ok: false, error: "not_claimable", detail: "client has no provider" };
    }
    const clientProvider: Provider = client.provider;

    if (!providerMatches(task.selectedProvider, clientProvider)) {
      return { ok: false, error: "not_claimable", detail: "provider mismatch" };
    }

    const existingRun = this.getRunForTask(taskId);
    if (!isClaimable(this.toQueueTask(task, existingRun), now)) {
      return { ok: false, error: "not_claimable" };
    }

    const nowIso = now.toISOString();
    let run: AgentRunRow;
    if (existingRun) {
      existingRun.provider = clientProvider;
      existingRun.state = "running";
      existingRun.attemptCount += 1;
      if (existingRun.providerSessionId) existingRun.resumeCount += 1;
      existingRun.startedAt = existingRun.startedAt ?? nowIso;
      existingRun.lastActivityAt = nowIso;
      existingRun.revision += 1;
      run = existingRun;
    } else {
      const runId = crypto.randomUUID();
      run = {
        id: runId,
        taskId,
        provider: clientProvider,
        state: "running",
        providerSessionId: null,
        project: "",
        requiresConnectedWorker: false,
        attemptCount: 1,
        resumeCount: 0,
        autoRetryCount: 0,
        nextAttemptAt: null,
        lastOutcome: null,
        lastError: null,
        startedAt: nowIso,
        lastActivityAt: nowIso,
        completedAt: null,
        revision: 1,
      };
      this.runs.set(runId, run);
      this.runByTask.set(taskId, runId);
    }

    const leaseId = crypto.randomUUID();
    const lease: LeaseRow = {
      id: leaseId,
      taskId,
      clientId: client.id,
      createdAt: nowIso,
      renewedAt: null,
      expiresAt: new Date(now.getTime() + ttlSeconds * 1000).toISOString(),
      released: false,
    };
    this.leases.set(leaseId, lease);
    this.activeLeaseByTask.set(taskId, leaseId);

    task.stage = "in_progress";
    task.revision += 1;
    task.updatedAt = nowIso;

    this.appendEvent(taskId, run.id, client.id, EVENT_TASK_CLAIMED, taskClaimedPayload(leaseId, run.id), now);

    return { ok: true, value: { lease, task: this.expand(taskId) } };
  }

  async renewLease(leaseId: string, clientId: string, ttlSeconds: number, now: Date): Promise<Result<LeaseRow>> {
    const lease = this.leases.get(leaseId);
    if (!lease) return { ok: false, error: "not_found" };
    if (lease.clientId !== clientId) return { ok: false, error: "lease_required", detail: "lease not held by this client" };
    if (lease.released) return { ok: false, error: "lease_expired" };
    if (new Date(lease.expiresAt).getTime() <= now.getTime()) {
      this.sweepExpiredLeases(now);
      return { ok: false, error: "lease_expired" };
    }

    lease.renewedAt = now.toISOString();
    lease.expiresAt = new Date(now.getTime() + ttlSeconds * 1000).toISOString();

    this.appendEvent(lease.taskId, this.runByTask.get(lease.taskId) ?? null, clientId, EVENT_LEASE_RENEWED, leaseRenewedPayload(leaseId), now);
    return { ok: true, value: lease };
  }

  async releaseLease(leaseId: string, clientId: string, now: Date): Promise<Result<void>> {
    const lease = this.leases.get(leaseId);
    if (!lease) return { ok: false, error: "not_found" };
    if (lease.clientId !== clientId) return { ok: false, error: "lease_required", detail: "lease not held by this client" };

    if (!lease.released) {
      lease.released = true;
      if (this.activeLeaseByTask.get(lease.taskId) === lease.id) {
        this.activeLeaseByTask.delete(lease.taskId);
      }
      this.appendEvent(lease.taskId, this.runByTask.get(lease.taskId) ?? null, clientId, EVENT_LEASE_RELEASED, leaseReleasedPayload(leaseId), now);
    }

    return { ok: true, value: undefined };
  }

  async expireLeases(now: Date): Promise<TaskEventRow[]> {
    return this.sweepExpiredLeases(now);
  }

  // -------------------------------------------------------------------
  // conversation
  // -------------------------------------------------------------------

  async appendMessage(taskId: string, client: ClientRow, input: MessageInput, now: Date): Promise<Result<AgentMessageRow>> {
    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };

    const failure = this.leaseFailure(taskId, client, now);
    if (failure) return { ok: false, error: failure };

    const run = this.getRunForTask(taskId);
    if (!run) return { ok: false, error: "not_found", detail: "task has no active run" };

    const nowIso = now.toISOString();
    const message = this.appendRunMessage(
      run,
      {
        role: input.role,
        kind: input.kind,
        content: input.content,
        links: input.links ?? [],
        providerTurnId: input.providerTurnId ?? null,
        createdAt: nowIso,
      },
      now,
    );

    run.lastActivityAt = nowIso;
    run.revision += 1;

    this.appendEvent(taskId, run.id, client.id, EVENT_MESSAGE_APPENDED, messageAppendedPayload(message.id, message.kind), now);
    return { ok: true, value: message };
  }

  async applyOutcome(taskId: string, client: ClientRow, input: OutcomeInput, now: Date): Promise<Result<ExpandedTask>> {
    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };

    const failure = this.leaseFailure(taskId, client, now);
    if (failure) return { ok: false, error: failure };

    const run = this.getRunForTask(taskId);
    if (!run) return { ok: false, error: "not_found", detail: "task has no active run" };

    const decision = decisionForOutcome(input.outcome);
    const nowIso = now.toISOString();
    const kind = messageKindForOutcome(input.outcome);

    let content: string;
    if (input.outcome === "needs_input" && input.questions && input.questions.length > 0) {
      content = input.questions.join("\n");
    } else if (input.outcome === "completed" && input.summary !== undefined) {
      content = input.summary;
    } else {
      content = input.message;
    }

    this.appendRunMessage(
      run,
      {
        role: "agent",
        kind,
        content,
        links: input.links ?? [],
        providerTurnId: input.providerTurnId ?? null,
        createdAt: nowIso,
      },
      now,
    );

    if (input.outcome === "completed") {
      task.links = mergeLinks(task.links, input.links);
    }

    task.stage = decision.taskStage;
    if (decision.taskOwner !== undefined) task.owner = decision.taskOwner;
    task.revision += 1;
    task.updatedAt = nowIso;

    run.state = decision.runState;
    run.lastOutcome = input.outcome;
    run.lastError = input.outcome === "failed" || input.outcome === "completion_uncertain" ? input.message : null;
    if (input.providerSessionId !== undefined) run.providerSessionId = input.providerSessionId;
    run.requiresConnectedWorker = decision.requiresConnectedWorker;
    if (decision.runState === "completed") run.completedAt = nowIso;
    run.lastActivityAt = nowIso;
    run.revision += 1;

    if (decision.releasesSlot) {
      const activeLeaseId = this.activeLeaseByTask.get(taskId);
      if (activeLeaseId) {
        const lease = this.leases.get(activeLeaseId);
        if (lease) lease.released = true;
        this.activeLeaseByTask.delete(taskId);
      }
    }

    this.appendEvent(
      taskId,
      run.id,
      client.id,
      EVENT_OUTCOME_APPLIED,
      outcomeAppliedPayload(input.outcome, task.stage, run.state, input.errorCategory),
      now,
    );

    return { ok: true, value: this.expand(taskId) };
  }

  async reply(taskId: string, content: string, actor: string, now: Date): Promise<Result<ExpandedTask>> {
    if (!content || content.trim() === "") {
      return { ok: false, error: "illegal_transition", detail: "reply content is empty" };
    }

    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };

    const run = this.getRunForTask(taskId);
    if (!run) return { ok: false, error: "not_found", detail: "task has no active run" };

    if (!canReply(task.owner, task.stage, run.state)) {
      return { ok: false, error: "illegal_transition" };
    }

    const nowIso = now.toISOString();
    this.appendRunMessage(
      run,
      { role: "human", kind: "answer", content, links: [], providerTurnId: null, createdAt: nowIso },
      now,
    );

    task.stage = "queued";
    task.revision += 1;
    task.updatedAt = nowIso;

    const reset = freshAttemptRunReset();
    run.state = "queued";
    run.requiresConnectedWorker = reset.requiresConnectedWorker;
    run.completedAt = reset.completedAt;
    run.lastError = reset.lastError;
    run.nextAttemptAt = reset.nextAttemptAt;
    run.autoRetryCount = reset.autoRetryCount;
    run.lastActivityAt = nowIso;
    run.revision += 1;

    this.appendEvent(taskId, run.id, actor, EVENT_REPLIED, repliedPayload(content), now);
    return { ok: true, value: this.expand(taskId) };
  }

  async review(
    taskId: string,
    action: ReviewActionKind,
    feedback: string | undefined,
    actor: string,
    now: Date,
  ): Promise<Result<ExpandedTask>> {
    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };

    const run = this.getRunForTask(taskId);
    const nowIso = now.toISOString();

    if (action === "approve") {
      const ctx: ApproveContext = {
        isExistenceTriage: requiresLedgerApproval(task.source) && task.owner === "me",
        isGated: isGatedActionType(task.actionType),
        owner: task.owner,
      };
      const target = approveTarget(task.stage, ctx);
      if (!target) return { ok: false, error: "illegal_transition" };

      const fromStage = task.stage;
      task.stage = target;
      // Mirrors PersonalBoard's grant/revoke on a lane move — approving a
      // ledger task into `queued` grants the Do/Don't bit the same way a
      // manual board drag would.
      task.agentApprovalGranted = agentApprovalGrantForMove(
        requiresLedgerApproval(task.source),
        task.agentApprovalGranted,
        target,
      );
      if (target === "done") task.completedAt = nowIso;
      task.revision += 1;
      task.updatedAt = nowIso;

      this.appendEvent(taskId, run ? run.id : null, actor, EVENT_APPROVED, approvedPayload(fromStage, target), now);
      return { ok: true, value: this.expand(taskId) };
    }

    let legal: boolean;
    if (action === "accept") {
      // reviewAction doesn't re-validate legality itself (see transitions.ts);
      // AgentTaskCoordinator.accept's own guard is simply `stage == .needsReview`.
      legal = task.stage === "needs_review";
    } else if (action === "request_changes") {
      legal = canRequestChanges(task.owner, task.stage);
    } else {
      legal = canTakeBack(task.owner, task.stage);
    }
    if (!legal) return { ok: false, error: "illegal_transition" };

    const result = reviewAction(action, { requiresAgentApproval: requiresLedgerApproval(task.source) });

    task.stage = result.stage;
    if (result.owner !== undefined) task.owner = result.owner;
    if (result.agentApprovalGranted !== undefined) task.agentApprovalGranted = result.agentApprovalGranted;
    if (action === "accept") {
      task.completedAt = nowIso;
      // TODO(slice 6): recurrence cascade on accept — TaskCompletion.complete/
      // RecurrenceEngine has no server port; the Mac client owns next-instance
      // creation until then.
    }
    task.revision += 1;
    task.updatedAt = nowIso;

    if (run && result.runState !== undefined) {
      run.state = result.runState;
      if (action === "request_changes") {
        const reset = freshAttemptRunReset();
        run.requiresConnectedWorker = reset.requiresConnectedWorker;
        run.completedAt = reset.completedAt;
        run.lastError = reset.lastError;
        run.nextAttemptAt = reset.nextAttemptAt;
        run.autoRetryCount = reset.autoRetryCount;
      }
      run.lastActivityAt = nowIso;
      run.revision += 1;
    }

    if (action === "take_back") {
      // A take-back can happen from queued/in_progress, where a lease may
      // still be held — reclaiming the task from the agent must free it.
      const activeLeaseId = this.activeLeaseByTask.get(taskId);
      if (activeLeaseId) {
        const lease = this.leases.get(activeLeaseId);
        if (lease) lease.released = true;
        this.activeLeaseByTask.delete(taskId);
        this.appendEvent(taskId, run ? run.id : null, actor, EVENT_LEASE_RELEASED, leaseReleasedPayload(activeLeaseId), now);
      }
    }

    if (action === "request_changes" && run) {
      this.appendRunMessage(
        run,
        {
          role: "human",
          kind: "review_feedback",
          content: feedback ?? "",
          links: [],
          providerTurnId: null,
          createdAt: nowIso,
        },
        now,
      );
    }

    this.appendEvent(taskId, run ? run.id : null, actor, EVENT_REVIEWED, reviewedPayload(action), now);
    return { ok: true, value: this.expand(taskId) };
  }

  // -------------------------------------------------------------------
  // artifacts
  // -------------------------------------------------------------------

  async createArtifact(input: ArtifactInput, actor: string, now: Date): Promise<Result<ArtifactRow>> {
    const task = this.tasks.get(input.taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };

    const id = crypto.randomUUID();
    const row: ArtifactRow = {
      id,
      taskId: input.taskId,
      runId: input.runId ?? null,
      kind: input.kind,
      title: input.title,
      storageKey: input.storageKey,
      mime: input.mime ?? null,
      sizeBytes: input.sizeBytes ?? null,
      createdBy: actor,
      createdAt: now.toISOString(),
    };
    this.artifacts.set(id, row);

    this.appendEvent(input.taskId, input.runId ?? null, actor, "artifact_created", { artifactId: id, kind: input.kind }, now);
    return { ok: true, value: row };
  }

  async getArtifact(artifactId: string): Promise<ArtifactRow | null> {
    return this.artifacts.get(artifactId) ?? null;
  }

  // -------------------------------------------------------------------
  // sync cursor
  // -------------------------------------------------------------------

  async listEvents(afterSeq: number, limit: number): Promise<TaskEventRow[]> {
    return this.events.filter((e) => e.seq > afterSeq).slice(0, limit);
  }
}
