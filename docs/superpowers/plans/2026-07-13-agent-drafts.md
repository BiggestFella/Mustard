# File-backed Agent Drafts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a delegated turn produce drafts (Jira/Shortcut comment, email, Slack, note) as vault markdown files that Mustard shows and edits **in place** in the task detail panel over the board — never truncated, never navigating away, never sent.

**Architecture:** The worker writes each draft to `<vault>/_agent/drafts/<task-uid>/<slug>.md` and returns a lightweight `{kind,title,path}` reference in the structured result. Mustard persists only the reference (`AgentDraft` model on `AgentRun`), reads the file live, and renders/edits it inline with the existing `MarkdownTextView` editor. Same path for local (coordinator) and connected (bridge) turns.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData, XCTest. Design spec: `docs/specs/2026-07-13-agent-drafts-design.md`.

---

## File structure

### New files
| File | Responsibility |
|---|---|
| `Sources/MustardKit/Models/AgentDraft.swift` | `@Model AgentDraft` + `AgentDraftKind` enum |
| `Sources/MustardKit/Views/AgentDraftsSection.swift` | Collapsed preview card → inline editor, Copy, Collapse |
| `Tests/MustardTests/AgentDraftModelTests.swift` | Model persistence + `run.drafts` round-trip |

### Modified files
| File | Change |
|---|---|
| `Sources/MustardKit/Agent/AgentTurnContract.swift` | `AgentDraftPayload`, `drafts` on `AgentTurnResult`, schema, key-check loosened to subset, `AgentDrafts.isSafeRelativePath` |
| `Sources/MustardKit/Agent/AgentConversation.swift` | `materializeDrafts` shared helper |
| `Sources/MustardKit/Models/AgentRun.swift` | `drafts` cascade relationship |
| `Sources/MustardKit/Agent/AgentTaskCoordinator.swift` | Materialize drafts on a result; include in the save-failure rollback |
| `Sources/MustardKit/Logic/BridgeProtocol.swift` | `drafts: [AgentDraftPayload]?` on `AgentResult` |
| `Sources/MustardKit/Agent/AgentService.swift` | `normalizeConnectedResult` materializes drafts |
| `Sources/MustardKit/Agent/Prompts/MustardAgentContract.md` | Drafts convention text |
| `Sources/MustardKit/Views/TaskDetailSheet.swift` | Mount `AgentDraftsSection` when `run.drafts` non-empty |
| `Sources/MustardKit/MustardContainer.swift` | Register `AgentDraft.self` |
| `Sources/MustardKit/PreviewData.swift` | Register model + a sample draft (with a real temp file) |
| `Tests/MustardTests/AgentTurnContractTests.swift` | Draft decode + path-safety + contract-text tests |
| `Tests/MustardTests/AgentTaskCoordinatorTests.swift` | Draft materialization tests + schema `AgentDraft.self` |
| `Tests/MustardTests/AgentBridgeServiceTests.swift` | Connected-draft test + schema `AgentDraft.self` |
| `Tests/MustardTests/AgentRunModelTests.swift` | Schema `AgentDraft.self` |
| `docs/architecture.md` | Add `AgentDraft` to the model table |

---

## Task 1: Draft payload, contract field, and path safety

**Files:**
- Modify: `Sources/MustardKit/Agent/AgentTurnContract.swift`
- Test: `Tests/MustardTests/AgentTurnContractTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `AgentTurnContractTests`:

```swift
func test_decodesDraftsWhenPresent() throws {
    let json = #"{"outcome":"completed","message":"done","questions":[],"summary":"Drafted","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null,"drafts":[{"kind":"comment","title":"Jira reply","path":"_agent/drafts/u1/reply.md"}]}"#
    let result = try AgentTurnContract.decode(json)
    XCTAssertEqual(result.drafts?.count, 1)
    XCTAssertEqual(result.drafts?.first?.kind, "comment")
    XCTAssertEqual(result.drafts?.first?.path, "_agent/drafts/u1/reply.md")
}

