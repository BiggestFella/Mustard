import { describe, expect, it } from "vitest";
import { MemoryStore } from "../src/db/memory.ts";
import type { AgentRunRow, ClientRow, TaskRow } from "../src/db/store.ts";
import {
  EVENT_APPROVED,
  EVENT_TASK_CREATED,
} from "../src/domain/events.ts";

const NOW = new Date("2026-08-26T12:00:00.000Z");

function minutesLater(base: Date, minutes: number): Date {
  return new Date(base.getTime() + minutes * 60_000);
}

async function makeStore() {
  const store = new MemoryStore();
  const worker: ClientRow = store.registerClient({
    tokenHash: "worker-hash",
    name: "worker-claude",
    kind: "worker",
    provider: "claude",
  });
  return { store, worker };
}

/**
 * Test-only seam: this slice's Store surface has no route that GRANTS
 * ledger approval (`agentApprovalGranted`) — only `PersonalBoard.move` does,
 * client-side, on a board drag to `queued` (see transitions.ts's
 * `agentApprovalGrantForMove`, which isn't wired to any Store method here).
 * `review()`'s `take_back` path can only *revoke* it. To exercise that
 * revoke path we need a ledger task that starts out granted, so this reaches
 * past the public Store surface directly rather than inventing an API route
 * this slice doesn't otherwise need.
 */
function forceGrantApproval(store: MemoryStore, taskId: string): void {
  (store as unknown as { tasks: Map<string, TaskRow> }).tasks.get(taskId)!.agentApprovalGranted = true;
}

/** Test-only seam: reaches past the public Store surface to set an actionType (no route sets it in this slice) or to corrupt run fields so a reset can be observed. */
function setActionType(store: MemoryStore, taskId: string, actionType: string): void {
  (store as unknown as { tasks: Map<string, TaskRow> }).tasks.get(taskId)!.actionType = actionType;
}

function corruptRunForResetTest(store: MemoryStore, taskId: string): void {
  const internals = store as unknown as { runByTask: Map<string, string>; runs: Map<string, AgentRunRow> };
  const runId = internals.runByTask.get(taskId)!;
  const run = internals.runs.get(runId)!;
  run.requiresConnectedWorker = true;
  run.completedAt = "2026-08-26T00:00:00.000Z";
  run.lastError = "stale error from a prior failed attempt";
  run.nextAttemptAt = "2026-08-26T13:00:00.000Z";
  run.autoRetryCount = 2;
}

describe("revision bumps", () => {
  it("increments task.revision exactly once per mutation", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "t", owner: "agent", stage: "for_agent" }, "actor", NOW);
    expect(created.ok).toBe(true);
    if (!created.ok) return;
    expect(created.value.revision).toBe(1);

    const updated = await store.updateTask(created.value.id, { title: "t2" }, 1, "actor", NOW);
    expect(updated.ok).toBe(true);
    if (!updated.ok) return;
    expect(updated.value.revision).toBe(2);

    const provided = await store.setProvider(created.value.id, "claude", "actor", NOW);
    expect(provided.ok).toBe(true);
    if (!provided.ok) return;
    expect(provided.value.revision).toBe(3);

    const claimed = await store.claimTask(created.value.id, worker, 900, NOW);
    expect(claimed.ok).toBe(true);
    if (!claimed.ok) return;
    expect(claimed.value.task.task.revision).toBe(4);

    const outcome = await store.applyOutcome(
      created.value.id,
      worker,
      { outcome: "completed", message: "done" },
      minutesLater(NOW, 1),
    );
    expect(outcome.ok).toBe(true);
    if (!outcome.ok) return;
    expect(outcome.value.task.revision).toBe(5);
  });
});

describe("resume_count", () => {
  it("increments on a re-claim once the run carries a provider session id", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "resumable", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const firstClaim = await store.claimTask(taskId, worker, 900, NOW);
    if (!firstClaim.ok) throw new Error("claim failed");
    expect(firstClaim.value.task.run?.attemptCount).toBe(1);
    expect(firstClaim.value.task.run?.resumeCount).toBe(0);
    expect(firstClaim.value.task.run?.providerSessionId).toBeNull();

    const outcome = await store.applyOutcome(
      taskId,
      worker,
      { outcome: "needs_input", message: "need info", questions: ["what?"], providerSessionId: "sess-abc" },
      minutesLater(NOW, 1),
    );
    if (!outcome.ok) throw new Error("outcome failed");
    expect(outcome.value.run?.providerSessionId).toBe("sess-abc");
    expect(outcome.value.task.stage).toBe("needs_input");
    expect(outcome.value.lease).toBeNull();

    const reply = await store.reply(taskId, "here's the info", "leon", minutesLater(NOW, 2));
    if (!reply.ok) throw new Error("reply failed");
    expect(reply.value.task.stage).toBe("queued");

    const secondClaim = await store.claimTask(taskId, worker, 900, minutesLater(NOW, 3));
    if (!secondClaim.ok) throw new Error("re-claim failed");
    expect(secondClaim.value.task.run?.attemptCount).toBe(2);
    expect(secondClaim.value.task.run?.resumeCount).toBe(1);
    expect(secondClaim.value.task.run?.providerSessionId).toBe("sess-abc");
  });
});

