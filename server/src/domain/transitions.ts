// Pure port of Mustard's Swift task-lifecycle transition rules. No I/O.
//
// Swift sources of truth:
//   Sources/MustardKit/Logic/AgentTaskTransition.swift   (outcome -> decision matrix)
//   Sources/MustardKit/Logic/PersonalBoard.swift          (approveTarget, move's ledger
//                                                           grant/revoke, agent lane set)
//   Sources/MustardKit/Logic/AgentTaskQueue.swift         (claim legality; re-exported
//                                                           here from queue.ts)
//   Sources/MustardKit/Agent/AgentTaskCoordinator.swift   (takeBack / reply / requestChanges
//                                                           legality, ~lines 240-300 and
//                                                           queueHumanTurn ~line 736,
//                                                           persistLocalCancellation ~line 910)

import type { AgentRunState, MessageKind, TaskOwner, TaskStage, TurnOutcome } from "./stages.ts";
import { isClaimable, type QueueTask } from "./queue.ts";

/**
 * Claim legality — a task is only claimable from `for_agent`/`queued` (plus
 * the fuller runnability checks: ownership, blocked, ledger approval, backoff,
 * connected-worker gating). Re-exported from queue.ts rather than
 * reimplemented, per `AgentTaskQueue.nextRunnable`'s filter
 * (AgentTaskQueue.swift:16-27) — there must be exactly one predicate for
 * "is this task claimable right now".
 */
export { isClaimable as canClaim };
export type { QueueTask };

// ---------------------------------------------------------------------------
// Agent turn outcome -> transition decision
// ---------------------------------------------------------------------------

export interface TransitionDecision {
  taskStage: TaskStage;
  runState: AgentRunState;
  releasesSlot: boolean;
  /** Only present when the outcome forces an owner change (`cancelled` reverts to `me`). */
  taskOwner?: TaskOwner;
  requiresConnectedWorker: boolean;
}

/**
 * Maps a completed agent turn's outcome to its task/run transition.
 * Mirrors `AgentTaskTransition.decision(for:)` (AgentTaskTransition.swift:24-59)
 * exactly for the five Swift-native outcomes.
 *
 * `completion_uncertain` has no Swift enum case — it is the server-side name
 * for the gated-timeout rule in AgentTaskCoordinator's retry handling: a
 * timeout or process death on a ticket/draft action must not be blindly
 * retried (the task UID is binding creation metadata, so a retry could
 * double-create), so it is routed to review exactly like a `failed` run
 * (`runState: "failed"`) but landing on `needs_review` like `completed`,
 * so a human decides whether the side effect actually happened.
 */
export function decisionForOutcome(outcome: TurnOutcome): TransitionDecision {
  switch (outcome) {
    case "needs_input":
      return {
        taskStage: "needs_input",
        runState: "needs_input",
        releasesSlot: true,
        requiresConnectedWorker: false,
      };
    case "completed":
      return {
        taskStage: "needs_review",
        runState: "completed",
        releasesSlot: true,
        requiresConnectedWorker: false,
      };
    case "requires_connected_worker":
      return {
        taskStage: "queued",
        runState: "queued",
        releasesSlot: true,
        requiresConnectedWorker: true,
      };
    case "failed":
      return {
        taskStage: "queued",
        runState: "failed",
        releasesSlot: true,
        requiresConnectedWorker: false,
      };
    case "cancelled":
      return {
        taskStage: "planned",
        runState: "cancelled",
        releasesSlot: true,
        taskOwner: "me",
        requiresConnectedWorker: false,
      };
    case "completion_uncertain":
      return {
        taskStage: "needs_review",
        runState: "failed",
        releasesSlot: true,
        requiresConnectedWorker: false,
      };
  }
}

/**
 * Message kind an applied turn outcome appends. `needs_input` -> `question`,
 * `completed` -> `result`, `failed`/`completion_uncertain` -> `error` are the
 * task brief's explicit mapping. `cancelled` is verified against Swift
 * ground truth: `AgentTaskCoordinator.apply`'s `.cancelled` branch
 * (AgentTaskCoordinator.swift:~684-692) appends a message with kind
 * `.recovery` — NOT `.error` — because a cancelled turn isn't itself a
 * failure signal, so this mirrors that exactly rather than guessing.
 * `requires_connected_worker` has no Swift-verified case checked for this
 * slice's fix pass; it keeps the pre-existing `progress` mapping (an
 * in-flight update — the task simply requeues pending a capability this
 * worker doesn't have, not a failure).
 */