func test_decodesWithoutDraftsKey_defaultsToNil() throws {
    let json = #"{"outcome":"completed","message":"done","questions":[],"summary":"s","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#
    let result = try AgentTurnContract.decode(json)
    XCTAssertNil(result.drafts)
}

func test_rejectsUnknownTopLevelKey() {
    let json = #"{"outcome":"completed","message":"m","questions":[],"summary":"s","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null,"bogus":1}"#
    XCTAssertThrowsError(try AgentTurnContract.decode(json))
}

func test_draftPathSafety() {
    XCTAssertTrue(AgentDrafts.isSafeRelativePath("_agent/drafts/u1/reply.md"))
    XCTAssertFalse(AgentDrafts.isSafeRelativePath("/etc/passwd"))
    XCTAssertFalse(AgentDrafts.isSafeRelativePath("_agent/drafts/../../secret.md"))
    XCTAssertFalse(AgentDrafts.isSafeRelativePath("notes/elsewhere.md"))
    XCTAssertFalse(AgentDrafts.isSafeRelativePath(""))
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter AgentTurnContractTests`
Expected: FAIL — `AgentDraftPayload`/`AgentDrafts`/`drafts` unresolved.

- [ ] **Step 3: Add the payload, safety helper, and contract field**

In `AgentTurnContract.swift`, add near the other value types:

```swift
public struct AgentDraftPayload: Codable, Equatable, Sendable {
    public let kind: String
    public let title: String
    public let path: String
    public init(kind: String, title: String, path: String) {
        self.kind = kind; self.title = title; self.path = path
    }
}

public enum AgentDrafts {
    /// A draft path must be relative, escape-free, and confined to the drafts folder.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"),
              trimmed.hasPrefix("_agent/drafts/") else { return false }
        return !trimmed.split(separator: "/").contains("..")
    }
}
```

Add `drafts` to `AgentTurnResult` as an optional stored property and give it an explicit
public initializer (this replaces the synthesized memberwise init; existing `.init(...)`
call sites pass the first eight arguments and default `drafts` to `nil`):

```swift
public struct AgentTurnResult: Codable, Equatable, Sendable {
    public let outcome: AgentTurnOutcome
    public let message: String
    public let questions: [String]
    public let summary: String
    public let artifacts: [AgentArtifact]
    public let retryDisposition: AgentRetryDisposition
    public let errorCategory: String?
    public let connectedCapability: String?
    public let drafts: [AgentDraftPayload]?

    public init(
        outcome: AgentTurnOutcome, message: String, questions: [String], summary: String,
        artifacts: [AgentArtifact], retryDisposition: AgentRetryDisposition,
        errorCategory: String?, connectedCapability: String?,
        drafts: [AgentDraftPayload]? = nil
    ) {
        self.outcome = outcome; self.message = message; self.questions = questions
        self.summary = summary; self.artifacts = artifacts; self.retryDisposition = retryDisposition
        self.errorCategory = errorCategory; self.connectedCapability = connectedCapability
        self.drafts = drafts
    }
}
```

`drafts` is optional, so synthesized `Codable` decodes a missing key as `nil` — no custom
`init(from:)` needed.

- [ ] **Step 4: Extend the schema and loosen the key check**

In `AgentTurnContract.jsonSchema`, add a `drafts` property (do NOT add it to `required`):

```json
"drafts":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"kind":{"type":"string"},"title":{"type":"string"},"path":{"type":"string"}},"required":["kind","title","path"]}}
```

In `validateNoUnknownProperties`, split the check into required-presence + no-unknown-keys.
The original 8 keys must ALL be present (this is what rejects a payload that omits a
nullable key instead of sending an explicit `null` — see
`test_rejectsMissingNullableKeysEvenWhenOutcomePermitsNull`); only `drafts` may be absent:

```swift
let requiredResultKeys: Set<String> = [
    "outcome", "message", "questions", "summary", "artifacts",
    "retryDisposition", "errorCategory", "connectedCapability",
]
let optionalResultKeys: Set<String> = ["drafts"]
let keys = Set(object.keys)
guard requiredResultKeys.isSubset(of: keys),
      keys.isSubset(of: requiredResultKeys.union(optionalResultKeys)) else {
    throw CocoaError(.propertyListReadCorrupt)
}
```

This preserves the existing strictness exactly (missing nullable keys still throw; unknown
keys still throw) while tolerating an absent `drafts`.

- [ ] **Step 5: Run and confirm pass**

Run: `swift test --filter AgentTurnContractTests`
Expected: PASS (including the pre-existing contract tests — their JSON keys are a subset of the allowed set).

- [ ] **Step 6: Commit**

```bash
git add Sources/MustardKit/Agent/AgentTurnContract.swift Tests/MustardTests/AgentTurnContractTests.swift
git commit -m "feat(agent): add drafts to the turn contract" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: `AgentDraft` model + relationship + registrations

