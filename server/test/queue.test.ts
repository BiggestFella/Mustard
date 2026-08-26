import { describe, expect, it } from "vitest";
import {
  compareQueueOrder,
  computeIsBlocked,
  isClaimable,
  nextRunnable,
  providerMatches,
  requiresLedgerApproval,
  type QueueTask,
} from "../src/domain/queue.ts";

function task(overrides: Partial<QueueTask> & { uid: string }): QueueTask {
  return {
    owner: "agent",
    stage: "for_agent",
    isBlocked: false,
    priority: "normal",
    createdAt: "2026-08-26T00:00:00.000Z",
    requiresAgentApproval: false,
    agentApprovalGranted: false,
    run: null,
    ...overrides,
  };
}

const NOW = new Date("2026-08-26T12:00:00.000Z");

describe("isClaimable", () => {
  it("claims a plain for_agent task owned by the agent", () => {
    expect(isClaimable(task({ uid: "t1" }), NOW)).toBe(true);
  });

  it("claims a plain queued task too", () => {
    expect(isClaimable(task({ uid: "t1", stage: "queued" }), NOW)).toBe(true);
  });

  it("rejects a me-owned task", () => {
    expect(isClaimable(task({ uid: "t1", owner: "me" }), NOW)).toBe(false);
  });

  it("rejects any stage other than for_agent/queued", () => {
    for (const stage of ["inbox", "planned", "needs_approval", "in_progress", "needs_input", "needs_review", "blocked", "done"] as const) {
      expect(isClaimable(task({ uid: "t1", stage }), NOW)).toBe(false);
    }
  });

  it("rejects a blocked task", () => {
    expect(isClaimable(task({ uid: "t1", isBlocked: true }), NOW)).toBe(false);
  });

  it("rejects ledger-imported work that hasn't been granted approval", () => {
    expect(
      isClaimable(task({ uid: "t1", requiresAgentApproval: true, agentApprovalGranted: false }), NOW),
    ).toBe(false);
  });

  it("claims ledger-imported work once approval is granted", () => {
    expect(
      isClaimable(task({ uid: "t1", requiresAgentApproval: true, agentApprovalGranted: true }), NOW),
    ).toBe(true);
  });

  it("recording-originated work (requiresAgentApproval false) is claimable without a grant", () => {
    expect(
      isClaimable(task({ uid: "t1", requiresAgentApproval: false, agentApprovalGranted: false }), NOW),
    ).toBe(true);
  });

  it("rejects a run flagged requiresConnectedWorker", () => {
    expect(
      isClaimable(
        task({ uid: "t1", run: { requiresConnectedWorker: true, nextAttemptAt: null } }),
        NOW,
      ),
    ).toBe(false);
  });

  it("rejects a run still backing off (nextAttemptAt in the future)", () => {
    expect(
      isClaimable(
        task({
          uid: "t1",
          run: { requiresConnectedWorker: false, nextAttemptAt: "2026-08-26T12:00:01.000Z" },
        }),
        NOW,
      ),
    ).toBe(false);
  });

  it("claims a run whose backoff has already elapsed", () => {
    expect(
      isClaimable(
        task({
          uid: "t1",
          run: { requiresConnectedWorker: false, nextAttemptAt: "2026-08-26T11:59:59.000Z" },
        }),
        NOW,
      ),
    ).toBe(true);
  });

  it("treats nextAttemptAt exactly equal to now as runnable (not strictly in the future)", () => {
    expect(
      isClaimable(
        task({
          uid: "t1",
          run: { requiresConnectedWorker: false, nextAttemptAt: NOW.toISOString() },
        }),
        NOW,
      ),
    ).toBe(true);
  });
});

describe("compareQueueOrder", () => {
  it("ranks urgent before high before normal before low", () => {
    const urgent = task({ uid: "a", priority: "urgent" });
    const high = task({ uid: "b", priority: "high" });
    const normal = task({ uid: "c", priority: "normal" });
    const low = task({ uid: "d", priority: "low" });
    expect(compareQueueOrder(urgent, high)).toBeLessThan(0);
    expect(compareQueueOrder(high, normal)).toBeLessThan(0);
    expect(compareQueueOrder(normal, low)).toBeLessThan(0);
    expect(compareQueueOrder(low, urgent)).toBeGreaterThan(0);
  });

  it("breaks a priority tie by createdAt ascending", () => {
    const earlier = task({ uid: "a", createdAt: "2026-08-26T00:00:00.000Z" });
    const later = task({ uid: "b", createdAt: "2026-08-26T01:00:00.000Z" });
    expect(compareQueueOrder(earlier, later)).toBeLessThan(0);
    expect(compareQueueOrder(later, earlier)).toBeGreaterThan(0);
  });

  it("breaks a priority+createdAt tie by uid ascending", () => {
    const a = task({ uid: "aaa" });
    const b = task({ uid: "bbb" });
    expect(compareQueueOrder(a, b)).toBeLessThan(0);
    expect(compareQueueOrder(b, a)).toBeGreaterThan(0);
  });

  it("is zero only for the same task compared to itself", () => {
    const a = task({ uid: "same" });
    expect(compareQueueOrder(a, a)).toBe(0);
  });
});