export function messageKindForOutcome(outcome: TurnOutcome): MessageKind {
  switch (outcome) {
    case "needs_input":
      return "question";
    case "completed":
      return "result";
    case "failed":
    case "completion_uncertain":
      return "error";
    case "cancelled":
      return "recovery";
    case "requires_connected_worker":
      return "progress";
  }
}

// ---------------------------------------------------------------------------
// Fresh-attempt run reset (reply / request-changes)
// ---------------------------------------------------------------------------

export interface FreshAttemptRunReset {
  requiresConnectedWorker: false;
  completedAt: null;
  lastError: null;
  nextAttemptAt: null;
  autoRetryCount: 0;
}

/**
 * Field resets a human-initiated turn (reply to a question, or request
 * changes on a review) applies to the run, on top of the state transition
 * itself. Mirrors `queueHumanTurn`'s reset block
 * (AgentTaskCoordinator.swift:772-778): a human-driven turn is a fresh
 * attempt, so any backoff/retry budget or stale error from a prior failed
 * attempt is cleared. Both stores must apply this in `reply()` and
 * `review("request_changes")`.
 */
export function freshAttemptRunReset(): FreshAttemptRunReset {
  return {
    requiresConnectedWorker: false,
    completedAt: null,
    lastError: null,
    nextAttemptAt: null,
    autoRetryCount: 0,
  };
}

// ---------------------------------------------------------------------------
// Gated action types (recommendation/task action-type -> always-gated?)
// ---------------------------------------------------------------------------

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

/**
 * Mirrors `RecommendationAction.isGated` / `MustardTask.isGated` (Sources/
 * MustardKit/Logic/RecommendationAction.swift:29-33, Models/MustardTask.swift
 * :111-115): no/empty action type -> not gated; a known action type -> its
 * own gating; an unknown/typo'd token fails closed (gated). The single copy
 * — both the lease-expiry sweep (gated -> needs_review) and the approve
 * action (`approveTarget`'s `ApproveContext.isGated`) call this rather than
 * re-deriving it.
 */
export function isGatedActionType(actionType: string | null): boolean {
  if (!actionType) return false;
  if (!KNOWN_ACTION_TYPES.has(actionType)) return true; // fail closed
  return GATED_ACTION_TYPES.has(actionType);
}

// ---------------------------------------------------------------------------
// Gate approval (needs_approval / needs_review)
// ---------------------------------------------------------------------------

export interface ApproveContext {
  /**
   * A ledger-harvested meeting task's "yes, this is really mine to do"
   * decision. Mirrors `AgentInbox.isExistenceTriage(task)`. Keeping it lands
   * the task on your own board and nothing runs — not even when it carries a
   * gated action type.
   */
  isExistenceTriage: boolean;
  /** Mirrors `task.isGated` (action-type derived; always queues regardless of owner). */
  isGated: boolean;
  owner: TaskOwner;
}

/**
 * Target stage when a human approves a gate. Mirrors `PersonalBoard.approveTarget`
 * (PersonalBoard.swift:92-100). Returns `undefined` when `stage` isn't a gate stage
 * this function handles (reject/discard and the reverse transitions are the
 * caller's responsibility, same as in Swift).
 */
export function approveTarget(stage: TaskStage, ctx: ApproveContext): TaskStage | undefined {
  switch (stage) {
    case "needs_approval":
      if (ctx.isExistenceTriage) return "planned";
      return ctx.isGated || ctx.owner === "agent" ? "queued" : "needs_review";
    case "needs_review":
      return "done";
    default:
      return undefined;
  }
}

// ---------------------------------------------------------------------------
// Ledger (Do/Don't) approval grant/revoke on a board lane move
// ---------------------------------------------------------------------------

/**
 * Whether `agentApprovalGranted` should flip when a ledger-imported meeting
 * task is dropped on `toStage`. Mirrors `PersonalBoard.move`
 * (PersonalBoard.swift:72-75): dropping into `queued` grants it; dropping
 * back onto `for_agent`/`needs_approval` revokes it; any other stage leaves
 * it unchanged. Non-ledger tasks (`requiresAgentApproval === false`) are
 * never touched, matching the Swift `if MeetingTaskSource.requiresAgentApproval(...)`
 * guard.
 */
export function agentApprovalGrantForMove(
  requiresAgentApproval: boolean,
  currentGranted: boolean,
  toStage: TaskStage,
): boolean {
  if (!requiresAgentApproval) return currentGranted;
  if (toStage === "queued") return true;
  if (toStage === "for_agent" || toStage === "needs_approval") return false;
  return currentGranted;
}

// ---------------------------------------------------------------------------
// Take-back / reply / request-changes legality
// ---------------------------------------------------------------------------

/**
 * Stages `takeBack` may act from. Mirrors `AgentTaskCoordinator.takeBack`'s
 * `legalStages` set (AgentTaskCoordinator.swift:~243-247).
 */
