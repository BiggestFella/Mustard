# Agent Bridge — File Contract (Phase 2)

> **Scope note (2026-07-13, F24):** the file bridge is now the **connected-worker fallback
> only**. Ordinary delegated tasks run locally on `AgentTaskCoordinator` and never touch the
> bridge; a card is exported **only** once a turn returns `requires_connected_worker` (its
> run's `requiresConnectedWorker == true`). `BridgeExport` enforces this, so the local
> coordinator and this bridge never both claim the same work. See CLAUDE.md → "Delegated
> agent tasks & the connected-worker fallback".

This is the interface between **Mustard** (the macOS app) and a **connected Claude
session** (Phase 3: the worker skill/routine with the Shortcut/Gmail connectors and the
DL skill). They cannot call each other directly — headless `claude -p` has no connectors
(ADR-0003) and the board lives in SwiftData a skill can't query — so they talk through
**JSON files in each KB vault**, mirroring the inbound `_recs/` → `InboxIngest` contract.

Phase 2 (this) ships Mustard's two halves: **export** (board → `outbox/`) and **ingest**
(`results/` → board), plus this contract. The **worker** that reads `outbox/`, does the
work, and writes `results/` is **Phase 3** — it implements the session side of this doc.

## Folder protocol

Under each KB working directory (routed by `AreaRouter` from the task's area):

```
<KB>/_agent/
  outbox/         Mustard writes work orders here          (Mustard owns writes)
    <uid>.json
    done/         the session archives a work order here after running it
  results/        the connected session writes outcomes here   (session owns writes)
    <uid>.json
    done/         Mustard archives a result here after applying it
```

**Ownership.** Mustard writes only under `outbox/` (never `outbox/done/`); the session
writes only under `results/` (never `results/done/`). **The consumer archives what it
consumed** into the sibling `done/`: the session moves a run work order to
`outbox/done/`; Mustard moves an applied result to `results/done/`. Archiving (not
deleting) gives an audit trail and guarantees nothing is re-run or re-applied.

Folder names are the constants in `BridgeFolders` (`Sources/MustardKit/Logic/BridgeProtocol.swift`).

**Filename:** `<task.uid>.json`. A re-queued task's prior files already sit in `done/`,
so a fresh `<uid>.json` does not collide. Two live results before Mustard archives → last
wins; the stage guard (below) still protects correctness.

## Lifecycle (one task)

1. A task enters `forAgent` (prep) or `queued` (execute). On Mustard's ~10-min loop,
   **export** routes it to its KB folder and writes `outbox/<uid>.json` — only if no live
   `outbox/<uid>.json` exists already (written once, not every cycle).
2. The session (Phase 3) reads `outbox/`, does the work, writes `results/<uid>.json`, and
   archives the order → `outbox/done/`.
3. On the loop, **ingest** reads `results/*.json`, applies each by `uid` (guarded — see
   the apply table), and archives it → `results/done/`.
4. **Stale-order cancel:** if a task left `forAgent`/`queued` while its order is still live
   in `outbox/` (not yet picked up), Mustard removes that outbox file on the next loop.

## Schemas

Both encode/decode with `JSONEncoder`/`JSONDecoder`, `.iso8601` dates, tolerant of missing
optionals (`BridgeCoding`).

### `AgentWorkOrder` — Mustard → `outbox/<uid>.json`

```
uid: String                 // stable match key (task.uid)
mode: "prep" | "execute"    // derived from stage: forAgent→prep, queued→execute
actionType: String          // task.actionType raw (may be "" for prep, to be classified)
title: String
body: String                // task.notes (the draft/details)
area: String                // task.list?.area?.name (e.g. "Digital Licence")
project: String             // KB folder code (e.g. "DL")
sourceContext: String
links: [{label, url}]        // usually empty on the way out
createdAt: String            // ISO-8601
```

### `AgentResult` — session → `results/<uid>.json`

```
uid: String
mode: "prep" | "execute"
status: "done" | "failed" | "declined"
// prep:
actionType: String?         // classified action (RecommendationAction raw, e.g. "ticket_write")
title: String?              // refined title
body: String?               // prepared draft
// execute:
links: [{label, url}]?       // created artifact links (Shortcut URL, Jira, draft)
summary: String?            // one-line what happened
error: String?              // message when failed
```

## Apply rules (guarded)

For each decoded result, Mustard finds the task by `uid`. It applies **only if the task is
still at the source stage** for that mode (`prep`→`forAgent`, `execute`→`queued`);
otherwise it archives the file without applying (the stale guard — the idempotency
backstop). Unknown `uid` → archive, no-op.

| mode · status     | effect on the task |
|-------------------|--------------------|
| prep · done       | set `actionType`, `notes` = prepared body, `title` (if given); stage → `needsApproval` |
| prep · declined   | `owner` = me, stage → `planned`, append note "🤖 Agent passed on this: {summary}" |
| prep · failed     | stay `forAgent`; surface `error` on `AgentService.lastError` |
| execute · done    | set `links`, append `summary` to notes; stage → `needsReview` |
| execute · failed  | stay `queued`; surface `error` on `lastError` (so the next export re-issues — retry) |
| execute · declined| `owner` = me, stage → `planned`, note appended |

Applying the same result twice is a no-op: after the first apply the task has left the
source stage, so the guard archives the second without effect.

## Worked examples

`outbox/u-9f3a.json` (execute — Mustard wrote this for a `queued` ticket task):

```json
{
  "actionType" : "ticket_write",
  "area" : "Digital Licence",
  "body" : "Driver licence renewal screen crashes on iOS 17 when the camera permission is denied.",
  "createdAt" : "2026-06-29T08:12:00Z",
  "links" : [],
  "mode" : "execute",
  "project" : "DL",
  "sourceContext" : "From standup 2026-06-29",
  "title" : "File bug: licence renewal crash on denied camera permission",
  "uid" : "u-9f3a"
}
```

`results/u-9f3a.json` (the session ran it and wrote this back):

```json
{
  "uid": "u-9f3a",
  "mode": "execute",
  "status": "done",
  "links": [{ "label": "Shortcut", "url": "https://app.shortcut.com/codeheroes/story/12345" }],
  "summary": "Created Shortcut story #12345 in the DL Bugs workflow."
}
```

After ingest, task `u-9f3a` moves to **Needs Review** with the Shortcut link, and the
result file is archived to `results/done/u-9f3a.json`.

A `prep` example — `results/u-77.json` for a `forAgent` task:

```json
{
  "uid": "u-77",
  "mode": "prep",
  "status": "done",
  "actionType": "ticket_write",
  "title": "Raise the SDK BLE timeout to 30s",
  "body": "Prepared story: bump the BLE scan timeout from 10s to 30s; see DIGIDMOB-812..."
}
```

After ingest, task `u-77` moves to **Needs Approval** with the classified action and the
prepared draft as its notes.

## The worker — `drain-agent-queue` (Phase 3, implemented)

The session side of this contract is the **`drain-agent-queue`** skill. It reads `outbox/`,
does the work (routing to a matching vault skill — `dl-create-shortcut-story`, the email/
Slack equivalents — or best-effort with the KB + connectors), writes `results/`, and
archives the order to `outbox/done/`.

**Where it lives:** `Codeheroes work/.claude/skills/drain-agent-queue/SKILL.md` — in the
sibling **`Codeheroes work`** vault repo, **not** in the Mustard repo, and **never pushed**
(that repo has tracked secrets). So it will not appear in a Mustard-repo session's skill
list; look for it in the vault.

**How to run it:** on-demand, in a **connected Claude session** (needs Shortcut/Gmail/Slack/
Chrome — headless `claude -p` inside Mustard cannot reach connectors, ADR-0003). Trigger it
with "drain the agent queue" / "run the agent worker" from a session in the `Codeheroes work`
directory. A scheduled routine wrapping it is still deferred (the Jira/Chrome step needs a
logged-in session). **Nothing consumes `outbox/` automatically** — if a card sits on
"Waiting for agent to pick up," the usual cause is simply that this worker has not been run.

## Manual end-to-end test

Mustard's two halves can be checked against a hand-written result, standing in for the
worker (use this when `drain-agent-queue` isn't being run):

1. In the app, approve an outward recommendation so a task enters **Approved · Queued**.
2. Confirm `<KB>/_agent/outbox/<uid>.json` appears with `"mode":"execute"`.
3. Hand-write `<KB>/_agent/results/<uid>.json`:
   ```json
   {"uid":"<uid>","mode":"execute","status":"done","links":[{"label":"Shortcut","url":"https://app.shortcut.com/x"}],"summary":"created"}
   ```
4. Wait for the ~10-min loop (or relaunch the app); confirm the task moved to **Needs
   Review** with the link, and the result file is now under `results/done/<uid>.json`.

For the real path, run `drain-agent-queue` in a connected session instead of steps 3–4.
