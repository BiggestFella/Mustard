import { describe, expect, it } from "vitest";
import {
  agentApprovalGrantForMove,
  approveTarget,
  canReply,
  canRequestChanges,
  canTakeBack,
  decisionForOutcome,
  reviewAction,
} from "../src/domain/transitions.ts";
import type { TurnOutcome } from "../src/domain/stages.ts";

describe("decisionForOutcome", () => {
  it("needs_input releases the slot and puts both task and run into needs_input", () => {
    expect(decisionForOutcome("needs_input")).toEqual({
      taskStage: "needs_input",
      runState: "needs_input",
      releasesSlot: true,
      requiresConnectedWorker: false,
    });
  });

  it("completed sends the task to review with a completed run", () => {
    expect(decisionForOutcome("completed")).toEqual({
      taskStage: "needs_review",
      runState: "completed",
      releasesSlot: true,
      requiresConnectedWorker: false,
    });
  });

  it("requires_connected_worker re-queues and flags requiresConnectedWorker", () => {
    expect(decisionForOutcome("requires_connected_worker")).toEqual({
      taskStage: "queued",
      runState: "queued",
      releasesSlot: true,
      requiresConnectedWorker: true,
    });
  });

  it("failed re-queues the task with a failed run", () => {
    expect(decisionForOutcome("failed")).toEqual({
      taskStage: "queued",
      runState: "failed",
      releasesSlot: true,
      requiresConnectedWorker: false,
    });
  });

  it("cancelled reverts ownership to me and plans the task", () => {
    expect(decisionForOutcome("cancelled")).toEqual({
      taskStage: "planned",
      runState: "cancelled",
      releasesSlot: true,
      taskOwner: "me",
      requiresConnectedWorker: false,
    });
  });

  it("completion_uncertain sends the task to review but marks the run failed", () => {
    expect(decisionForOutcome("completion_uncertain")).toEqual({
      taskStage: "needs_review",
      runState: "failed",
      releasesSlot: true,
      requiresConnectedWorker: false,
    });
  });

  it("covers every outcome without falling through to a default", () => {
    const outcomes: TurnOutcome[] = [
      "needs_input",
      "completed",
      "requires_connected_worker",
      "failed",
      "cancelled",
      "completion_uncertain",
    ];
    for (const outcome of outcomes) {
      expect(() => decisionForOutcome(outcome)).not.toThrow();
    }
  });
});

describe("approveTarget", () => {
  it("existence triage always lands on planned, even when gated", () => {
    expect(
      approveTarget("needs_approval", { isExistenceTriage: true, isGated: true, owner: "agent" }),
    ).toBe("planned");
    expect(
      approveTarget("needs_approval", { isExistenceTriage: true, isGated: false, owner: "me" }),
    ).toBe("planned");
  });

  it("a gated action queues regardless of owner", () => {
    expect(
      approveTarget("needs_approval", { isExistenceTriage: false, isGated: true, owner: "me" }),
    ).toBe("queued");
  });

  it("an agent-owned non-gated action queues too", () => {
    expect(
      approveTarget("needs_approval", { isExistenceTriage: false, isGated: false, owner: "agent" }),
    ).toBe("queued");
  });

  it("a personal non-gated action goes straight to review", () => {
    expect(
      approveTarget("needs_approval", { isExistenceTriage: false, isGated: false, owner: "me" }),
    ).toBe("needs_review");
  });

  it("needs_review approves to done", () => {
    expect(approveTarget("needs_review", { isExistenceTriage: false, isGated: false, owner: "me" })).toBe(
      "done",
    );
  });

  it("returns undefined for non-gate stages", () => {
    for (const stage of ["inbox", "planned", "queued", "in_progress", "done"] as const) {
      expect(approveTarget(stage, { isExistenceTriage: false, isGated: false, owner: "me" })).toBeUndefined();
    }
  });
});

