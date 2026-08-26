// Supabase Edge Function entry point (Deno runtime). Wires the shared Hono
// app (../../../src/app.ts, framework-agnostic — it never imports anything
// Supabase- or Deno-specific) to a real Postgres-backed Store (PgStore,
// ../../../src/db/pg.ts) and serves it via `Deno.serve`.
//
// This file is intentionally NOT covered by `npx tsc --noEmit` (server's
// tsconfig.json only includes src/** and test/**, not supabase/**) because
// it uses Deno globals (`Deno.env`, `Deno.serve`) that don't exist under
// Node's type-checker. It has its own runtime (Deno's own type-checking on
// deploy) rather than a local automated check — see server/README.md for
// the deploy steps and the curl smoke test that exercises this file.
//
// Relative .ts imports (with the literal ".ts" extension) resolve fine
// under Deno, unlike Node's ESM resolver, so no build step is needed to
// reach into src/.

import postgres from "postgres";
import { createApp } from "../../../src/app.ts";
import { PgStore } from "../../../src/db/pg.ts";

const dbUrl = Deno.env.get("DB_URL");
if (!dbUrl) {
  throw new Error(
    "DB_URL is not set. Deploy setup: `supabase secrets set DB_URL=\"<transaction-pooler-connection-string>\"` — see server/README.md.",
  );
}

// `prepare: false` is required through Supabase's transaction-mode pooler:
// pgbouncer in transaction-pooling mode hands out a different physical
// connection per transaction, so server-side prepared statements (which are
// scoped to one physical connection) can't survive across queries.
// `max: 2` keeps this Edge Function instance's own connection footprint
// small — Supabase can run many instances of the same function concurrently,
// each with its own pool, and the free-tier Postgres has a modest total
// connection ceiling.
const sql = postgres(dbUrl, { prepare: false, max: 2 });

const store = new PgStore(sql);
const app = createApp({ store });

// Path-prefix handling: Supabase mounts every Edge Function at
// `/functions/v1/<function-name>/...` (here, function name "api" per
// supabase/config.toml), but createApp()'s routes are registered directly
// as `/v1/...` (see src/app.ts) with no knowledge of that mount point —
// deliberately, since src/app.ts is also exercised directly in tests
// against an in-memory store with no Supabase involved. Rather than teach
// src/app.ts about a Supabase-specific mount path, strip the mount prefix
// off the incoming request's URL here, at the one place that's actually
// Supabase-specific, before handing it to the app's `fetch` handler.
const MOUNT_PREFIX = "/functions/v1/api";

function stripMountPrefix(request: Request): Request {
  const url = new URL(request.url);
  if (url.pathname.startsWith(MOUNT_PREFIX)) {
    url.pathname = url.pathname.slice(MOUNT_PREFIX.length) || "/";
  }
  return new Request(url, request);
}

Deno.serve((request) => app.fetch(stripMountPrefix(request)));
