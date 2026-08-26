import { describe, expect, it } from "vitest";
import { MemoryStore } from "../src/db/memory.ts";
import type { ClientRow, TaskRow } from "../src/db/store.ts";

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
});