**Files:**
- Create: `Sources/MustardKit/Models/AgentDraft.swift`
- Modify: `Sources/MustardKit/Models/AgentRun.swift`
- Modify: `Sources/MustardKit/MustardContainer.swift`
- Modify: `Sources/MustardKit/PreviewData.swift` (schema only; sample draft is Task 7)
- Create: `Tests/MustardTests/AgentDraftModelTests.swift`
- Modify: test-local schemas in `AgentTaskCoordinatorTests.swift`, `AgentBridgeServiceTests.swift`, `AgentRunModelTests.swift`

- [ ] **Step 1: Write the failing round-trip test**

Create `AgentDraftModelTests.swift`:

```swift
import XCTest
import SwiftData
@testable import MustardKit

final class AgentDraftModelTests: XCTestCase {
    @MainActor
    func test_draftRoundTripsThroughRun() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, AgentDraft.self, configurations: config)
        let context = ModelContext(container)
        let task = MustardTask(title: "Prep")
        let run = AgentRun(task: task)
        let draft = AgentDraft(run: run, kind: .comment, title: "Jira reply",
                               relativePath: "_agent/drafts/u1/reply.md")
        context.insert(task); context.insert(run); context.insert(draft)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<AgentRun>()).first)
        XCTAssertEqual(fetched.drafts?.count, 1)
        XCTAssertEqual(fetched.drafts?.first?.kind, .comment)
        XCTAssertEqual(fetched.drafts?.first?.relativePath, "_agent/drafts/u1/reply.md")
    }

    func test_kindDefaultsToOtherForUnknownRaw() {
        let draft = AgentDraft()
        draft.kindRaw = "unknown"
        XCTAssertEqual(draft.kind, .other)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter AgentDraftModelTests`
Expected: FAIL — `AgentDraft` unresolved.

- [ ] **Step 3: Create the model**

Create `Sources/MustardKit/Models/AgentDraft.swift`:

```swift
import Foundation
import SwiftData

public enum AgentDraftKind: String, Codable, CaseIterable {
    case email, message, comment, note, other
}

@Model
public final class AgentDraft {
    public var uid: String = UUID().uuidString
    public var kindRaw: String = AgentDraftKind.note.rawValue
    public var title: String = ""
    /// Path relative to the owning run's `workingDirectory`.
    public var relativePath: String = ""
    public var createdAt: Date = Date.now
    public var run: AgentRun?

    public var kind: AgentDraftKind {
        get { AgentDraftKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    public init(run: AgentRun? = nil, kind: AgentDraftKind = .note,
                title: String = "", relativePath: String = "") {
        self.run = run
        self.kindRaw = kind.rawValue
        self.title = title
        self.relativePath = relativePath
    }
}
```

- [ ] **Step 4: Add the relationship on `AgentRun`**

In `AgentRun.swift`, after the `messages` relationship, add:

```swift
@Relationship(deleteRule: .cascade, inverse: \AgentDraft.run)
public var drafts: [AgentDraft]? = []
```

- [ ] **Step 5: Register the model everywhere a MustardTask/AgentRun schema is built**

