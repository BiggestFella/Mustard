# Mustard task service

The hosted single-user task control plane (ADR-0013). Design:
`docs/specs/2026-08-26-shared-task-service-design.md` — that document is
authoritative; this README covers running and deploying only.

- **Runtime:** Supabase Edge Functions (Deno) serving a Hono app; Postgres via the
  Supabase pooler; storage via Supabase Storage.
- **Source layout:** `src/domain/` is pure, fully unit-tested lifecycle logic (the
  server-side `Logic/`); `src/db/` is the store behind an interface (in-memory fake
  for tests, `pg.ts` for real Postgres); `src/app.ts` + `src/routes/` are thin.
- **Tests:** `npm test` (vitest, no network, no Docker). `npm run typecheck`.

## Deploying (Leon — one-time setup, ~10 minutes)

The agent session cannot create accounts or log in for you. Steps:

1. Create the project: [supabase.com](https://supabase.com) → New project →
   **free tier**, region **Sydney (ap-southeast-2)**, any strong DB password
   (store it in your password manager; the service uses the pooler URL, you rarely
   need it again).
2. In a terminal, from this `server/` directory:

```bash
supabase login
```

```bash
supabase link --project-ref <ref-from-project-url>
```

3. Apply the schema:

```bash
supabase db push
```

   (or `psql "$DB_URL" -f migrations/0001_init.sql -f migrations/0002_idempotency_reserve.sql`
   if you prefer psql — apply every file in `migrations/` in filename order.)
4. Deploy the API:

```bash
supabase functions deploy api --no-verify-jwt
```

   `--no-verify-jwt` is correct: the function does its own bearer auth against
   `clients.token_hash`; Supabase JWTs are not used.
5. Set the function's DB secret (Dashboard → Edge Functions → api → secrets, or):

```bash
supabase secrets set DB_URL="<transaction-pooler-connection-string>"
```

6. Mint the first clients (SQL editor in the dashboard). Generate each token
   locally, e.g. `openssl rand -hex 32`, then insert only its hash:

```sql
insert into clients (id, name, kind, provider, token_hash, enabled)
values
  (gen_random_uuid(), 'mac-app',       'user_app', null,     encode(digest('<token-1>', 'sha256'), 'hex'), true),
  (gen_random_uuid(), 'worker-claude', 'worker',   'claude', encode(digest('<token-2>', 'sha256'), 'hex'), true);
```

   Keep the plaintext tokens in your password manager; the DB never stores them.
7. Smoke test:

```bash
curl -s -H "Authorization: Bearer <token-1>" https://<ref>.supabase.co/functions/v1/api/v1/health
```

Free-tier note: the project pauses after ~1 week of zero activity — unpause is one
click in the dashboard.
