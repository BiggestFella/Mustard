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
  LeaseRow,
  MessageInput,
  OutcomeInput,
  Result,
  Store,
  TaskContextRow,
  TaskEventRow,
  TaskFilter,
  TaskLinkJSON,
  TaskPatch,
  TaskRow,
} from "./store.ts";
import type { AgentMessageRow, AgentRunRow } from "./store.ts";
import type { MessageKind, Provider, TurnOutcome } from "../domain/stages.ts";
import {
  canReply,
  canRequestChanges,
  canTakeBack,
  decisionForOutcome,
  reviewAction,
  type ReviewActionKind,
} from "../domain/transitions.ts";
import { compareQueueOrder, isClaimable, type QueueTask } from "../domain/queue.ts";
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

/**
 * Message kind for an applied turn outcome. `needs_input` -> `completed` ->
 * `failed` are spelled out explicitly by the task brief; the other three
 * outcomes aren't, so this resolves them by the closest fit in
 * `MessageKind` and documents the reasoning inline (see also this file's
 * evidence report):
 *  - `completion_uncertain` is routed through `decisionForOutcome` exactly
 *    like `failed` (runState: "failed") — mirror that for the message kind.
 *  - `cancelled` is likewise a terminal negative outcome with no dedicated
 *    kind, so it gets the same treatment.
 *  - `requires_connected_worker` isn't a failure — the task simply requeues
 *    pending a capability this worker doesn't have — so it's tagged
 *    `progress` (an in-flight update) rather than `error`.
 */
function messageKindForOutcome(outcome: TurnOutcome): MessageKind {
  switch (outcome) {
    case "needs_input":
      return "question";
    case "completed":
      return "result";
    case "failed":
    case "cancelled":
    case "completion_uncertain":
      return "error";
    case "requires_connected_worker":
      return "progress";
  }
}

