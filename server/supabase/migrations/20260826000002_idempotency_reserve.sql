-- Idempotency reserve-then-act (ADR-0013 fix pass, slice 2 review). The
-- original `idempotency_keys` table only had `status`/`response`, written
-- once at the end of a request — that's a check-then-act race: two
-- concurrent requests carrying the same Idempotency-Key could both find
-- nothing cached and both execute the underlying operation. `state` lets a
-- request atomically reserve the key (`insert ... on conflict do nothing`)
-- before doing any work, so a racing second request sees `pending` and
-- returns 409 `idempotency_in_flight` instead of re-executing.
--
-- Not yet applied anywhere (README.md's deploy steps are still "Leon —
-- one-time setup"), so this is a plain additive migration rather than a
-- backfill-and-swap.

alter table idempotency_keys
    add column state text not null default 'pending';

alter table idempotency_keys
    add constraint idempotency_keys_state_check check (state in ('pending', 'complete'));

alter table idempotency_keys
    alter column state drop default;
