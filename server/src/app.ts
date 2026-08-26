// HTTP surface for the hosted task control plane (ADR-0013). Routes are
// deliberately thin: auth -> permission check -> Store call -> status/JSON
// mapping. All lifecycle legality lives in src/domain/*, enforced inside the
// Store implementation (src/db/*.ts) — this file never reimplements it.
//
// Wire-format note (route-spec ambiguity, resolved here): the design doc's
// route table spells out exact snake_case names for query params and
// headers (`updated_after`, `ttl_seconds`, `Idempotency-Key`, `If-Match`),
// which this file honours literally. It does NOT pin down JSON request/
// response body key casing anywhere — that's explicitly deferred to "an
// implementation-slice deliverable (OpenAPI document, from which the Swift
// client is generated)". Rather than invent and maintain a snake_case <->
// camelCase body conversion layer with no concrete spec driving its shape,
// this slice keeps JSON bodies camelCase, matching the Store/domain
// TypeScript types directly. Revisit once the OpenAPI doc lands.

import { Hono } from "hono";
import { bearerToken, isAllowed, sha256Hex } from "./auth.ts";
import type {
  ClientRow,
  CreateTaskInput,
  MessageInput,
  OutcomeInput,
  Store,
  StoreError,
  TaskFilter,
  TaskPatch,
} from "./db/store.ts";
import type { Provider, TaskOwner, TaskStage } from "./domain/stages.ts";
import type { ReviewActionKind } from "./domain/transitions.ts";

type Variables = { client: ClientRow };

const STATUS_BY_ERROR: Record<StoreError, number> = {
  not_found: 404,
  revision_conflict: 409,
  already_leased: 409,
  not_claimable: 409,
  lease_required: 409,
  lease_expired: 409,
  illegal_transition: 422,
};

function errorBody(error: string, detail?: string): { error: string; detail?: string } {
  return detail !== undefined ? { error, detail } : { error };
}

interface RouteResponse {
  body: unknown;
  status: number;
}

/**
 * Reserve-then-act idempotency wrapper for the two routes that accept an
 * `Idempotency-Key` (item G of the fix pass). The old flow was
 * check-then-act (`getIdempotent` -> maybe execute -> `putIdempotent`),
 * which left a race: two concurrent requests carrying the same key could
 * both see nothing cached and both execute `run`. `Store.reserveIdempotent`
 * atomically claims the key first; only the request that wins the
 * reservation calls `run`, and its result — success OR failure — is what
 * every replay (including the losing concurrent request, once it retries)
 * gets back.
 */
async function withIdempotency(
  store: Store,
  client: ClientRow,
  key: string | undefined,
  route: string,
  now: Date,
  run: () => Promise<RouteResponse>,
): Promise<RouteResponse> {
  if (!key) return run();

  const reservation = await store.reserveIdempotent(client.id, key, route, now);
  if (reservation.status === "complete") {
    return { body: reservation.response.response, status: reservation.response.status };
  }
  if (reservation.status === "in_flight") {
    return { body: errorBody("idempotency_in_flight"), status: 409 };
  }

  const result = await run();
  await store.completeIdempotent(client.id, key, route, result.status, result.body);
  return result;
}