describe("nextRunnable", () => {
  it("returns undefined when nothing is claimable", () => {
    expect(nextRunnable([task({ uid: "t1", owner: "me" })], NOW)).toBeUndefined();
  });

  it("picks the highest-priority claimable task", () => {
    const low = task({ uid: "a", priority: "low" });
    const urgent = task({ uid: "b", priority: "urgent" });
    const normal = task({ uid: "c", priority: "normal" });
    expect(nextRunnable([low, urgent, normal], NOW)?.uid).toBe("b");
  });

  it("skips a higher-priority task that isn't claimable", () => {
    const blockedUrgent = task({ uid: "a", priority: "urgent", isBlocked: true });
    const claimableNormal = task({ uid: "b", priority: "normal" });
    expect(nextRunnable([blockedUrgent, claimableNormal], NOW)?.uid).toBe("b");
  });

  it("falls back to createdAt then uid when priorities tie", () => {
    const t1 = task({ uid: "z", createdAt: "2026-08-26T00:00:00.000Z" });
    const t2 = task({ uid: "a", createdAt: "2026-08-26T00:00:00.000Z" });
    // Same priority and createdAt: uid "a" sorts before "z".
    expect(nextRunnable([t1, t2], NOW)?.uid).toBe("a");
  });

  it("is deterministic regardless of input order", () => {
    const tasks = [
      task({ uid: "c", priority: "normal", createdAt: "2026-08-26T02:00:00.000Z" }),
      task({ uid: "a", priority: "urgent", createdAt: "2026-08-26T03:00:00.000Z" }),
      task({ uid: "b", priority: "urgent", createdAt: "2026-08-26T01:00:00.000Z" }),
    ];
    const forward = nextRunnable(tasks, NOW)?.uid;
    const reversed = nextRunnable([...tasks].reverse(), NOW)?.uid;
    expect(forward).toBe("b");
    expect(reversed).toBe("b");
  });

  it("honours next_attempt_at gating end-to-end", () => {
    const backingOff = task({
      uid: "a",
      priority: "urgent",
      run: { requiresConnectedWorker: false, nextAttemptAt: "2026-08-26T13:00:00.000Z" },
    });
    const runnable = task({ uid: "b", priority: "low" });
    expect(nextRunnable([backingOff, runnable], NOW)?.uid).toBe("b");
  });
});

describe("providerMatches", () => {
  it("never matches a client with no provider, even against an unassigned task", () => {
    expect(providerMatches(null, null)).toBe(false);
    expect(providerMatches("claude", null)).toBe(false);
    expect(providerMatches("any", null)).toBe(false);
  });

  it("an unassigned (null) task matches any provider-carrying client", () => {
    expect(providerMatches(null, "claude")).toBe(true);
    expect(providerMatches(null, "codex")).toBe(true);
  });

  it("the 'any' wildcard task matches any provider-carrying client", () => {
    expect(providerMatches("any", "claude")).toBe(true);
    expect(providerMatches("any", "codex")).toBe(true);
  });

  it("otherwise requires an exact match", () => {
    expect(providerMatches("claude", "claude")).toBe(true);
    expect(providerMatches("claude", "codex")).toBe(false);
  });
});

describe("requiresLedgerApproval", () => {
  it("is true only for the meeting source", () => {
    expect(requiresLedgerApproval("meeting")).toBe(true);
  });

  it("is false for meeting-recording (a different, already-approved pipeline) and everything else", () => {
    expect(requiresLedgerApproval("meeting-recording")).toBe(false);
    expect(requiresLedgerApproval("manual")).toBe(false);
    expect(requiresLedgerApproval("voice")).toBe(false);
  });
});

describe("computeIsBlocked", () => {
  it("is false with no blocker and no reason", () => {
    expect(computeIsBlocked({ blockedByTaskId: null, blockerStage: null, blockedReason: "" })).toBe(false);
  });

  it("is true when the blocker exists and isn't done", () => {
    expect(computeIsBlocked({ blockedByTaskId: "t1", blockerStage: "in_progress", blockedReason: "" })).toBe(true);
  });

  it("is false once the blocker reaches done", () => {
    expect(computeIsBlocked({ blockedByTaskId: "t1", blockerStage: "done", blockedReason: "" })).toBe(false);
  });

  it("is false for a dangling blocker reference (blockerStage null) with no reason", () => {
    expect(computeIsBlocked({ blockedByTaskId: "missing", blockerStage: null, blockedReason: "" })).toBe(false);
  });

  it("is true from a non-empty blockedReason alone, independent of any blocker", () => {
    expect(computeIsBlocked({ blockedByTaskId: null, blockerStage: null, blockedReason: "waiting on design" })).toBe(true);
  });

  it("whitespace-only blockedReason does not block", () => {
    expect(computeIsBlocked({ blockedByTaskId: null, blockerStage: null, blockedReason: "   " })).toBe(false);
  });
});
