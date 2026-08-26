// The storage seam for the task service. Every method is ONE atomic operation:
// implementations run each inside a single transaction (pg.ts) or a synchronous
// mutation (memory.ts). Lifecycle legality lives in src/domain/* — store
// implementations call those pure functions INSIDE the transaction so a
// check-then-write can never race. Routes stay thin: auth → store call → HTTP.
//
// Conventions:
// - Result objects, not thrown errors, for expected failures ({ ok: false,
//   error }) so routes map them to status codes without try/catch soup.
// - Every mutation appends the corresponding task_events row in the same
//   transaction; `seq` values come back so callers can report cursors.
// - `now` is always injectable for tests.

import type {
  AgentRunState,
  MessageKind,
  MessageRole,
  Provider,
  TaskOwner,
  TaskPriority,
  TaskStage,
  TurnOutcome,
} from "../domain/stages.ts";
import type { ClientScope } from "../auth.ts";
import type { ReviewActionKind } from "../domain/transitions.ts";

// ---------- rows ----------

export interface TaskLinkJSON {
  label: string;
  url: string;
}

export interface TaskRow {
  id: string;
  title: string;
  notes: string;
  stage: TaskStage;
  owner: TaskOwner;
  selectedProvider: Provider | null;
  priority: TaskPriority;
  scheduledAt: string | null;
  dueAt: string | null;
  isTimed: boolean;
  focusOnDay: string | null;
  estimateMinutes: number;
  completedAt: string | null;
  carriedForwardAt: string | null;
  recurrence: string | null;
  recurredFrom: string | null;
  autoCompleted: boolean;
  tags: string[];
  links: TaskLinkJSON[];
  source: string;
  sourceURL: string | null;
  sourceContext: string;
  originKey: string | null;
  agentApprovalGranted: boolean;
  captureState: string | null;
  captureTranscript: string | null;
  blockedByTaskId: string | null;
  blockedReason: string;
  parentTaskId: string | null;
  listId: string | null;
  actionType: string | null;
  confidence: number | null;
  revision: number;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
}

export interface TaskContextRow {
  taskId: string;
  noteRefs: unknown[];
  urls: string[];
  artifactIds: string[];
  guidance: string | null;
}

export interface AgentRunRow {
  id: string;
  taskId: string;
  provider: Provider;
  state: AgentRunState;
  providerSessionId: string | null;
  project: string;
  requiresConnectedWorker: boolean;
  attemptCount: number;
  resumeCount: number;
  autoRetryCount: number;
  nextAttemptAt: string | null;
  lastOutcome: string | null;
  lastError: string | null;
  startedAt: string | null;
  lastActivityAt: string;
  completedAt: string | null;
  revision: number;
}

export interface AgentMessageRow {
  id: string;
  runId: string;
  seq: number;
  role: MessageRole;
  kind: MessageKind;
  content: string;
  links: TaskLinkJSON[];
  providerTurnId: string | null;
  createdAt: string;
}

export interface ArtifactRow {
  id: string;
  taskId: string;
  runId: string | null;
  kind: string;
  title: string;
  storageKey: string;
  mime: string | null;
  sizeBytes: number | null;
  createdBy: string | null;
  createdAt: string;
}

export interface LeaseRow {
  id: string;
  taskId: string;
  clientId: string;
  createdAt: string;
  renewedAt: string | null;
  expiresAt: string;
  released: boolean;
}

export interface TaskEventRow {
  seq: number;
  taskId: string;
  runId: string | null;
  actor: string | null;
  type: string;
  // `object`, not `Record<string, unknown>`: every payload is built by one of
  // src/domain/events.ts's typed builder functions (named interfaces with no
  // index signature), and `Record<string, unknown>` cannot accept those
  // without a cast. Nothing in this codebase indexes into `payload` by key —
  // it's opaque here, only ever JSON-serialized on the way out.
  payload: object;
  createdAt: string;
}

export interface ClientRow {
  id: string;
  name: string;
  kind: ClientScope;
  provider: Provider | null;
  enabled: boolean;
}

// ---------- inputs / results ----------

export type StoreError =
  | "not_found"
  | "revision_conflict"
  | "already_leased"
  | "not_claimable"
  | "lease_required"
  | "lease_expired"
  | "illegal_transition";

export type Result<T> = { ok: true; value: T } | { ok: false; error: StoreError; detail?: string };

/**
 * Outcome of `reserveIdempotent`, the reserve-then-act half of the
 * idempotency-key flow (see `Store.reserveIdempotent`'s doc comment below).
 * `"reserved"` means the caller now owns this key and must eventually call
 * `completeIdempotent`; `"in_flight"` means another request already reserved
 * it and hasn't completed yet; `"complete"` replays the prior response.
 */
export type IdempotencyReservation =
  | { status: "reserved" }
  | { status: "in_flight" }
  | { status: "complete"; response: { status: number; response: unknown } };

export interface CreateTaskInput {
  id?: string;
  title: string;
  notes?: string;
  stage?: TaskStage;
  owner?: TaskOwner;
  selectedProvider?: Provider | null;
  priority?: TaskPriority;
  scheduledAt?: string | null;
  estimateMinutes?: number;
  tags?: string[];
  links?: TaskLinkJSON[];
  source?: string;
  listId?: string | null;
  context?: Omit<TaskContextRow, "taskId"> | null;
  project?: string;
}