export function createApp(deps: { store: Store }) {
  const { store } = deps;
  const app = new Hono<{ Variables: Variables }>();

  function storeError(result: { ok: false; error: StoreError; detail?: string }): [{ error: string; detail?: string }, number] {
    return [errorBody(result.error, result.detail), STATUS_BY_ERROR[result.error]];
  }

  // Unauthenticated — registered before the `/v1/*` auth middleware below so
  // it never enters that chain. Hono composes matched handlers in
  // registration order; this terminal handler runs and returns a response
  // before `next()` would ever reach the middleware registered after it.
  app.get("/v1/health", (c) => c.json({ status: "ok" }));

  app.use("/v1/*", async (c, next) => {
    const token = bearerToken(c.req.header("Authorization"));
    if (!token) return c.json(errorBody("unauthorized"), 401);
    const tokenHash = await sha256Hex(token);
    const client = await store.getClientByTokenHash(tokenHash);
    if (!client || !client.enabled) return c.json(errorBody("unauthorized"), 401);
    await store.touchClientSeen(client.id, new Date());
    c.set("client", client);
    await next();
  });

  function requirePermission(client: ClientRow, permission: string): boolean {
    return isAllowed(client.kind, permission);
  }

  app.post("/v1/tasks", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "tasks.create")) return c.json(errorBody("forbidden"), 403);

    const idempotencyKey = c.req.header("Idempotency-Key");
    const route = "POST /v1/tasks";
    const now = new Date();

    const { body, status } = await withIdempotency(store, client, idempotencyKey, route, now, async () => {
      const reqBody = await c.req.json().catch(() => ({}));
      if (typeof reqBody.title !== "string" || reqBody.title.length === 0) {
        return { body: errorBody("invalid_request", "title is required"), status: 400 };
      }
      const input: CreateTaskInput = reqBody;
      const result = await store.createTask(input, client.id, now);
      if (!result.ok) {
        const [errBody, errStatus] = storeError(result);
        return { body: errBody, status: errStatus };
      }
      return { body: result.value, status: 201 };
    });

    return c.json(body as never, status as never);
  });

  app.get("/v1/tasks", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "tasks.list")) return c.json(errorBody("forbidden"), 403);

    const stageQ = c.req.query("stage");
    const ownerQ = c.req.query("owner");
    const providerQ = c.req.query("provider");
    const updatedAfterQ = c.req.query("updated_after");
    const limitQ = c.req.query("limit");
    const claimableQ = c.req.query("claimable");

    const filter: TaskFilter = {};
    if (stageQ) filter.stage = stageQ as TaskStage;
    if (ownerQ) filter.owner = ownerQ as TaskOwner;
    if (providerQ) filter.provider = providerQ as Provider;
    if (updatedAfterQ) filter.updatedAfter = updatedAfterQ;
    if (limitQ) filter.limit = Number(limitQ);

    if (claimableQ === "true") {
      if (!client.provider) return c.json([]);
      filter.claimableBy = client.provider;
    }

    const tasks = await store.listTasks(filter, new Date());
    return c.json(tasks);
  });

  app.get("/v1/tasks/:id", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "tasks.get")) return c.json(errorBody("forbidden"), 403);
    // NB: the design doc's route table mentions `?expand=context,run,...`,
    // but Store.getTask (the contract this route is not allowed to modify)
    // has no partial-expansion parameter — it always returns the full
    // ExpandedTask. This route mirrors that: `?expand=` is accepted but
    // ignored in this slice.
    const result = await store.getTask(c.req.param("id"));
    if (!result.ok) {
      const [body, status] = storeError(result);
      return c.json(body, status as never);
    }
    return c.json(result.value);
  });

  app.patch("/v1/tasks/:id", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "tasks.update")) return c.json(errorBody("forbidden"), 403);

    const ifMatch = c.req.header("If-Match");
    if (ifMatch === undefined) {
      return c.json(errorBody("precondition_required", "If-Match header is required"), 428);
    }
    const ifRevision = Number(ifMatch);
    if (!Number.isFinite(ifRevision)) {
      return c.json(errorBody("invalid_request", "If-Match must be an integer revision"), 400);
    }

    const patch: TaskPatch = await c.req.json().catch(() => ({}));
    const result = await store.updateTask(c.req.param("id"), patch, ifRevision, client.id, new Date());
    if (!result.ok) {
      const [body, status] = storeError(result);
      return c.json(body, status as never);
    }
    return c.json(result.value);
  });

  app.post("/v1/tasks/:id/provider", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "tasks.set_provider")) return c.json(errorBody("forbidden"), 403);

    const body = await c.req.json().catch(() => ({}));
    const provider = (body.provider ?? null) as Provider | null;
    const result = await store.setProvider(c.req.param("id"), provider, client.id, new Date());
    if (!result.ok) {
      const [body2, status] = storeError(result);
      return c.json(body2, status as never);
    }
    return c.json(result.value);
  });

  app.post("/v1/tasks/:id/claim", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "tasks.claim")) return c.json(errorBody("forbidden"), 403);

    const body = await c.req.json().catch(() => ({}));
    const ttlSeconds = typeof body.ttl_seconds === "number" ? body.ttl_seconds : 900;
    const result = await store.claimTask(c.req.param("id"), client, ttlSeconds, new Date());
    if (!result.ok) {
      const [body2, status] = storeError(result);
      return c.json(body2, status as never);
    }
    return c.json(result.value);
  });

  app.post("/v1/leases/:id/renew", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "leases.renew")) return c.json(errorBody("forbidden"), 403);

    const body = await c.req.json().catch(() => ({}));
    const ttlSeconds = typeof body.ttl_seconds === "number" ? body.ttl_seconds : 900;
    const result = await store.renewLease(c.req.param("id"), client.id, ttlSeconds, new Date());
    if (!result.ok) {
      const [body2, status] = storeError(result);
      return c.json(body2, status as never);
    }
    return c.json(result.value);
  });

  app.post("/v1/leases/:id/release", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "leases.release")) return c.json(errorBody("forbidden"), 403);

    const result = await store.releaseLease(c.req.param("id"), client.id, new Date());
    if (!result.ok) {
      const [body, status] = storeError(result);
      return c.json(body, status as never);
    }
    return c.body(null, 204);
  });

  app.post("/v1/tasks/:id/messages", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "messages.append")) return c.json(errorBody("forbidden"), 403);

    const input: MessageInput = await c.req.json().catch(() => ({}));
    const result = await store.appendMessage(c.req.param("id"), client, input, new Date());
    if (!result.ok) {
      const [body, status] = storeError(result);
      return c.json(body, status as never);
    }
    return c.json(result.value, 201);
  });

  app.post("/v1/tasks/:id/outcome", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "outcome.report")) return c.json(errorBody("forbidden"), 403);

    const idempotencyKey = c.req.header("Idempotency-Key");
    const route = "POST /v1/tasks/:id/outcome";
    const now = new Date();

    const { body, status } = await withIdempotency(store, client, idempotencyKey, route, now, async () => {
      const input: OutcomeInput = await c.req.json().catch(() => ({}));
      const result = await store.applyOutcome(c.req.param("id"), client, input, now);
      if (!result.ok) {
        const [errBody, errStatus] = storeError(result);
        return { body: errBody, status: errStatus };
      }
      return { body: result.value, status: 200 };
    });

    return c.json(body as never, status as never);
  });

  app.post("/v1/tasks/:id/reply", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "tasks.reply")) return c.json(errorBody("forbidden"), 403);

    const body = await c.req.json().catch(() => ({}));
    if (typeof body.content !== "string" || body.content.trim().length === 0) {
      return c.json(errorBody("invalid_request", "content is required"), 400);
    }
    const result = await store.reply(c.req.param("id"), body.content, client.id, new Date());
    if (!result.ok) {
      const [body2, status] = storeError(result);
      return c.json(body2, status as never);
    }
    return c.json(result.value);
  });

  app.post("/v1/tasks/:id/review", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "tasks.review")) return c.json(errorBody("forbidden"), 403);

    const body = await c.req.json().catch(() => ({}));
    const action = body.action as ReviewActionKind;
    if (action !== "accept" && action !== "request_changes" && action !== "take_back" && action !== "approve") {
      return c.json(errorBody("invalid_request", "action must be accept | request_changes | take_back | approve"), 400);
    }
    const feedback: string | undefined = typeof body.feedback === "string" ? body.feedback : undefined;
    const result = await store.review(c.req.param("id"), action, feedback, client.id, new Date());
    if (!result.ok) {
      const [body2, status] = storeError(result);
      return c.json(body2, status as never);
    }
    return c.json(result.value);
  });

  // Artifacts (POST /v1/artifacts, GET /v1/artifacts/:id/download): SKIPPED
  // in this slice per the task brief — storage presigning arrives with the
  // deploy slice. store.createArtifact/getArtifact are fully implemented
  // and exercised directly in test/memory-store.test.ts; only the HTTP
  // surface is deferred. TODO(deploy slice): wire these two routes once an
  // object-storage adapter exists to presign against.

  app.get("/v1/events", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "events.list")) return c.json(errorBody("forbidden"), 403);

    const afterRaw = Number(c.req.query("after") ?? "0");
    const after = Number.isFinite(afterRaw) ? afterRaw : 0;
    const limitRaw = Number(c.req.query("limit") ?? "100");
    const limit = Math.min(Math.max(Number.isFinite(limitRaw) ? limitRaw : 100, 1), 500);

    const events = await store.listEvents(after, limit);
    return c.json(events);
  });

  app.get("/v1/me", async (c) => {
    const client = c.get("client");
    if (!requirePermission(client, "me")) return c.json(errorBody("forbidden"), 403);
    return c.json(client);
  });

  return app;
}