function requiresAgentApproval(source: string): boolean {
  // Mirrors Sources/MustardKit/Logic/MeetingTaskSource.swift:
  // `requiresAgentApproval(_:) { source == "meeting" }`. "meeting-recording"
  // is a *different* pipeline that is already locally approved and must NOT
  // match here (see that file's doc comment).
  return source === "meeting";
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
  private idempotency = new Map<string, { status: number; response: unknown }>();

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
    payload: Record<string, unknown>,
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
    // Mirrors MustardTask.isBlocked (Models/MustardTask.swift): blocked by
    // an unfinished dependency, or by a non-empty free-text reason.
    if (task.blockedByTaskId) {
      const blocker = this.tasks.get(task.blockedByTaskId);
      if (blocker && blocker.stage !== "done") return true;
    }
    return task.blockedReason.trim().length > 0;
  }

  private toQueueTask(task: TaskRow, run: AgentRunRow | null): QueueTask {
    return {
      uid: task.id,
      owner: task.owner,
      stage: task.stage,
      isBlocked: this.computeIsBlocked(task),
      priority: task.priority,
      createdAt: task.createdAt,
      requiresAgentApproval: requiresAgentApproval(task.source),
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
   * Simplification (documented per the task brief): this slice has no
   * action-gating information, so EVERY expired-lease task routes back to
   * `queued` with its run marked `interrupted` — there is no
   * gated-completion-uncertain branch here. That distinction arrives with
   * the recommendations slice, which is what will carry the "was this a
   * gated action?" signal this sweep would need.
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
        task.stage = "queued";
        task.revision += 1;
        task.updatedAt = now.toISOString();

        const run = this.getRunForTask(lease.taskId);
        if (run) {
          run.state = "interrupted";
          run.lastActivityAt = now.toISOString();
          run.revision += 1;
          runId = run.id;
        }
      }

      const event = this.appendEvent(lease.taskId, runId, null, "lease_expired", { leaseId: lease.id }, now);
      expiredEvents.push(event);
    }
    return expiredEvents;
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

  async getIdempotent(clientId: string, key: string, route: string): Promise<{ status: number; response: unknown } | null> {
    return this.idempotency.get(idempotencyKey(clientId, key, route)) ?? null;
  }

  async putIdempotent(clientId: string, key: string, route: string, status: number, response: unknown): Promise<void> {
    this.idempotency.set(idempotencyKey(clientId, key, route), { status, response });
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

    this.appendEvent(id, this.runByTask.get(id) ?? null, actor, "task_created", { title: task.title, stage: task.stage }, now);
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
        if (t.selectedProvider === null || t.selectedProvider === "any") return true;
        return t.selectedProvider === claimableBy;
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
    if (patch.stage !== undefined) task.stage = patch.stage;
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

    this.appendEvent(taskId, this.runByTask.get(taskId) ?? null, actor, "task_updated", { patch }, now);
    return { ok: true, value: task };
  }

  async setProvider(taskId: string, provider: Provider | null, actor: string, now: Date): Promise<Result<TaskRow>> {
    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };

    task.selectedProvider = provider;
    task.revision += 1;
    task.updatedAt = now.toISOString();

    this.appendEvent(taskId, this.runByTask.get(taskId) ?? null, actor, "provider_assigned", { provider }, now);
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

    if (task.selectedProvider !== null && task.selectedProvider !== "any" && task.selectedProvider !== clientProvider) {
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

    this.appendEvent(taskId, run.id, client.id, "task_claimed", { leaseId, runId: run.id }, now);

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

    this.appendEvent(lease.taskId, this.runByTask.get(lease.taskId) ?? null, clientId, "lease_renewed", { leaseId }, now);
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
      this.appendEvent(lease.taskId, this.runByTask.get(lease.taskId) ?? null, clientId, "lease_released", { leaseId }, now);
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

    if (client.kind === "worker") {
      const activeLeaseId = this.activeLeaseByTask.get(taskId);
      const lease = activeLeaseId ? this.leases.get(activeLeaseId) : undefined;
      if (!lease || lease.clientId !== client.id) {
        return { ok: false, error: "lease_required" };
      }
    }

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

    this.appendEvent(taskId, run.id, client.id, "message_appended", { messageId: message.id, kind: message.kind }, now);
    return { ok: true, value: message };
  }

  async applyOutcome(taskId: string, client: ClientRow, input: OutcomeInput, now: Date): Promise<Result<ExpandedTask>> {
    const task = this.tasks.get(taskId);
    if (!task || task.deletedAt) return { ok: false, error: "not_found" };

    if (client.kind === "worker") {
      const activeLeaseId = this.activeLeaseByTask.get(taskId);
      const lease = activeLeaseId ? this.leases.get(activeLeaseId) : undefined;
      if (!lease || lease.clientId !== client.id) {
        return { ok: false, error: "lease_required" };
      }
    }

    const run = this.getRunForTask(taskId);
    if (!run) return { ok: false, error: "not_found", detail: "task has no active run" };

    const decision = decisionForOutcome(input.outcome);
    const nowIso = now.toISOString();
    const kind = messageKindForOutcome(input.outcome);

    let content: string;
    if (input.outcome === "needs_input" && input.questions && input.questions.length > 0) {
      content = input.questions.join("\n");
    } else if (input.outcome === "completed" && input.summary) {
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
      "outcome_applied",
      { outcome: input.outcome, taskStage: task.stage, runState: run.state },
      now,
    );

    return { ok: true, value: this.expand(taskId) };
  }

  async reply(taskId: string, content: string, actor: string, now: Date): Promise<Result<ExpandedTask>> {
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

    run.state = "queued";
    run.lastActivityAt = nowIso;
    run.revision += 1;

    this.appendEvent(taskId, run.id, actor, "replied", { content }, now);
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

    const result = reviewAction(action, { requiresAgentApproval: requiresAgentApproval(task.source) });
    const nowIso = now.toISOString();

    task.stage = result.stage;
    if (result.owner !== undefined) task.owner = result.owner;
    if (result.agentApprovalGranted !== undefined) task.agentApprovalGranted = result.agentApprovalGranted;
    if (action === "accept") task.completedAt = nowIso;
    task.revision += 1;
    task.updatedAt = nowIso;

    if (run && result.runState !== undefined) {
      run.state = result.runState;
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

    this.appendEvent(taskId, run ? run.id : null, actor, "reviewed", { action, feedback: feedback ?? null }, now);
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