const TAKE_BACK_LEGAL_STAGES: readonly TaskStage[] = [
  "inbox",
  "for_agent",
  "needs_approval",
  "queued",
  "in_progress",
  "needs_input",
  "needs_review",
];

/** Mirrors `AgentTaskCoordinator.takeBack`'s guard: `task.owner == .agent && legalStages.contains(task.stage)`. */
export function canTakeBack(owner: TaskOwner, stage: TaskStage): boolean {
  return owner === "agent" && (TAKE_BACK_LEGAL_STAGES as TaskStage[]).includes(stage);
}

/**
 * Mirrors the `.answer` branch of `queueHumanTurn` (AgentTaskCoordinator.swift:753-756):
 * `task.owner == .agent && task.stage == .needsInput && run.state == .needsInput`.
 * The caller is still responsible for the non-pure guards Swift also applies
 * (non-empty reply text, and a run must actually exist) — this function only
 * covers the stage/owner/run-state legality.
 */
export function canReply(owner: TaskOwner, stage: TaskStage, runState: AgentRunState): boolean {
  return owner === "agent" && stage === "needs_input" && runState === "needs_input";
}

/**
 * Mirrors the `.reviewFeedback` branch of `queueHumanTurn` (AgentTaskCoordinator.swift:757-761):
 * `task.owner == .agent && task.stage == .needsReview` — any run state is legal,
 * including a completion-uncertain review whose run ended `.failed` rather than `.completed`.
 */
export function canRequestChanges(owner: TaskOwner, stage: TaskStage): boolean {
  return owner === "agent" && stage === "needs_review";
}

// ---------------------------------------------------------------------------
// Review actions (Needs Review column: Accept / Request changes / Take back)
// ---------------------------------------------------------------------------

/**
 * `approve` is a distinct action from the three below: it resolves a
 * `needs_approval`/`needs_review` gate via `approveTarget` rather than
 * `reviewAction` (see that function's narrower parameter type). It is
 * included here so the wire-level action vocabulary
 * (`POST /v1/tasks/:id/review`'s `action` field) has one enum, not two.
 */
export type ReviewActionKind = "accept" | "request_changes" | "take_back" | "approve";

/** The subset of `ReviewActionKind` that `reviewAction` (below) handles. */
export type PlainReviewActionKind = Exclude<ReviewActionKind, "approve">;

export interface ReviewContext {
  /**
   * Whether the task being reviewed is ledger-imported meeting work
   * (`MeetingTaskSource.requiresAgentApproval(source)`). Only affects
   * `take_back`: Swift's `persistLocalCancellation`
   * (AgentTaskCoordinator.swift:910-921) unconditionally revokes the ledger
   * grant on take-back, regardless of target stage — unlike a plain board
   * move via `agentApprovalGrantForMove`, where dropping onto `planned`
   * would leave the grant untouched. Omit or pass `false` for non-ledger tasks.
   */
  requiresAgentApproval?: boolean;
}

export interface ReviewResult {
  stage: TaskStage;
  owner?: TaskOwner;
  runState?: AgentRunState;
  /** Only present for `take_back` on a ledger-gated task; see `ReviewContext`. */
  agentApprovalGranted?: boolean;
}

/**
 * Resolves a Needs Review column action to its resulting task (+ run) state.
 *
 *  - `accept`: `AgentTaskCoordinator.accept` requires `task.stage == .needsReview`
 *    (caller-checked; not re-validated here) then `TaskCompletion.complete` marks
 *    the task `done`. Owner and run are untouched by this path.
 *  - `request_changes`: the `.reviewFeedback` branch of `queueHumanTurn`
 *    (AgentTaskCoordinator.swift:770-772) sets `task.owner = .agent`,
 *    `task.stage = .queued`, `run.state = .queued`.
 *  - `take_back`: `persistLocalCancellation` (AgentTaskCoordinator.swift:919-928)
 *    sets `task.owner = .me`, `task.stage = .planned`, and — when a run exists —
 *    `run.state = .cancelled`; it also revokes the ledger grant unconditionally
 *    when the task requires agent approval (see `ReviewContext`).
 */
export function reviewAction(action: PlainReviewActionKind, ctx: ReviewContext = {}): ReviewResult {
  switch (action) {
    case "accept":
      return { stage: "done" };
    case "request_changes":
      return { stage: "queued", owner: "agent", runState: "queued" };
    case "take_back": {
      const result: ReviewResult = { stage: "planned", owner: "me", runState: "cancelled" };
      if (ctx.requiresAgentApproval) {
        result.agentApprovalGranted = false;
      }
      return result;
    }
  }
}