describe("links merge on completed outcome", () => {
  it("unions task.links with the outcome's links, new entries winning on url collision", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask(
      {
        title: "merges links",
        owner: "agent",
        stage: "for_agent",
        links: [{ label: "A", url: "https://example.com/a" }],
      },
      "actor",
      NOW,
    );
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const claim = await store.claimTask(taskId, worker, 900, NOW);
    if (!claim.ok) throw new Error("claim failed");

    const outcome = await store.applyOutcome(
      taskId,
      worker,
      {
        outcome: "completed",
        message: "done",
        summary: "shipped",
        links: [
          { label: "A-updated", url: "https://example.com/a" },
          { label: "B", url: "https://example.com/b" },
        ],
      },
      minutesLater(NOW, 1),
    );
    if (!outcome.ok) throw new Error("outcome failed");

    expect(outcome.value.task.links).toEqual([
      { label: "A-updated", url: "https://example.com/a" },
      { label: "B", url: "https://example.com/b" },
    ]);
    expect(outcome.value.task.stage).toBe("needs_review");
  });
});

describe("take_back revokes ledger approval", () => {
  it("clears agentApprovalGranted for a meeting-sourced task on take_back", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask(
      { title: "ledger task", owner: "agent", stage: "queued", source: "meeting" },
      "actor",
      NOW,
    );
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;
    forceGrantApproval(store, taskId);

    const claim = await store.claimTask(taskId, worker, 900, NOW);
    if (!claim.ok) throw new Error("claim failed");
    expect(claim.value.task.task.stage).toBe("in_progress");

    const takeBack = await store.review(taskId, "take_back", undefined, "leon", minutesLater(NOW, 1));
    expect(takeBack.ok).toBe(true);
    if (!takeBack.ok) return;
    expect(takeBack.value.task.stage).toBe("planned");
    expect(takeBack.value.task.owner).toBe("me");
    expect(takeBack.value.task.agentApprovalGranted).toBe(false);
    // take_back must also free a lease that was still held (in_progress).
    expect(takeBack.value.lease).toBeNull();
  });

  it("leaves agentApprovalGranted untouched for a non-ledger task on take_back", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask(
      { title: "voice task", owner: "agent", stage: "for_agent", source: "voice" },
      "actor",
      NOW,
    );
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const takeBack = await store.review(taskId, "take_back", undefined, "leon", NOW);
    expect(takeBack.ok).toBe(true);
    if (!takeBack.ok) return;
    expect(takeBack.value.task.agentApprovalGranted).toBe(false);
    void worker;
  });
});