describe("agentApprovalGrantForMove", () => {
  it("grants on drop into queued", () => {
    expect(agentApprovalGrantForMove(true, false, "queued")).toBe(true);
  });

  it("revokes on drop back onto for_agent", () => {
    expect(agentApprovalGrantForMove(true, true, "for_agent")).toBe(false);
  });

  it("revokes on drop back onto needs_approval", () => {
    expect(agentApprovalGrantForMove(true, true, "needs_approval")).toBe(false);
  });

  it("leaves the grant unchanged for any other stage", () => {
    expect(agentApprovalGrantForMove(true, true, "planned")).toBe(true);
    expect(agentApprovalGrantForMove(true, false, "in_progress")).toBe(false);
    expect(agentApprovalGrantForMove(true, true, "done")).toBe(true);
  });

  it("never touches the grant for a non-ledger task", () => {
    expect(agentApprovalGrantForMove(false, false, "queued")).toBe(false);
    expect(agentApprovalGrantForMove(false, true, "for_agent")).toBe(true);
  });
});

describe("take-back / reply / request-changes legality", () => {
  const legalTakeBackStages = [
    "inbox",
    "for_agent",
    "needs_approval",
    "queued",
    "in_progress",
    "needs_input",
    "needs_review",
  ] as const;

  it("take-back is legal from every agent-owned lane stage plus inbox", () => {
    for (const stage of legalTakeBackStages) {
      expect(canTakeBack("agent", stage)).toBe(true);
    }
  });

  it("take-back is illegal once the task is done, or scheduled/blocked/planned", () => {
    for (const stage of ["done", "scheduled", "blocked", "planned"] as const) {
      expect(canTakeBack("agent", stage)).toBe(false);
    }
  });

  it("take-back is illegal for a me-owned task even in a nominally legal stage", () => {
    expect(canTakeBack("me", "needs_review")).toBe(false);
  });

  it("reply is legal only when task and run both say needs_input, owned by agent", () => {
    expect(canReply("agent", "needs_input", "needs_input")).toBe(true);
  });

  it("reply is illegal if the run has moved on (e.g. queued after the human already answered)", () => {
    expect(canReply("agent", "needs_input", "queued")).toBe(false);
  });

  it("reply is illegal if the task stage isn't needs_input even if the run still is", () => {
    expect(canReply("agent", "needs_review", "needs_input")).toBe(false);
  });

  it("reply is illegal for a me-owned task", () => {
    expect(canReply("me", "needs_input", "needs_input")).toBe(false);
  });

  it("request-changes is legal for any run state as long as the task is in needs_review", () => {
    for (const runState of ["completed", "failed", "cancelled", "queued", "running"] as const) {
      expect(canRequestChanges("agent", "needs_review")).toBe(true);
      void runState; // run state is intentionally not consulted (matches Swift)
    }
  });

  it("request-changes is illegal outside needs_review or for a me-owned task", () => {
    expect(canRequestChanges("agent", "in_progress")).toBe(false);
    expect(canRequestChanges("me", "needs_review")).toBe(false);
  });
});

describe("reviewAction", () => {
  it("accept resolves to done with no owner/run change", () => {
    expect(reviewAction("accept")).toEqual({ stage: "done" });
  });

  it("request_changes re-queues, keeping the agent as owner", () => {
    expect(reviewAction("request_changes")).toEqual({
      stage: "queued",
      owner: "agent",
      runState: "queued",
    });
  });

  it("take_back plans the task, reverts ownership, and cancels the run", () => {
    expect(reviewAction("take_back")).toEqual({
      stage: "planned",
      owner: "me",
      runState: "cancelled",
    });
  });

  it("take_back on a ledger-gated task also revokes the Do/Don't grant", () => {
    expect(reviewAction("take_back", { requiresAgentApproval: true })).toEqual({
      stage: "planned",
      owner: "me",
      runState: "cancelled",
      agentApprovalGranted: false,
    });
  });

  it("take_back on a non-ledger task never mentions the grant", () => {
    const result = reviewAction("take_back", { requiresAgentApproval: false });
    expect(result).not.toHaveProperty("agentApprovalGranted");
  });
});
