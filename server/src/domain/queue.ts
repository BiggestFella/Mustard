// Pure port of the agent work queue's claim predicate and ordering.
//
// Swift source of truth: Sources/MustardKit/Logic/AgentTaskQueue.swift
//   - `nextRunnable` (lines 14-29) is the claim filter + `.min(by: precedes)`.
//   - `precedes` (lines 65-71) and `priorityRank` (lines 73-80) are the
//     ordering comparator.
//
// No I/O: callers own fetching the candidate task list and passing `now`.

import type { TaskOwner, TaskPriority, TaskStage } from "./stages.ts";

/** The subset of an agent run's fields the queue predicate needs. */
export interface QueueRun {
  requiresConnectedWorker: boolean;
  /**
   * Earliest time this run's task may be picked up again after a scheduled
   * backoff (AgentRetryPolicy). `null` means immediately runnable.
   * ISO 8601 string.
   */
  nextAttemptAt: string | null;
}

/** The subset of a task's fields the queue predicate + ordering need. */
export interface QueueTask {
  uid: string;
  owner: TaskOwner;
  stage: TaskStage;
  isBlocked: boolean;
  priority: TaskPriority;
  /** ISO 8601 string. */
  createdAt: string;
  /**
   * Whether this task's source is ledger-imported meeting work, which must
   * carry the persisted Do/Don't bit (`agentApprovalGranted`) before it is
   * claimable. Mirrors `MeetingTaskSource.requiresAgentApproval(source)`.
   * Recording-originated tasks (and anything else) pass `false` here and
   * are already locally approved.
   */
  requiresAgentApproval: boolean;
  agentApprovalGranted: boolean;
  run: QueueRun | null;
}

const PRIORITY_RANK: Record<TaskPriority, number> = {
  urgent: 0,
  high: 1,
  normal: 2,
  low: 3,
};

function isBackingOff(task: QueueTask, now: Date): boolean {
  const nextAttemptAt = task.run?.nextAttemptAt ?? null;
  if (nextAttemptAt === null) return false;
  return new Date(nextAttemptAt).getTime() > now.getTime();
}

/**
 * Whether `task` is currently claimable by the agent queue. Mirrors the
 * `.filter { ... }` predicate inside `AgentTaskQueue.nextRunnable`
 * (AgentTaskQueue.swift:16-27).
 */
export function isClaimable(task: QueueTask, now: Date = new Date()): boolean {
  if (task.owner !== "agent") return false;
  if (task.stage !== "for_agent" && task.stage !== "queued") return false;
  if (task.isBlocked) return false;
  if (task.requiresAgentApproval && !task.agentApprovalGranted) return false;
  if (task.run?.requiresConnectedWorker === true) return false;
  if (isBackingOff(task, now)) return false;
  return true;
}

/**
 * Ordering comparator: priority rank (urgent < high < normal < low), then
 * `createdAt` ascending, then `uid` ascending as a deterministic tiebreak.
 * Mirrors `AgentTaskQueue.precedes` (AgentTaskQueue.swift:65-71). Returns a
 * negative number when `a` sorts before `b`, positive when after, zero when
 * equal in every ordering key (which, since `uid` is a total order, only
 * happens when `a` and `b` are the same task).
 */
export function compareQueueOrder(a: QueueTask, b: QueueTask): number {
  const rankDiff = PRIORITY_RANK[a.priority] - PRIORITY_RANK[b.priority];
  if (rankDiff !== 0) return rankDiff;

  const createdDiff = new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime();
  if (createdDiff !== 0) return createdDiff;

  if (a.uid < b.uid) return -1;
  if (a.uid > b.uid) return 1;
  return 0;
}

/**
 * The single task the agent queue should pick up next, or `undefined` if
 * nothing is claimable. Mirrors `AgentTaskQueue.nextRunnable`
 * (AgentTaskQueue.swift:14-29).
 */
export function nextRunnable(tasks: readonly QueueTask[], now: Date = new Date()): QueueTask | undefined {
  let best: QueueTask | undefined;
  for (const task of tasks) {
    if (!isClaimable(task, now)) continue;
    if (best === undefined || compareQueueOrder(task, best) < 0) {
      best = task;
    }
  }
  return best;
}