describe("expired-lease sweep", () => {
  it("emits one lease_expired event per expired lease and routes the task to queued/interrupted", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "will expire", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const claim = await store.claimTask(taskId, worker, 60, NOW);
    if (!claim.ok) throw new Error("claim failed");
    expect(claim.value.task.task.stage).toBe("in_progress");

    const future = minutesLater(NOW, 10);
    const events = await store.expireLeases(future);
    expect(events).toHaveLength(1);
    expect(events[0]?.type).toBe("lease_expired");
    expect(events[0]?.taskId).toBe(taskId);
    expect(events[0]?.actor).toBeNull();

    const after = await store.getTask(taskId);
    expect(after.ok).toBe(true);
    if (!after.ok) return;
    expect(after.value.task.stage).toBe("queued");
    expect(after.value.run?.state).toBe("interrupted");
    expect(after.value.lease).toBeNull();

    // A second sweep at the same (or later) time is a no-op — the lease is
    // already released, so it must not be reported or re-routed again.
    const secondSweep = await store.expireLeases(minutesLater(future, 1));
    expect(secondSweep).toHaveLength(0);
  });

  it("routes a gated action's expired lease to needs_review with the run failed, not queued/interrupted", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "gated", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;
    setActionType(store, taskId, "draft_email");

    const claim = await store.claimTask(taskId, worker, 60, NOW);
    if (!claim.ok) throw new Error("claim failed");

    const future = minutesLater(NOW, 10);
    const events = await store.expireLeases(future);
    expect(events).toHaveLength(1);

    const after = await store.getTask(taskId);
    expect(after.ok).toBe(true);
    if (!after.ok) return;
    expect(after.value.task.stage).toBe("needs_review");
    expect(after.value.run?.state).toBe("failed");
    expect(after.value.run?.completedAt).not.toBeNull();
  });

  it("still routes an ungated action's expired lease to queued/interrupted", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "ungated", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;
    setActionType(store, taskId, "vault_note");

    const claim = await store.claimTask(taskId, worker, 60, NOW);
    if (!claim.ok) throw new Error("claim failed");

    const events = await store.expireLeases(minutesLater(NOW, 10));
    expect(events).toHaveLength(1);

    const after = await store.getTask(taskId);
    expect(after.ok).toBe(true);
    if (!after.ok) return;
    expect(after.value.task.stage).toBe("queued");
    expect(after.value.run?.state).toBe("interrupted");
  });
});

describe("expired-lease rejection on appendMessage/applyOutcome", () => {
  it("appendMessage rejects with lease_expired once the lease's ttl has elapsed but before any sweep", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "will expire", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const claim = await store.claimTask(taskId, worker, 60, NOW);
    if (!claim.ok) throw new Error("claim failed");

    const future = minutesLater(NOW, 10); // well past the 60s ttl; no sweep has run yet
    const result = await store.appendMessage(taskId, worker, { role: "agent", kind: "progress", content: "hi" }, future);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error).toBe("lease_expired");
  });

  it("applyOutcome rejects with lease_expired once the lease's ttl has elapsed but before any sweep", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "will expire", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const claim = await store.claimTask(taskId, worker, 60, NOW);
    if (!claim.ok) throw new Error("claim failed");

    const future = minutesLater(NOW, 10);
    const result = await store.applyOutcome(taskId, worker, { outcome: "completed", message: "done" }, future);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error).toBe("lease_expired");
  });
});

describe("fresh-attempt run reset (reply / request_changes)", () => {
  it("reply() clears stale backoff/retry/error state on the run alongside the state transition", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "t", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const claim = await store.claimTask(taskId, worker, 900, NOW);
    if (!claim.ok) throw new Error("claim failed");
    const outcome = await store.applyOutcome(
      taskId,
      worker,
      { outcome: "needs_input", message: "need info", questions: ["what?"] },
      minutesLater(NOW, 1),
    );
    if (!outcome.ok) throw new Error("outcome failed");

    corruptRunForResetTest(store, taskId);

    const reply = await store.reply(taskId, "here's the info", "leon", minutesLater(NOW, 2));
    expect(reply.ok).toBe(true);
    if (!reply.ok) return;
    expect(reply.value.task.stage).toBe("queued");
    expect(reply.value.run?.state).toBe("queued");
    expect(reply.value.run?.requiresConnectedWorker).toBe(false);
    expect(reply.value.run?.completedAt).toBeNull();
    expect(reply.value.run?.lastError).toBeNull();
    expect(reply.value.run?.nextAttemptAt).toBeNull();
    expect(reply.value.run?.autoRetryCount).toBe(0);
  });

  it("review('request_changes') clears stale backoff/retry/error state on the run alongside the state transition", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "t", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const claim = await store.claimTask(taskId, worker, 900, NOW);
    if (!claim.ok) throw new Error("claim failed");
    const outcome = await store.applyOutcome(
      taskId,
      worker,
      { outcome: "completed", message: "done", summary: "shipped" },
      minutesLater(NOW, 1),
    );
    if (!outcome.ok) throw new Error("outcome failed");

    corruptRunForResetTest(store, taskId);

    const result = await store.review(taskId, "request_changes", "please redo this", "leon", minutesLater(NOW, 2));
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.task.stage).toBe("queued");
    expect(result.value.run?.state).toBe("queued");
    expect(result.value.run?.requiresConnectedWorker).toBe(false);
    expect(result.value.run?.completedAt).toBeNull();
    expect(result.value.run?.lastError).toBeNull();
    expect(result.value.run?.nextAttemptAt).toBeNull();
    expect(result.value.run?.autoRetryCount).toBe(0);
  });

  it("take_back does NOT apply the fresh-attempt reset (only reply/request_changes do)", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "t", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const claim = await store.claimTask(taskId, worker, 900, NOW);
    if (!claim.ok) throw new Error("claim failed");

    corruptRunForResetTest(store, taskId);

    const result = await store.review(taskId, "take_back", undefined, "leon", minutesLater(NOW, 1));
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    // take_back's ReviewResult carries no run-state-reset semantics beyond
    // `run.state = "cancelled"` (see transitions.ts's reviewAction) — the
    // corrupted fields from before the call are untouched.
    expect(result.value.run?.state).toBe("cancelled");
    expect(result.value.run?.requiresConnectedWorker).toBe(true);
  });
});

