import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app.ts";
import { MemoryStore } from "../src/db/memory.ts";
import { sha256Hex } from "../src/auth.ts";

const USER_TOKEN = "user-app-token-0123456789abcdef0123456789";
const WORKER_TOKEN = "claude-worker-token-0123456789abcdef012345";
const WORKER2_TOKEN = "claude-worker-2-token-0123456789abcdef01234";
const BAD_TOKEN = "totally-bogus-token-0123456789abcdef0123456";

async function setup() {
  const store = new MemoryStore();
  store.registerClient({
    tokenHash: await sha256Hex(USER_TOKEN),
    name: "mac-app",
    kind: "user_app",
    provider: null,
  });
  store.registerClient({
    tokenHash: await sha256Hex(WORKER_TOKEN),
    name: "worker-claude-1",
    kind: "worker",
    provider: "claude",
  });
  store.registerClient({
    tokenHash: await sha256Hex(WORKER2_TOKEN),
    name: "worker-claude-2",
    kind: "worker",
    provider: "claude",
  });
  const app = createApp({ store });
  return { store, app };
}

function auth(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}`, "content-type": "application/json" };
}

async function json(res: Response): Promise<any> {
  return res.json();
}

describe("auth", () => {
  it("401s a missing token", async () => {
    const { app } = await setup();
    const res = await app.request("/v1/tasks");
    expect(res.status).toBe(401);
  });

  it("401s a bad token", async () => {
    const { app } = await setup();
    const res = await app.request("/v1/tasks", { headers: auth(BAD_TOKEN) });
    expect(res.status).toBe(401);
  });

  it("health needs no auth", async () => {
    const { app } = await setup();
    const res = await app.request("/v1/health");
    expect(res.status).toBe(200);
    expect(await json(res)).toEqual({ status: "ok" });
  });

  it("403s a worker calling a user-only route (review)", async () => {
    const { app } = await setup();
    const res = await app.request("/v1/tasks/00000000-0000-0000-0000-000000000000/review", {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({ action: "accept" }),
    });
    expect(res.status).toBe(403);
  });
});

describe("create task idempotency", () => {
  it("replays the identical response for a repeated Idempotency-Key", async () => {
    const { app } = await setup();
    const headers = { ...auth(USER_TOKEN), "Idempotency-Key": "create-key-1" };

    const res1 = await app.request("/v1/tasks", {
      method: "POST",
      headers,
      body: JSON.stringify({ title: "Idempotent task" }),
    });
    expect(res1.status).toBe(201);
    const body1 = await json(res1);

    const res2 = await app.request("/v1/tasks", {
      method: "POST",
      headers,
      body: JSON.stringify({ title: "Idempotent task" }),
    });
    expect(res2.status).toBe(201);
    const body2 = await json(res2);

    expect(body2).toEqual(body1);

    const list = await app.request("/v1/tasks?owner=me", { headers: auth(USER_TOKEN) });
    const tasks = await json(list);
    expect(tasks.filter((t: any) => t.title === "Idempotent task")).toHaveLength(1);
  });
});

describe("PATCH optimistic concurrency", () => {
  it("428s a missing If-Match", async () => {
    const { app } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "Needs If-Match" }),
    });
    const task = await json(created);

    const res = await app.request(`/v1/tasks/${task.id}`, {
      method: "PATCH",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "renamed" }),
    });
    expect(res.status).toBe(428);
  });

  it("409s a stale If-Match", async () => {
    const { app } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "Will conflict" }),
    });
    const task = await json(created);
    expect(task.revision).toBe(1);

    const res = await app.request(`/v1/tasks/${task.id}`, {
      method: "PATCH",
      headers: { ...auth(USER_TOKEN), "If-Match": "999" },
      body: JSON.stringify({ title: "renamed" }),
    });
    expect(res.status).toBe(409);
    expect((await json(res)).error).toBe("revision_conflict");
  });

  it("accepts a matching If-Match and bumps the revision", async () => {
    const { app } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "Will update" }),
    });
    const task = await json(created);

    const res = await app.request(`/v1/tasks/${task.id}`, {
      method: "PATCH",
      headers: { ...auth(USER_TOKEN), "If-Match": String(task.revision) },
      body: JSON.stringify({ title: "renamed" }),
    });
    expect(res.status).toBe(200);
    const updated = await json(res);
    expect(updated.title).toBe("renamed");
    expect(updated.revision).toBe(task.revision + 1);
  });
});

describe("claim legality", () => {
  it("rejects a claim whose provider doesn't match the task's selected provider", async () => {
    const { app } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "codex only", owner: "agent", stage: "for_agent", selectedProvider: "codex" }),
    });
    const task = await json(created);

    const res = await app.request(`/v1/tasks/${task.id}/claim`, {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(409);
    expect((await json(res)).error).toBe("not_claimable");
  });

  it("rejects a second claim while the lease is still held", async () => {
    const { app } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "single claim", owner: "agent", stage: "for_agent" }),
    });
    const task = await json(created);

    const first = await app.request(`/v1/tasks/${task.id}/claim`, {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({}),
    });
    expect(first.status).toBe(200);

    const second = await app.request(`/v1/tasks/${task.id}/claim`, {
      method: "POST",
      headers: auth(WORKER2_TOKEN),
      body: JSON.stringify({}),
    });
    expect(second.status).toBe(409);
    expect((await json(second)).error).toBe("already_leased");
  });
});

describe("lease expiry", () => {
  it("frees the task back to queued when the lease's ttl elapses", async () => {
    const { app, store } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "will expire", owner: "agent", stage: "for_agent" }),
    });
    const task = await json(created);

    const claimRes = await app.request(`/v1/tasks/${task.id}/claim`, {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({ ttl_seconds: 1 }),
    });
    expect(claimRes.status).toBe(200);

    const inProgress = await app.request(`/v1/tasks/${task.id}`, { headers: auth(USER_TOKEN) });
    expect((await json(inProgress)).task.stage).toBe("in_progress");

    // Injected `now`, well past the 1-second ttl — the HTTP layer always
    // calls `new Date()`, so lease-expiry timing is exercised directly
    // against the store instance backing this app (same object, no clock
    // mocking needed).
    const future = new Date(Date.now() + 10 * 60 * 1000);
    const events = await store.expireLeases(future);
    expect(events).toHaveLength(1);
    expect(events[0]?.type).toBe("lease_expired");

    const after = await app.request(`/v1/tasks/${task.id}`, { headers: auth(USER_TOKEN) });
    const expanded = await json(after);
    expect(expanded.task.stage).toBe("queued");
    expect(expanded.run.state).toBe("interrupted");
    expect(expanded.lease).toBeNull();
  });
});

describe("full happy loop", () => {
  it("walks create -> delegate -> claim -> needs_input -> reply -> re-claim -> completed -> accept", async () => {
    const { app } = await setup();

    // 1. create plain (inbox / owner=me)
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "Ship the thing", priority: "high" }),
    });
    expect(created.status).toBe(201);
    const task0 = await json(created);
    expect(task0.stage).toBe("inbox");
    expect(task0.owner).toBe("me");

    // delegate via PATCH: stage=for_agent, owner=agent
    const delegated = await app.request(`/v1/tasks/${task0.id}`, {
      method: "PATCH",
      headers: { ...auth(USER_TOKEN), "If-Match": String(task0.revision) },
      body: JSON.stringify({ stage: "for_agent", owner: "agent" }),
    });
    expect(delegated.status).toBe(200);
    const task1 = await json(delegated);
    expect(task1.stage).toBe("for_agent");
    expect(task1.owner).toBe("agent");

    // 2. worker lists claimable
    const claimable = await app.request("/v1/tasks?claimable=true", { headers: auth(WORKER_TOKEN) });
    expect(claimable.status).toBe(200);
    const claimableTasks = await json(claimable);
    expect(claimableTasks.map((t: any) => t.id)).toContain(task1.id);

    // 3. worker claims
    const claimRes = await app.request(`/v1/tasks/${task1.id}/claim`, {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({ ttl_seconds: 900 }),
    });
    expect(claimRes.status).toBe(200);
    const claimBody = await json(claimRes);
    expect(claimBody.task.task.stage).toBe("in_progress");
    expect(claimBody.lease.taskId).toBe(task1.id);

    // 4. progress message
    const progress = await app.request(`/v1/tasks/${task1.id}/messages`, {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({ role: "agent", kind: "progress", content: "working on it" }),
    });
    expect(progress.status).toBe(201);

    // 5. outcome: needs_input
    const needsInput = await app.request(`/v1/tasks/${task1.id}/outcome`, {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({ outcome: "needs_input", message: "need clarification", questions: ["Deadline?"] }),
    });
    expect(needsInput.status).toBe(200);
    const afterNeedsInput = await json(needsInput);
    expect(afterNeedsInput.task.stage).toBe("needs_input");
    expect(afterNeedsInput.lease).toBeNull();
    expect(afterNeedsInput.messages.at(-1).kind).toBe("question");

    // 6. user replies
    const replyRes = await app.request(`/v1/tasks/${task1.id}/reply`, {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ content: "Friday" }),
    });
    expect(replyRes.status).toBe(200);
    const afterReply = await json(replyRes);
    expect(afterReply.task.stage).toBe("queued");

    // 7. worker re-claims
    const reClaim = await app.request(`/v1/tasks/${task1.id}/claim`, {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({}),
    });
    expect(reClaim.status).toBe(200);

    // 8. outcome: completed
    const completed = await app.request(`/v1/tasks/${task1.id}/outcome`, {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({
        outcome: "completed",
        message: "done",
        summary: "Shipped it",
        links: [{ label: "PR", url: "https://example.com/pr/1" }],
      }),
    });
    expect(completed.status).toBe(200);
    const afterCompleted = await json(completed);
    expect(afterCompleted.task.stage).toBe("needs_review");
    expect(afterCompleted.task.links).toEqual([{ label: "PR", url: "https://example.com/pr/1" }]);
    expect(afterCompleted.lease).toBeNull();

    // 9. user review: accept
    const review = await app.request(`/v1/tasks/${task1.id}/review`, {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ action: "accept" }),
    });
    expect(review.status).toBe(200);
    const afterReview = await json(review);
    expect(afterReview.task.stage).toBe("done");

    // events cursor: monotonically increasing seq, ?after= filters
    const allEvents = await app.request("/v1/events?after=0&limit=500", { headers: auth(USER_TOKEN) });
    const events = await json(allEvents);
    expect(events.length).toBeGreaterThan(5);
    const seqs = events.map((e: any) => e.seq);
    expect(seqs).toEqual([...seqs].sort((a, b) => a - b));
    for (let i = 1; i < seqs.length; i++) {
      expect(seqs[i]).toBeGreaterThan(seqs[i - 1]);
    }

    const midSeq = seqs[Math.floor(seqs.length / 2)];
    const filtered = await app.request(`/v1/events?after=${midSeq}`, { headers: auth(USER_TOKEN) });
    const filteredEvents = await json(filtered);
    expect(filteredEvents.every((e: any) => e.seq > midSeq)).toBe(true);
    expect(filteredEvents.length).toBe(seqs.filter((s: number) => s > midSeq).length);
  });
});

describe("me / health", () => {
  it("returns the calling client's identity", async () => {
    const { app } = await setup();
    const res = await app.request("/v1/me", { headers: auth(WORKER_TOKEN) });
    expect(res.status).toBe(200);
    const me = await json(res);
    expect(me.kind).toBe("worker");
    expect(me.provider).toBe("claude");
  });
});

describe("idempotency reserve-then-act", () => {
  it("409s a concurrent request reusing a key that's already reserved and still in flight, and does not execute it", async () => {
    const { app, store } = await setup();
    const client = await store.getClientByTokenHash(await sha256Hex(USER_TOKEN));
    if (!client) throw new Error("setup failed");

    // Simulate a request that already reserved the key and hasn't completed
    // yet (the race window `reserveIdempotent`/`completeIdempotent` close).
    await store.reserveIdempotent(client.id, "in-flight-key", "POST /v1/tasks", new Date());

    const res = await app.request("/v1/tasks", {
      method: "POST",
      headers: { ...auth(USER_TOKEN), "Idempotency-Key": "in-flight-key" },
      body: JSON.stringify({ title: "should not be created" }),
    });
    expect(res.status).toBe(409);
    expect((await json(res)).error).toBe("idempotency_in_flight");

    const list = await app.request("/v1/tasks?owner=me", { headers: auth(USER_TOKEN) });
    const tasks = await json(list);
    expect(tasks.filter((t: any) => t.title === "should not be created")).toHaveLength(0);
  });

  it("still replays the identical response for a completed key (reserve-then-act preserves the old replay behavior)", async () => {
    const { app } = await setup();

    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "outcome idempotency", owner: "agent", stage: "for_agent" }),
    });
    const task = await json(created);
    await app.request(`/v1/tasks/${task.id}/claim`, {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({}),
    });

    const res1 = await app.request(`/v1/tasks/${task.id}/outcome`, {
      method: "POST",
      headers: { ...auth(WORKER_TOKEN), "Idempotency-Key": "outcome-key-1" },
      body: JSON.stringify({ outcome: "completed", message: "done" }),
    });
    expect(res1.status).toBe(200);
    const body1 = await json(res1);

    const res2 = await app.request(`/v1/tasks/${task.id}/outcome`, {
      method: "POST",
      headers: { ...auth(WORKER_TOKEN), "Idempotency-Key": "outcome-key-1" },
      body: JSON.stringify({ outcome: "completed", message: "done" }),
    });
    expect(res2.status).toBe(200);
    const body2 = await json(res2);
    expect(body2).toEqual(body1);
  });
});

describe("PATCH ledger grant/revoke side effect", () => {
  it("grants agentApprovalGranted when a ledger (meeting-sourced) task's stage moves to queued", async () => {
    const { app } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "ledger task", owner: "agent", stage: "needs_approval", source: "meeting" }),
    });
    const task = await json(created);
    expect(task.agentApprovalGranted).toBe(false);

    const patched = await app.request(`/v1/tasks/${task.id}`, {
      method: "PATCH",
      headers: { ...auth(USER_TOKEN), "If-Match": String(task.revision) },
      body: JSON.stringify({ stage: "queued" }),
    });
    expect(patched.status).toBe(200);
    const queued = await json(patched);
    expect(queued.stage).toBe("queued");
    expect(queued.agentApprovalGranted).toBe(true);

    // Dropping it back onto for_agent revokes the grant.
    const revoked = await app.request(`/v1/tasks/${task.id}`, {
      method: "PATCH",
      headers: { ...auth(USER_TOKEN), "If-Match": String(queued.revision) },
      body: JSON.stringify({ stage: "for_agent" }),
    });
    expect(revoked.status).toBe(200);
    expect((await json(revoked)).agentApprovalGranted).toBe(false);
  });

  it("never grants approval for a non-ledger task's stage move", async () => {
    const { app } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "voice task", owner: "agent", stage: "for_agent", source: "voice" }),
    });
    const task = await json(created);

    const patched = await app.request(`/v1/tasks/${task.id}`, {
      method: "PATCH",
      headers: { ...auth(USER_TOKEN), "If-Match": String(task.revision) },
      body: JSON.stringify({ stage: "queued" }),
    });
    expect(patched.status).toBe(200);
    expect((await json(patched)).agentApprovalGranted).toBe(false);
  });

  it("leaves agentApprovalGranted untouched for a PATCH that doesn't touch stage", async () => {
    const { app } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "ledger task", owner: "agent", stage: "needs_approval", source: "meeting" }),
    });
    const task = await json(created);

    const patched = await app.request(`/v1/tasks/${task.id}`, {
      method: "PATCH",
      headers: { ...auth(USER_TOKEN), "If-Match": String(task.revision) },
      body: JSON.stringify({ title: "renamed" }),
    });
    expect(patched.status).toBe(200);
    expect((await json(patched)).agentApprovalGranted).toBe(false);
  });
});

describe("review('approve') endpoint", () => {
  it("approves a needs_approval task to its computed target", async () => {
    const { app } = await setup();
    const created = await app.request("/v1/tasks", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ title: "approve via http", owner: "me", stage: "needs_approval" }),
    });
    const task = await json(created);

    const res = await app.request(`/v1/tasks/${task.id}/review`, {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ action: "approve" }),
    });
    expect(res.status).toBe(200);
    const body = await json(res);
    expect(body.task.stage).toBe("needs_review");
  });

  it("403s a worker calling approve (review stays user_app-only)", async () => {
    const { app } = await setup();
    const res = await app.request("/v1/tasks/00000000-0000-0000-0000-000000000000/review", {
      method: "POST",
      headers: auth(WORKER_TOKEN),
      body: JSON.stringify({ action: "approve" }),
    });
    expect(res.status).toBe(403);
  });

  it("400s an action outside the accept | request_changes | take_back | approve vocabulary", async () => {
    const { app } = await setup();
    const res = await app.request("/v1/tasks/00000000-0000-0000-0000-000000000000/review", {
      method: "POST",
      headers: auth(USER_TOKEN),
      body: JSON.stringify({ action: "bogus" }),
    });
    expect(res.status).toBe(400);
  });
});
