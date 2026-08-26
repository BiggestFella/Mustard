// Wire-format (snake_case) port of Mustard's Swift task-lifecycle enums.
//
// Swift sources of truth:
//   Sources/MustardKit/Models/TaskStage.swift        (TaskStage)
//   Sources/MustardKit/Models/Enums.swift             (TaskOwner, TaskPriority)
//   Sources/MustardKit/Models/AgentRun.swift          (AgentProvider, AgentRunState)
//   Sources/MustardKit/Models/AgentMessage.swift      (AgentMessageRole, AgentMessageKind)
//   Sources/MustardKit/Agent/AgentTurnContract.swift  (AgentTurnOutcome)
//
// Swift's raw values are camelCase (e.g. `forAgent`, `needsApproval`,
// `reviewFeedback`); this port's wire format is snake_case throughout
// (`for_agent`, `needs_approval`, `review_feedback`).

/** The single lifecycle field for a task. Mirrors Swift `TaskStage`. */
export type TaskStage =
  | "inbox"
  | "planned"
  | "scheduled"
  | "for_agent"
  | "needs_approval"
  | "queued"
  | "in_progress"
  | "needs_input"
  | "needs_review"
  | "blocked"
  | "done";

export const TASK_STAGES: readonly TaskStage[] = [
  "inbox",
  "planned",
  "scheduled",
  "for_agent",
  "needs_approval",
  "queued",
  "in_progress",
  "needs_input",
  "needs_review",
  "blocked",
  "done",
];

/**
 * The three "needs a human decision" gate stages — mirrors Swift
 * `TaskStage.isGate` (TaskStage.swift:52).
 */
export const GATE_STAGES: readonly TaskStage[] = [
  "needs_approval",
  "needs_input",
  "needs_review",
];

export function isGateStage(stage: TaskStage): boolean {
  return (GATE_STAGES as TaskStage[]).includes(stage);
}

/** Mirrors Swift `TaskOwner`. */
export type TaskOwner = "me" | "agent";

/**
 * Provider identifier for an agent run. Swift's `AgentProvider`
 * (AgentRun.swift:4) currently only models `claude` and `codex`; this port's
 * scope is explicitly wider (per task spec) to anticipate `grok`, `hermes`,
 * a `manual` (human-run) provider, and an `any` wildcard used by routing/
 * filter call sites. Note this is a deliberate divergence from the current
 * Swift source, not a bug.
 */
export type Provider = "claude" | "codex" | "grok" | "hermes" | "manual" | "any";

/** Mirrors Swift `AgentRunState` (AgentRun.swift:9). */
export type AgentRunState =
  | "queued"
  | "running"
  | "needs_input"
  | "completed"
  | "failed"
  | "cancelled"
  | "interrupted";

/** Mirrors Swift `AgentMessageRole` (AgentMessage.swift:5). */
export type MessageRole = "human" | "agent" | "system";

/** Mirrors Swift `AgentMessageKind` (AgentMessage.swift:11). */
export type MessageKind =
  | "delegation"
  | "question"
  | "answer"
  | "progress"
  | "result"
  | "review_feedback"
  | "recovery"
  | "error";

/**
 * Mirrors Swift `AgentTurnOutcome` (AgentTurnContract.swift:3) plus
 * `completion_uncertain`, which does not exist as a distinct Swift case —
 * it is the server-side name for the gated-timeout rule described in
 * AgentTaskCoordinator's retry handling: a timeout/process-death on a
 * ticket/draft action is "completion-uncertain" and must go to review
 * rather than retrying, because the task UID is binding creation metadata
 * and a blind retry could double-create.
 */
export type TurnOutcome =
  | "completed"
  | "needs_input"
  | "failed"
  | "cancelled"
  | "requires_connected_worker"
  | "completion_uncertain";

/** Mirrors Swift `TaskPriority` (Enums.swift:28). */
export type TaskPriority = "low" | "normal" | "high" | "urgent";