describe("review('approve') targets", () => {
  it("existence triage (ledger task, owner me) lands on planned without granting execution", async () => {
    const { store } = await makeStore();
    const created = await store.createTask(
      { title: "ledger existence", owner: "me", stage: "needs_approval", source: "meeting" },
      "actor",
      NOW,
    );
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const result = await store.review(taskId, "approve", undefined, "leon", NOW);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.task.stage).toBe("planned");
    expect(result.value.task.agentApprovalGranted).toBe(false);
  });

  it("approving a gated action into queued grants the ledger approval, mirroring PersonalBoard.move", async () => {
    const { store } = await makeStore();
    const created = await store.createTask(
      { title: "gated ledger", owner: "agent", stage: "needs_approval", source: "meeting" },
      "actor",
      NOW,
    );
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;
    setActionType(store, taskId, "draft_email");

    const result = await store.review(taskId, "approve", undefined, "leon", NOW);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.task.stage).toBe("queued");
    expect(result.value.task.agentApprovalGranted).toBe(true);
  });

  it("a personal (owner me), non-gated action approves straight to needs_review", async () => {
    const { store } = await makeStore();
    const created = await store.createTask(
      { title: "plain approval", owner: "me", stage: "needs_approval" },
      "actor",
      NOW,
    );
    if (!created.ok) throw new Error("setup failed");
    const result = await store.review(created.value.id, "approve", undefined, "leon", NOW);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.task.stage).toBe("needs_review");
  });

  it("approving from needs_review marks the task done and stamps completedAt", async () => {
    const { store, worker } = await makeStore();
    const created = await store.createTask({ title: "t", owner: "agent", stage: "for_agent" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;
    const claim = await store.claimTask(taskId, worker, 900, NOW);
    if (!claim.ok) throw new Error("claim failed");
    const outcome = await store.applyOutcome(taskId, worker, { outcome: "completed", message: "done" }, minutesLater(NOW, 1));
    if (!outcome.ok) throw new Error("outcome failed");

    const result = await store.review(taskId, "approve", undefined, "leon", minutesLater(NOW, 2));
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.task.stage).toBe("done");
    expect(result.value.task.completedAt).not.toBeNull();
  });

  it("rejects approve from a non-gate stage", async () => {
    const { store } = await makeStore();
    const created = await store.createTask({ title: "t", owner: "me", stage: "planned" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");
    const result = await store.review(created.value.id, "approve", undefined, "leon", NOW);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error).toBe("illegal_transition");
  });
});

describe("event vocabulary", () => {
  it("createTask emits the EVENT_TASK_CREATED constant with a {title, stage} payload", async () => {
    const { store } = await makeStore();
    const created = await store.createTask({ title: "vocab check", owner: "me" }, "actor", NOW);
    if (!created.ok) throw new Error("setup failed");

    const events = await store.listEvents(0, 10);
    const ev = events.find((e) => e.taskId === created.value.id);
    expect(ev?.type).toBe(EVENT_TASK_CREATED);
    expect(ev?.payload).toEqual({ title: "vocab check", stage: "inbox" });
  });

  it("review('approve') emits the EVENT_APPROVED constant with a {fromStage, toStage} payload", async () => {
    const { store } = await makeStore();
    const created = await store.createTask(
      { title: "approve vocab", owner: "me", stage: "needs_approval" },
      "actor",
      NOW,
    );
    if (!created.ok) throw new Error("setup failed");
    const taskId = created.value.id;

    const result = await store.review(taskId, "approve", undefined, "leon", minutesLater(NOW, 1));
    expect(result.ok).toBe(true);

    const events = await store.listEvents(0, 10);
    const ev = events.find((e) => e.type === EVENT_APPROVED);
    expect(ev).toBeDefined();
    expect(ev?.payload).toEqual({ fromStage: "needs_approval", toStage: "needs_review" });
  });
});
