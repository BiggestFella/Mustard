// Single event-type vocabulary + payload shapes for `task_events` rows.
// Both src/db/memory.ts and src/db/pg.ts MUST emit every event exclusively
// through this module's constants and payload builders — otherwise
// GET /v1/events (the sync cursor both the Mac app and workers read) returns
// a different shape depending on which store answered it, which defeats the
// whole point of a shared wire contract. No I/O: pure string constants and
// object-shaping functions.

import type { AgentRunState, Provider, TaskStage, TurnOutcome } from "./stages.ts";
import type { ReviewActionKind } from "./transitions.ts";

export const EVENT_TASK_CREATED = "task_created";
export const EVENT_TASK_UPDATED = "task_updated";
export const EVENT_PROVIDER_ASSIGNED = "provider_assigned";
export const EVENT_TASK_CLAIMED = "task_claimed";
export const EVENT_LEASE_RENEWED = "lease_renewed";
export const EVENT_LEASE_RELEASED = "lease_released";
export const EVENT_LEASE_EXPIRED = "lease_expired";
export const EVENT_MESSAGE_APPENDED = "message_appended";
export const EVENT_OUTCOME_APPLIED = "outcome_applied";
export const EVENT_REPLIED = "replied";
export const EVENT_REVIEWED = "reviewed";
export const EVENT_APPROVED = "approved";

export interface TaskCreatedPayload {
  title: string;
  stage: TaskStage;
}
export function taskCreatedPayload(title: string, stage: TaskStage): TaskCreatedPayload {
  return { title, stage };
}

export interface TaskUpdatedPayload {
  patch: object;
}
export function taskUpdatedPayload(patch: object): TaskUpdatedPayload {
  return { patch };
}

export interface ProviderAssignedPayload {
  provider: Provider | null;
}
export function providerAssignedPayload(provider: Provider | null): ProviderAssignedPayload {
  return { provider };
}

export interface TaskClaimedPayload {
  leaseId: string;
  runId: string;
}
export function taskClaimedPayload(leaseId: string, runId: string): TaskClaimedPayload {
  return { leaseId, runId };
}

export interface LeasePayload {
  leaseId: string;
}
export function leaseRenewedPayload(leaseId: string): LeasePayload {
  return { leaseId };
}
export function leaseReleasedPayload(leaseId: string): LeasePayload {
  return { leaseId };
}
export function leaseExpiredPayload(leaseId: string): LeasePayload {
  return { leaseId };
}

export interface MessageAppendedPayload {
  messageId: string;
  kind: string;
}
export function messageAppendedPayload(messageId: string, kind: string): MessageAppendedPayload {
  return { messageId, kind };
}

export interface OutcomeAppliedPayload {
  outcome: TurnOutcome;
  taskStage: TaskStage;
  runState: AgentRunState;
  errorCategory?: string | null;
}
export function outcomeAppliedPayload(
  outcome: TurnOutcome,
  taskStage: TaskStage,
  runState: AgentRunState,
  errorCategory?: string | null,
): OutcomeAppliedPayload {
  const payload: OutcomeAppliedPayload = { outcome, taskStage, runState };
  if (errorCategory !== undefined) payload.errorCategory = errorCategory;
  return payload;
}

export interface RepliedPayload {
  content: string;
}
export function repliedPayload(content: string): RepliedPayload {
  return { content };
}

export interface ReviewedPayload {
  action: ReviewActionKind;
}
export function reviewedPayload(action: ReviewActionKind): ReviewedPayload {
  return { action };
}

export interface ApprovedPayload {
  fromStage: TaskStage;
  toStage: TaskStage;
}
export function approvedPayload(fromStage: TaskStage, toStage: TaskStage): ApprovedPayload {
  return { fromStage, toStage };
}
