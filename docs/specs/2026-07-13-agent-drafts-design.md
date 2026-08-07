# File-backed Agent Drafts — Design

- **Status:** Implemented and eye-checked by Leon (2026-07-20); includes the companion side panel and the durable marker-hiding fix (cfd60a4)
- **Date:** 2026-07-13
- **Depends on:** the agent task-sessions core MVP (F24, `docs/specs/2026-07-13-agent-task-sessions-design.md`)
- **Branch:** `codex/agent-task-sessions-implementation`

## Problem

A completed delegated turn can produce drafted content — a Jira/Shortcut comment, an
email, a Slack message, a note. Today the only place that content can land is the
structured result's prose (`message`/`summary`), and the coordinator stores `summary`
in preference to `message` (`AgentTaskCoordinator.apply(_ result:)`), so a full draft
returned in `message` is **not shown and not retrievable** — only a one-line summary
survives. Large drafts would also bloat the SwiftData conversation. The first real test
task ("Jira Question") surfaced this: the agent drafted a formal Jira reply plus two
guideline URLs, but only the summary was visible.

## Goal

Give every draft a durable, copy-able, in-app home that handles arbitrarily large content,
without sending anything and without converting tasks into notes.

## Approach

A draft **is a vault markdown file**. The worker writes it to the vault (it already has
vault access) and returns a lightweight reference; Mustard records the reference and renders
— and lets you **edit** — the file **inline in the task detail panel, which opens over the
board**. Reviewing a draft never changes surfaces: no jump to the Notes tab, no context
switch. The embedded markdown editor is the one we already built (Notes/Craft editor); the
conversation keeps only a short line, so the transcript stays lean regardless of draft size.

## Components

### 1. File location & format
- Path: `<vault>/_agent/drafts/<task-uid>/<slug>.md`, namespaced per task, alongside the
  existing `_agent/outbox`/`results`.
- Always markdown. Multiple drafts per task allowed (one file each).
- Files persist (durable record); no auto-cleanup on accept in this iteration.

### 2. Worker contract (`AgentTurnContract` + `MustardAgentContract.md`)
- `AgentTurnResult` gains `drafts: [AgentDraftPayload]` where
  `AgentDraftPayload = { kind: String, title: String, path: String }` (`path` relative to
  the run's working directory).
- `kind` is a small closed set for iconography: `email`, `message`, `comment`, `note`,
  `other` (decoded leniently; unknown → `other`).
- JSON schema updated to include the optional `drafts` array with those required subfields.
- Semantic post-validation: reject absolute paths and any `..` segment — a draft path must
  stay inside `_agent/drafts/` within the working directory. A payload that fails is dropped
  with an error note rather than trusted.
- Contract text (binding): *any drafted content must be written to a file under
  `_agent/drafts/<task-uid>/` and returned in `drafts[]` with its relative path — never
  inline large content in `message`/`summary`. Never send; drafts only.*

### 3. Connected-worker parity (`BridgeProtocol.AgentResult`, `BridgeIngest`, `AgentService`)
- `AgentResult` gains an optional `drafts: [AgentDraftPayload]?`.
- The connected worker writes the same file layout and returns paths.
- `AgentService.normalizeConnectedResult` records draft references identically to the local
  path, so local and connected turns behave the same.

### 4. Storage (`AgentDraft` model)
- New `@Model AgentDraft { uid, kindRaw, title, relativePath, createdAt, run: AgentRun? }`
  with a typed `kind` accessor.
- `AgentRun` gains `@Relationship(deleteRule: .cascade, inverse: \AgentDraft.run) drafts: [AgentDraft]?`
  — drafts reach the task via `run.task` and are cleaned up with the run.
- Only the **reference** is persisted in SwiftData; the body stays on disk.
- Registered in `MustardContainer`, `PreviewData`, and every model test schema that includes
  `MustardTask`/`AgentRun`.

### 5. Coordinator wiring (`AgentTaskCoordinator`)
- On a completed turn (and any outcome that returns drafts), for each validated payload
  create an `AgentDraft` on the run (via a small helper, mirroring the `AgentConversation`
  pattern). The completion message summarises count only ("Drafted 2 items"), never the
  bodies.
- Draft creation participates in the existing narrow snapshot/restore on save failure.

### 6. Display & edit (`AgentDraftsSection` in the task detail — in place, over the board)
The task detail already opens as a panel/drawer over the board, so everything below happens
without leaving the board or switching surfaces.

- A "Drafts" section (shown when `run.drafts` is non-empty). Each draft is a **compact
  reference card**: `kind` icon + title + a 2–3 line snippet of the body (read live from the
  file). Tapping it (or its **Open** affordance) does NOT expand in place — a tiny embedded
  box is a poor reading surface (UX review, 2026-07-20).
- Instead, opening a draft slides a **full-height companion panel in beside the task panel,
  to its left** (same docked-drawer pattern the task panel uses), giving the draft real
  reading width. The panel hosts the embedded markdown editor we already built
  (`MarkdownTextView` on the file at `run.workingDirectory + draft.relativePath`), **editable
  in place** with autosave (a "saved" affordance) plus **Copy** and a close control. The file
  is the single source of truth — read live, never cached into the store, so size is a
  non-issue.
- **One draft panel at a time**: opening another draft swaps the panel's content. Closing the
  task panel closes the draft panel with it. Review actions (Request changes / Accept / Take
  back) stay in the task panel only, so the two sit side by side: read left, act right.
- **Comment / request changes**: the task panel's existing review bar carries a
  feedback field → `AgentTaskCoordinator.requestChanges` (a comment *to the agent*), alongside
  **Take back** and **Accept output** — all in the same panel.
- Missing/moved file → a graceful "draft file not found" state, not a crash.
- Optional (not the primary path): a small "pop out to Notes ↗" affordance for a heavy editing
  session, routing a `NoteRef` open-request to the Notes tab. Deferrable — the in-place editor
  covers review and light edits.

### 7. Safety
- Path validation confines drafts to `_agent/drafts/` within the working directory — for both
  reading and the in-place editor's writes.
- Mustard writes to a draft file only through the user-driven inline editor (their own edits);
  it never posts or sends. The agent likewise only *drafts* — the no-send rule is unchanged and
  reinforced in the contract.

## Testing
- **Pure:** `AgentTurnContract` decode of `drafts[]`; path-safety validation (absolute / `..`
  rejected). Pin no clock here.
- **Coordinator (stub runtime):** a completed result carrying `drafts[]` creates matching
  `AgentDraft` records on the run; the summary message excludes bodies; invalid paths are
  dropped.
- **Bridge:** a connected `AgentResult` with `drafts` creates `AgentDraft` records via ingest.
- **Model round-trip:** `AgentDraft` persists and resolves through `run.drafts`.
- **View:** build + Leon's eye-check (collapsed preview → expand to inline editor, edit
  autosaves to the file, Copy, Collapse, review bar in the same panel over the board).

## Out of scope (YAGNI)
- Anchored inline/margin comments *on* the draft text (Google-Docs-style annotations) — our
  editor has no annotation layer; a comment *to the agent* uses the existing review field.
- Converting tasks into vault notes (separate epic if ever wanted).
- Routing *non-draft* large outputs through files (same mechanism could extend later).
- Auto-cleanup / lifecycle status on draft files (accepted/used/stale).
- Cross-surface Notes navigation as the primary review path (in-place only; a "pop out to
  Notes" escape hatch is optional and deferrable).