Add `AgentDraft.self` to the `ModelContainer(for:)` list in each of:
- `Sources/MustardKit/MustardContainer.swift`
- `Sources/MustardKit/PreviewData.swift`
- `Tests/MustardTests/AgentTaskCoordinatorTests.swift` (the `fixture` container AND `makeContainer`)
- `Tests/MustardTests/AgentBridgeServiceTests.swift` (the `service` container)
- `Tests/MustardTests/AgentRunModelTests.swift` (both containers)

Each edit inserts `AgentDraft.self` alongside `AgentRun.self, AgentMessage.self`.

- [ ] **Step 6: Run model + regression tests**

Run: `swift test --filter 'AgentDraftModelTests|AgentRunModelTests|AgentTaskCoordinatorTests|AgentBridgeServiceTests'`
Expected: PASS (no SwiftData inverse/schema errors).

- [ ] **Step 7: Commit**

```bash
git add Sources/MustardKit/Models/AgentDraft.swift Sources/MustardKit/Models/AgentRun.swift Sources/MustardKit/MustardContainer.swift Sources/MustardKit/PreviewData.swift Tests/MustardTests
git commit -m "feat(agent): persist agent draft references" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: Materialize drafts from a completed local turn

**Files:**
- Modify: `Sources/MustardKit/Agent/AgentConversation.swift`
- Modify: `Sources/MustardKit/Agent/AgentTaskCoordinator.swift`
- Test: `Tests/MustardTests/AgentTaskCoordinatorTests.swift`

- [ ] **Step 1: Write failing coordinator tests**

Add to `AgentTaskCoordinatorTests`:

```swift
func test_completedTurnMaterializesValidDraftsAndDropsUnsafeOnes() async throws {
    let runtime = ScriptedAgentRuntime(responses: [
        .success(.init(outcome: .completed, message: "done", questions: [], summary: "Drafted",
                       artifacts: [], retryDisposition: .none, errorCategory: nil,
                       connectedCapability: nil, drafts: [
                           .init(kind: "comment", title: "Jira reply", path: "_agent/drafts/u1/reply.md"),
                           .init(kind: "email", title: "Escape attempt", path: "../../etc/passwd"),
                       ])),
    ])
    let (coordinator, context) = try fixture(runtime: runtime)
    let task = insertRoutedTask(in: context, title: "Draft it", stage: .forAgent)

    await coordinator.runNext(settings: settings, now: firstTurn)

    XCTAssertEqual(task.stage, .needsReview)
    let drafts = task.agentRun?.drafts ?? []
    XCTAssertEqual(drafts.count, 1)
    XCTAssertEqual(drafts.first?.kind, .comment)
    XCTAssertEqual(drafts.first?.relativePath, "_agent/drafts/u1/reply.md")
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter 'AgentTaskCoordinatorTests/test_completedTurnMaterializesValidDraftsAndDropsUnsafeOnes'`
Expected: FAIL — `drafts` param unknown / no drafts materialized.

- [ ] **Step 3: Add the shared materialize helper**

In `AgentConversation.swift`, add:

```swift
@discardableResult
static func materializeDrafts(
    _ payloads: [AgentDraftPayload],
    into run: AgentRun,
    in context: ModelContext
) -> [AgentDraft] {
    var created: [AgentDraft] = []
    for payload in payloads where AgentDrafts.isSafeRelativePath(payload.path) {
        let draft = AgentDraft(
            run: run,
            kind: AgentDraftKind(rawValue: payload.kind) ?? .other,
            title: payload.title.isEmpty ? payload.path : payload.title,
            relativePath: payload.path
        )
        context.insert(draft)
        created.append(draft)
    }
    return created
}
```

- [ ] **Step 4: Call it from `apply(_ result:)` and roll back on save failure**

In `AgentTaskCoordinator.apply(_ result:to:run:now:)`, immediately after the `switch
result.outcome` block that assigns `outcomeMessage` and before `guard save(...)`, add:

```swift
let createdDrafts = AgentConversation.materializeDrafts(result.drafts ?? [], into: run, in: context)
```

Then, inside the existing `guard save("Could not save the agent turn result") else { ... }`
failure block (which already restores the task/run snapshots and removes `outcomeMessage`),
add draft cleanup before `compensatePersistenceFailure`:

```swift
for draft in createdDrafts { draft.run = nil; context.delete(draft) }
```

- [ ] **Step 5: Run the test**

Run: `swift test --filter 'AgentTaskCoordinatorTests'`
Expected: PASS (all coordinator tests, including the new one).

- [ ] **Step 6: Commit**

```bash
git add Sources/MustardKit/Agent/AgentConversation.swift Sources/MustardKit/Agent/AgentTaskCoordinator.swift Tests/MustardTests/AgentTaskCoordinatorTests.swift
git commit -m "feat(agent): materialize drafts from a completed turn" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: Connected-worker (bridge) draft parity

**Files:**
- Modify: `Sources/MustardKit/Logic/BridgeProtocol.swift`
- Modify: `Sources/MustardKit/Agent/AgentService.swift`
- Test: `Tests/MustardTests/AgentBridgeServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `AgentBridgeServiceTests`:

```swift
@MainActor
func test_ingest_materializesConnectedDrafts() throws {
    let io = StubIO(); let (svc, ctx) = try service(io)
    let t = MustardTask(title: "ship"); t.uid = "u1"; t.stage = .queued
    let run = AgentRun(task: t); run.requiresConnectedWorker = true; run.state = .running
    t.agentRun = run
    ctx.insert(t); ctx.insert(run)
    io.results = [(AgentResult(uid: "u1", mode: "execute", status: "done", actionType: nil,
        title: nil, body: nil, links: nil, summary: "Drafted", error: nil,
        drafts: [AgentDraftPayload(kind: "email", title: "Reply", path: "_agent/drafts/u1/reply.md")]),
        "/kb/DL/_agent/results/u1.json")]

    svc.ingestAgentResults(workingDir: "/kb/DL")

    XCTAssertEqual(run.drafts?.count, 1)
    XCTAssertEqual(run.drafts?.first?.kind, .email)
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter 'AgentBridgeServiceTests/test_ingest_materializesConnectedDrafts'`
Expected: FAIL — `AgentResult` has no `drafts` parameter.

- [ ] **Step 3: Add `drafts` to `AgentResult`**

In `BridgeProtocol.swift`, add the stored property and initializer parameter (last, defaulted
so existing call sites keep working):

```swift
public var drafts: [AgentDraftPayload]?
```

In the `init`, add `drafts: [AgentDraftPayload]? = nil` as the final parameter and
`self.drafts = drafts` in the body.

- [ ] **Step 4: Materialize in `normalizeConnectedResult`**

In `AgentService.normalizeConnectedResult(_ r:into:)`, at the end (after the `switch`), add:

```swift
AgentConversation.materializeDrafts(r.drafts ?? [], into: run, in: context)
```

- [ ] **Step 5: Run bridge tests**

Run: `swift test --filter 'AgentBridgeServiceTests|BridgeIngestTests|BridgeExportTests'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MustardKit/Logic/BridgeProtocol.swift Sources/MustardKit/Agent/AgentService.swift Tests/MustardTests/AgentBridgeServiceTests.swift
git commit -m "feat(agent): capture drafts from connected worker results" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: Worker contract instruction

**Files:**
- Modify: `Sources/MustardKit/Agent/Prompts/MustardAgentContract.md`
- Test: `Tests/MustardTests/AgentTurnContractTests.swift`

- [ ] **Step 1: Add the failing assertion**

Extend `test_workerContractContainsHardSafetyRules` (or add a new test) with:

```swift
func test_workerContractDescribesDraftFiles() throws {
    let text = try AgentTurnContract.workerContract()
    XCTAssertTrue(text.contains("_agent/drafts/"))
    XCTAssertTrue(text.contains("drafts[]"))
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter 'AgentTurnContractTests/test_workerContractDescribesDraftFiles'`
Expected: FAIL.

- [ ] **Step 3: Add the convention to the contract**

Append to `MustardAgentContract.md`:

```markdown
When you produce drafted content (an email, a message, a ticket/comment, or a note), write
the full draft to a markdown file at `_agent/drafts/<task-uid>/<slug>.md` and return it in
`drafts[]` as `{ "kind": "email|message|comment|note|other", "title": "...", "path": "_agent/drafts/<task-uid>/<slug>.md" }`.
Never inline a large draft body in `message` or `summary`; never send or post it. Always
include a `drafts` array (empty when there are none).
```

- [ ] **Step 4: Run + repackage probe**

Run: `swift test --filter AgentTurnContractTests`
Then: `./build-app.sh` (the packaged worker-contract probe must still pass).
Expected: tests PASS; build prints `Verified packaged Mustard worker contract`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Agent/Prompts/MustardAgentContract.md Tests/MustardTests/AgentTurnContractTests.swift
git commit -m "docs(agent): worker contract writes drafts to files" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: In-place Drafts section (view)

**Files:**
- Create: `Sources/MustardKit/Views/AgentDraftsSection.swift`
- Modify: `Sources/MustardKit/Views/TaskDetailSheet.swift`

No unit tests (SwiftUI view — build + Leon's eye-check, per the testing rules).

- [ ] **Step 1: Create the Drafts section view**

Create `Sources/MustardKit/Views/AgentDraftsSection.swift`:

```swift
import SwiftUI
import SwiftData

/// The task's agent drafts, shown and edited in place (the task detail opens over the
/// board, so nothing navigates away). Each draft is a vault markdown file read live; the
/// expanded editor is the shared MarkdownTextView, autosaving back to the file.
public struct AgentDraftsSection: View {
    let run: AgentRun
    public init(run: AgentRun) { self.run = run }

    private var drafts: [AgentDraft] {
        (run.drafts ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    public var body: some View {
        if !drafts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("DRAFTS")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                ForEach(drafts, id: \.uid) { draft in
                    AgentDraftCard(draft: draft, workingDirectory: run.workingDirectory)
                }
            }
        }
    }
}

private struct AgentDraftCard: View {
    let draft: AgentDraft
    let workingDirectory: String
    @State private var expanded = false
    @State private var text: String = ""
    @State private var loaded = false

    private var io: FileVaultIO { FileVaultIO(rootPath: workingDirectory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                if loaded {
                    MarkdownTextView(text: $text)
                        .frame(minHeight: 160, maxHeight: 420)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline, lineWidth: 0.5))
                        .onChange(of: text) { _, newValue in try? io.write(draft.relativePath, newValue) }
                } else {
                    Text("Draft file not found — it may have been moved.")
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.warnText)
                }
                actions
            } else {
                Text(snippet).font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(3)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.Palette.hairline).frame(width: 2) }
                actions
            }
        }
        .padding(12)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        .task(id: draft.uid) { load() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(Theme.Fonts.body).foregroundStyle(Theme.Palette.agent)
            Text(draft.title).font(Theme.Fonts.body).fontWeight(.medium)
            Spacer(minLength: 8)
            Text(draft.kind.rawValue)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.agentText)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Theme.Palette.agentTintLight, in: Capsule())
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { expanded.toggle() } label: {
                Label(expanded ? "Collapse" : "Expand",
                      systemImage: expanded ? "chevron.up" : "chevron.down")
            }.controlSize(.small)
            Button {
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #endif
            } label: { Label("Copy", systemImage: "doc.on.doc") }
                .controlSize(.small).disabled(!loaded)
            Spacer(minLength: 0)
        }
    }

    private var snippet: String {
        loaded ? text : "Loading…"
    }

    private var icon: String {
        switch draft.kind {
        case .email: return "envelope"
        case .message: return "message"
        case .comment: return "text.bubble"
        case .note, .other: return "doc.text"
        }
    }

    private func load() {
        if let contents = io.read(draft.relativePath) {
            text = contents; loaded = true
        } else {
            loaded = false
        }
    }
}
```

- [ ] **Step 2: Mount it in the task detail**

In `TaskDetailSheet.swift`, in `body`, immediately after the `AgentConversationView` mount
(`if task.agentRun != nil { AgentConversationView(task: task) }`), add:

```swift
if let run = task.agentRun, !(run.drafts ?? []).isEmpty {
    AgentDraftsSection(run: run)
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Package and eye-check**

Run: `./build-app.sh && open build/Mustard.app`
Ask Leon to verify on a Needs Review task with a draft: the Drafts section shows a collapsed
card (kind + title + snippet), Expand reveals the editor inline in the same panel (board still
behind), edits persist, Copy works, Collapse works. State only that it builds and runs.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Views/AgentDraftsSection.swift Sources/MustardKit/Views/TaskDetailSheet.swift
git commit -m "feat(agent): show and edit drafts in place in the task" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: Preview fixture, docs, and MVP verification

**Files:**
- Modify: `Sources/MustardKit/PreviewData.swift`
- Modify: `docs/architecture.md`

- [ ] **Step 1: Add a preview draft backed by a real temp file**

In `PreviewData.swift`, after the Needs Review sample (`review`/`reviewRun`) is inserted, add
a draft whose file actually exists so the preview renders content:

```swift
let draftsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("mustard-preview/_agent/drafts/\(review.uid)", isDirectory: true)
try? FileManager.default.createDirectory(at: draftsDir, withIntermediateDirectories: true)
let draftRel = "_agent/drafts/\(review.uid)/jira-reply.md"
try? "## Jira reply (draft)\n\nThe \"Manage my QDI\" option can't satisfy Apple 5.1.1(v) or Google Play account-deletion rules, so the delete-worded option must stay regardless of SSP.\n\n- Apple 5.1.1(v)\n- Google Play account-deletion"
    .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mustard-preview/\(draftRel)"),
           atomically: true, encoding: .utf8)
reviewRun.workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mustard-preview").path
let previewDraft = AgentDraft(run: reviewRun, kind: .comment, title: "Manage my QDI — Jira reply",
                              relativePath: draftRel)
reviewRun.drafts = [previewDraft]
ctx.insert(previewDraft)
```

(`AgentDraft.self` was already added to the preview schema in Task 2.)

- [ ] **Step 2: Document the model**

In `docs/architecture.md`, add a row to the model table under `AgentMessage`:

```markdown
| `AgentDraft` | a file-backed draft the agent produced | `kind`, `title`, `relativePath` (under `_agent/drafts/`), → run. Body lives in the vault file, not the store |
```

- [ ] **Step 3: Full verification matrix**

Run each and confirm success:

```bash
swift test --filter 'AgentTurnContractTests|AgentDraftModelTests|AgentTaskCoordinatorTests|AgentBridgeServiceTests'
swift test
swift build
./build-app.sh
git diff --check
```

Expected: focused + full suites pass (0 failures), build succeeds, `Verified packaged Mustard
worker contract`, no whitespace errors.

- [ ] **Step 4: iOS target still compiles**

The new `AgentDraft` model is in `Models/` (compiled for iOS); `AgentDraftsSection` is in
`Views/` (excluded from iOS). Confirm no new iOS breakage beyond the known pre-existing one:

```bash
xcodegen generate
xcodebuild -project MustardMobile.xcodeproj -scheme MustardMobile -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:" | sort -u
```

Expected: only the pre-existing `PriorityFlag`/`TaskChipRow` errors (tracked separately) — no
new errors from `AgentDraft`/`AgentTurnContract`/`BridgeProtocol`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/PreviewData.swift docs/architecture.md
git commit -m "docs(agent): preview draft fixture and model docs" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Definition of done

- All new and existing tests pass; `swift build` and `./build-app.sh` succeed.
- A completed local turn and a connected-worker result both create `AgentDraft` references
  from safe paths; unsafe paths are dropped.
- The task detail shows drafts as collapsed cards that expand to an inline editor over the
  board, autosaving to the vault file; Copy works; no navigation to Notes.
- Nothing is sent; draft bodies never enter the SwiftData store.
- No merge to `main` — this stays on the feature branch for Leon's test and approval.
