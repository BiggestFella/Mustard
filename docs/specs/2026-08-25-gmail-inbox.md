# Gmail inbox — Mustard-owned Gmail API integration (spec)

**Date:** 2026-08-25 · **Status:** Approved (Leon's handoff, 2026-08-25 chat) · **ADR:** 0012 (supersedes 0008 for email discovery)

## What

Replace the external "inbox routine sweep" (the local scout of ADR-0008) with an
in-app Gmail inbox: Mustard polls Gmail directly over the Gmail API, triages new
mail into Recommendations through the existing normalize → dedupe → insert
pipeline, and supports acting on the underlying email — archive, and reply/send —
from the recommendation card. Single user (Leon), personal use, $0 running cost.

This is exactly the fallback ADR-0007 named: *"(A) Mustard-owned Gmail OAuth —
Mac-anchored"*, on the shared `SourceProposal`/dedupe/provenance foundation.

## Decisions from the handoff (not re-litigated)

- **Auth:** Gmail API directly via OAuth 2.0 with Leon's own Google login. No
  service account, no third-party wrapper (Nylas/Zapier).
- **Sync:** scheduled polling. No Pub/Sub, no webhook endpoint, no watch renewal.
  Minutes of latency is fine.
- **Scopes:** `gmail.readonly` + `gmail.modify` (archive = remove `INBOX` label,
  never delete) + `gmail.send` (reply in-thread via `messages.send` + `threadId`).
  Single-user → no Google verification review; "unverified app" consent screen is
  expected and fine.
- **Tokens:** refresh token stored securely, never in the repo; silent
  refresh-on-demand before each poll.

## Open items from the handoff — resolved

| Open item | Resolution |
|---|---|
| Which label to poll | Configurable in Settings → Gmail via a label picker fed by `labels.list`. Default `INBOX`, plus a Gmail query (default `newer_than:3d`) to bound the window. No hardcoded label. |
| Where the routine expects input | `AgentService`'s shared proposal pipeline. The poll produces `[SourceProposal]` (same contract as the scout's `_recs/*.json`) and hands them to a new `AgentService.ingestExternal` → existing `IngestNormalizer` → `SourceDedupe` → `Recommendation` insert → `applyTrust`. `InboxIngest`/`_recs/` stays as a legacy path; nothing breaks if the scout still runs (message-id dedupe makes the two sources idempotent against each other). |
| Polling interval | Default 5 minutes, adjustable 1–60 in Settings. The 60s scheduler tick checks `GmailSettings.isDue`. |
| Refresh-token storage | `KeychainTokenStore(service: "com.mustard.gmail")` — the existing Keychain store class, separate service from Calendar. Client id/secret typed into Settings (same pattern as Google Calendar), never committed. |
| Review-before-send | **Always.** Approve keeps its existing meaning (stage a draft). Sending is a separate, explicit **"Send reply via Gmail"** button on the gmail-sourced `draft_email` card, behind a confirmation dialog, using the (editable) draft. Archive is likewise an explicit **"Archive in Gmail"** button. Nothing outward happens from trust/auto-approve — `RecommendationAction.isGated` is untouched. |

## Architecture (reuse-first)

- **OAuth:** the existing Calendar stack, verbatim — `PKCE`, `GoogleAuthSession`
  (loopback + system browser), `GoogleTokenClient` (exchange/refresh, refresh-token
  carry-forward), `LoopbackRedirectServer`. One change: `GoogleOAuth.authorizationURL`
  gains a `scope:` parameter (Calendar keeps its default).
- **HTTP:** the one `HTTPTransport` seam; a new `GmailClient` mirrors
  `GoogleEventsClient` (pure URL builders, injected transport, fail-loud non-2xx,
  401 → `invalidGrant`).
- **Triage ("worthy of attention" + draft generation):** the scout's KEEP/DROP
  judgement moves into a `GmailTriage` prompt run through headless `claude -p`
  (via the injected `ClaudeRun` + the shared `AgentExecutionGate`). Only Gmail
  *access* needed a connector (ADR-0007); the email bodies are embedded in the
  prompt and grounding reads the local KBs (cwd = the KB folders' common parent).
  Provenance (ids, thread, URL, labels, date) comes from our fetch, never from
  model output.
- **Routing:** kept emails route to one of the enabled vault-source projects
  (`GmailTriage.routes(from: SourceSettings)`); the rec's `vaultPath` is that
  project's working directory, so keep/execute/export behave exactly like scout recs.
- **Idempotency:** two layers — the existing `SourceDedupe` on
  `(gmail, sourceEventID)`, plus a bounded seen-id set (`GmailSyncState`, UserDefaults)
  so DROPped noise isn't re-triaged (re-paid) every poll. Ids are marked seen only
  after a successful triage parse; failures retry next poll.
- **Actions:** `GmailService.archive` (remove `INBOX`), `GmailService.sendReply`
  (re-fetch original for fresh headers → `GmailMime` RFC 2822 reply with
  `In-Reply-To`/`References` → `messages.send` with `threadId`).
- **No SwiftData schema change.** Everything new persists to Keychain or
  UserDefaults blobs (`gmailSettings`, `gmailSyncState`).

## Non-goals

- No service account, no Nylas/Zapier, no Pub/Sub (per handoff).
- No auto-send under any trust level. No delete/trash — archive only.
- No Gmail UI in Mustard beyond the recommendation cards + Settings section
  (this is triage, not a mail client).
- iOS: MustardKit Gmail code compiles for iOS (parity rule) but the mobile app
  re-implements views separately and shows sample data (no CloudKit) — no mobile
  UI in this slice.

## What Leon must do to turn it on (post-merge)

1. Google Cloud console: enable the Gmail API on the same project as the Calendar
   OAuth client (or create one), OAuth client type **Desktop app**.
2. Settings → Gmail: paste client id/secret → Connect → approve in browser
   (consent screen will warn "unverified" — expected).
3. Pick the label to poll (defaults to INBOX) and toggle "Poll inbox" on.