export interface TaskPatch {
  title?: string;
  notes?: string;
  stage?: TaskStage;
  owner?: TaskOwner;
  priority?: TaskPriority;
  scheduledAt?: string | null;
  dueAt?: string | null;
  estimateMinutes?: number;
  tags?: string[];
  links?: TaskLinkJSON[];
  listId?: string | null;
  blockedReason?: string;
}

export interface TaskFilter {
  stage?: TaskStage;
  owner?: TaskOwner;
  provider?: Provider;
  updatedAfter?: string;
  claimableBy?: Provider; // computed claimable list for a worker's provider
  limit?: number;
}

export interface ExpandedTask {
  task: TaskRow;
  context: TaskContextRow | null;
  run: AgentRunRow | null;
  messages: AgentMessageRow[];
  artifacts: ArtifactRow[];
  lease: LeaseRow | null; // active lease if any
}

export interface OutcomeInput {
  outcome: TurnOutcome;
  message: string;
  questions?: string[];
  summary?: string;
  links?: TaskLinkJSON[];
  providerTurnId?: string | null;
  providerSessionId?: string | null;
  errorCategory?: string | null;
}

export interface MessageInput {
  role: MessageRole;
  kind: MessageKind;
  content: string;
  links?: TaskLinkJSON[];
  providerTurnId?: string | null;
}

export interface ArtifactInput {
  taskId: string;
  runId?: string | null;
  kind: string;
  title: string;
  storageKey: string;
  mime?: string | null;
  sizeBytes?: number | null;
}

// ---------- the seam ----------

export interface Store {
  // auth
  getClientByTokenHash(tokenHash: string): Promise<ClientRow | null>;
  touchClientSeen(clientId: string, now: Date): Promise<void>;

  // idempotency: reserve-then-act, not check-then-act — a plain get/put pair
  // left a race between two concurrent requests carrying the same
  // Idempotency-Key (both could see "nothing cached yet" and both execute).
  // `reserveIdempotent` atomically claims the key (inserting a `pending`
  // marker, or reporting that one already exists); the caller then always
  // calls `completeIdempotent` with the final outcome — success or failure —
  // once the underlying operation has run, so replays return the identical
  // response as the first attempt.
  reserveIdempotent(clientId: string, key: string, route: string, now: Date): Promise<IdempotencyReservation>;
  completeIdempotent(clientId: string, key: string, route: string, status: number, response: unknown): Promise<void>;

  // tasks
  createTask(input: CreateTaskInput, actor: string, now: Date): Promise<Result<TaskRow>>;
  listTasks(filter: TaskFilter, now: Date): Promise<TaskRow[]>;
  getTask(taskId: string): Promise<Result<ExpandedTask>>;
  // Optimistic concurrency: fails with revision_conflict unless ifRevision matches.
  updateTask(taskId: string, patch: TaskPatch, ifRevision: number, actor: string, now: Date): Promise<Result<TaskRow>>;
  setProvider(taskId: string, provider: Provider | null, actor: string, now: Date): Promise<Result<TaskRow>>;

  // worker loop — all lease-aware, all atomic
  // Claim: task must be claimable (domain isClaimable) and provider-compatible
  // with the client; expires stale leases lazily; sets stage=in_progress,
  // run created/updated to running, appends event.
  claimTask(taskId: string, client: ClientRow, ttlSeconds: number, now: Date): Promise<Result<{ lease: LeaseRow; task: ExpandedTask }>>;
  renewLease(leaseId: string, clientId: string, ttlSeconds: number, now: Date): Promise<Result<LeaseRow>>;
  releaseLease(leaseId: string, clientId: string, now: Date): Promise<Result<void>>;
  // Sweep expired leases: mark released, route task per domain rules
  // (gated action -> needs_review "completion uncertain", else queued), events.
  expireLeases(now: Date): Promise<TaskEventRow[]>;

  // conversation
  // Workers must hold the live lease; user_app appends freely.
  appendMessage(taskId: string, client: ClientRow, input: MessageInput, now: Date): Promise<Result<AgentMessageRow>>;
  // Applies domain decisionForOutcome inside the transaction: message + task
  // stage + run state + lease release + event. completed merges links onto task.
  applyOutcome(taskId: string, client: ClientRow, input: OutcomeInput, now: Date): Promise<Result<ExpandedTask>>;
  // Leon answers a Needs You question (user_app only; legality via canReply).
  reply(taskId: string, content: string, actor: string, now: Date): Promise<Result<ExpandedTask>>;
  // accept | request_changes | take_back via domain reviewAction (user_app only).
  review(taskId: string, action: ReviewActionKind, feedback: string | undefined, actor: string, now: Date): Promise<Result<ExpandedTask>>;

  // artifacts
  createArtifact(input: ArtifactInput, actor: string, now: Date): Promise<Result<ArtifactRow>>;
  getArtifact(artifactId: string): Promise<ArtifactRow | null>;

  // sync cursor
  listEvents(afterSeq: number, limit: number): Promise<TaskEventRow[]>;
}
