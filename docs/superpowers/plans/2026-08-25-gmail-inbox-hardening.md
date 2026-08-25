# Gmail Inbox — Deep-Review Hardening (fix plan)

Fixes the deep-review panel's blocking findings on PR #150. Apply in order, TDD where a
pure unit exists. Verify each with real exit codes (`... > /tmp/x.log 2>&1; echo EXIT:$?`),
never through a pipe. One commit per task, message given, trailer
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. HEAD is a88e162 (branch
claude/gmail-inbox-triage-02219c). Work in
/Users/leoncreed-baker/Documents/Cavehole/Mustard/.claude/worktrees/linear-backlog-audit-2dfaa5.

---

### Task H1: Locked-down `claude` invocation for triage (finding S1)

**Files:** Modify `Sources/MustardKit/Agent/ClaudeRunner.swift`; Modify
`Sources/Mustard/MustardApp.swift`; Test `Tests/MustardTests/ClaudeRunnerRestrictedTests.swift` (new).

The triage path must not inherit the machine's permission posture. Add a `restrictedRun`
that denies every write/exec/network/MCP tool and forces non-bypass permission mode.
`ClaudeInvocation` already carries arbitrary `arguments`, so this needs no engine change.

- [ ] **Step 1: Failing test** — assert the argv is what we expect (pure, no process spawn).
  Add a testable arg-builder rather than testing the closure's private argv. In
  `ClaudeRunner.swift` add a static func that builds the args, and test THAT:

```swift
// Tests/MustardTests/ClaudeRunnerRestrictedTests.swift
import XCTest
@testable import MustardKit

final class ClaudeRunnerRestrictedTests: XCTestCase {
    func testRestrictedArgsDenyDangerousToolsAndMCP() {
        let args = ClaudeRunner.restrictedArguments(prompt: "hi")
        // The prompt is present under -p.
        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args.contains("hi"))
        XCTAssertTrue(args.contains("--output-format"))
        // Non-bypass permission mode is forced.
        XCTAssertEqual(args[safe: args.firstIndex(of: "--permission-mode").map { $0 + 1 } ?? -1], "default")
        // MCP servers are strictly none.
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertEqual(args[safe: args.firstIndex(of: "--mcp-config").map { $0 + 1 } ?? -1], "{}")
        // Dangerous tools are denied; read-only tools allowed.
        let denied = args[safe: args.firstIndex(of: "--disallowedTools").map { $0 + 1 } ?? -1] ?? ""
        for tool in ["Bash", "Edit", "Write", "WebFetch", "WebSearch", "Task"] {
            XCTAssertTrue(denied.contains(tool), "\(tool) must be denied")
        }
        let allowed = args[safe: args.firstIndex(of: "--allowedTools").map { $0 + 1 } ?? -1] ?? ""
        XCTAssertEqual(allowed, "Read,Grep,Glob")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
```

- [ ] **Step 2:** run → compile failure (no `restrictedArguments`).
- [ ] **Step 3: Implement.** In `ClaudeRunner.swift`, OUTSIDE the `#if os(macOS)` block
  (so both platforms compile it — it only builds strings), add to the enum:

```swift
    /// Argv for a `claude -p` run hardened for UNTRUSTED input (email triage, ADR-0012).
    /// Denies every write/exec/network tool and all MCP servers, and forces non-bypass
    /// permission mode, so attacker-controlled prompt text cannot reach Bash/Write/Edit/
    /// WebFetch/WebSearch/Task or any connector — even when the machine's settings default
    /// to bypassPermissions (CLI `--disallowedTools` is a separate, enforcing mechanism).
    /// Read/Grep/Glob stay for KB grounding: a read secret can only reach a local, capped
    /// card field, never the network or an outward action. Pure, so it is unit-tested.
    static func restrictedArguments(prompt: String) -> [String] {
        [
            "-p", prompt,
            "--output-format", "json",
            "--permission-mode", "default",
            "--allowedTools", "Read,Grep,Glob",
            "--disallowedTools", "Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task",
            "--strict-mcp-config",
            "--mcp-config", "{}",
        ]
    }
```

  Then add a `restrictedRun` in BOTH the `#if os(macOS)` and `#else` branches, mirroring
  `run`. macOS branch (after `run`):

```swift
    /// `run` for untrusted triage input — see `restrictedArguments`.
    public static let restrictedRun: ClaudeRun = { prompt, cwd in
        await invoke(.init(id: UUID(), arguments: restrictedArguments(prompt: prompt), workingDirectory: cwd))
    }
```

  iOS `#else` branch (after the stub `run`):

```swift
    public static let restrictedRun: ClaudeRun = { _, _ in
        ClaudeResult(ok: false, text: "The agent runs on the Mac only.")
    }
```

- [ ] **Step 4:** In `Sources/Mustard/MustardApp.swift`, the GmailService construction passes
  `claude: ClaudeRunner.run` — change it to `claude: ClaudeRunner.restrictedRun`.
- [ ] **Step 5:** `swift test --filter ClaudeRunnerRestrictedTests > /tmp/h1.log 2>&1; echo EXIT:$?` → 0;
  `swift build > /tmp/h1b.log 2>&1; echo EXIT:$?` → 0.
- [ ] **Step 6: Commit** `fix(gmail): run email triage under a locked-down claude invocation`

---

### Task H2: Ground a single route at the KB, not its parent (finding S2)

**Files:** Modify `Sources/MustardKit/Gmail/GmailTriage.swift`; Modify `Tests/MustardTests/GmailTriageTests.swift`.

- [ ] **Step 1: Failing tests** — add to GmailTriageTests:

```swift
    func testGroundingDirectorySingleRouteGroundsAtKBNotParent() {
        let one = [GmailTriage.ProjectRoute(name: "DL", workingDirectory: "/kb/DL-Knowledge-Base")]
        XCTAssertEqual(GmailTriage.groundingDirectory(for: one), "/kb/DL-Knowledge-Base")
        // Project list renders the current directory, not a broken ./DL-Knowledge-Base/.
        let prompt = GmailTriage.prompt(emails: [email()], projects: one)
        XCTAssertTrue(prompt.contains("the current directory"))
    }
```

  (The existing `testGroundingDirectoryIsCommonParent` uses the two-route `routes`, so it is
  unaffected — it still returns "/kb". Leave it.)

- [ ] **Step 2:** run → fail (single route currently returns the parent).
- [ ] **Step 3: Implement.** In `groundingDirectory`, special-case one route; keep the
  deepest-common-ancestor walk for many:

```swift
    public static func groundingDirectory(for routes: [ProjectRoute]) -> String? {
        guard let first = routes.first else { return nil }
        // One route: ground at the KB itself — no reason to expose its siblings.
        guard routes.count > 1 else { return first.workingDirectory }
        var common = URL(fileURLWithPath: first.workingDirectory).deletingLastPathComponent().pathComponents
        for route in routes.dropFirst() {
            let comps = URL(fileURLWithPath: route.workingDirectory).deletingLastPathComponent().pathComponents
            var i = 0
            while i < min(common.count, comps.count), common[i] == comps[i] { i += 1 }
            common = Array(common.prefix(i))
        }
        guard common.count > 1 else { return nil }
        return "/" + common.dropFirst().joined(separator: "/")
    }
```

  And make `relativePath` + the project-list line handle "cwd == the KB":

```swift
    static func relativePath(of route: ProjectRoute, from base: String?) -> String {
        guard let base else { return URL(fileURLWithPath: route.workingDirectory).lastPathComponent }
        if route.workingDirectory == base { return "." }
        guard route.workingDirectory.hasPrefix(base + "/") else {
            return URL(fileURLWithPath: route.workingDirectory).lastPathComponent
        }
        return String(route.workingDirectory.dropFirst(base.count + 1))
    }
```

  In `prompt`, render the location cleanly:

```swift
        let projectList = projects.map { route in
            let rel = relativePath(of: route, from: base)
            let loc = rel == "." ? "the current directory" : "./\(rel)/"
            return "  • \(route.name) — notes in \(loc)"
        }.joined(separator: "\n")
```

- [ ] **Step 4:** `swift test --filter GmailTriageTests > /tmp/h2.log 2>&1; echo EXIT:$?` → 0.
- [ ] **Step 5: Commit** `fix(gmail): ground single-route triage at the KB, not its parent`

---

### Task H3: Cap failed-triage retries so a hostile email can't loop (finding S3)

**Files:** Modify `Sources/MustardKit/Gmail/GmailSettings.swift` (GmailSyncState +
GmailSyncPlanner helper); Modify `Sources/MustardKit/Gmail/GmailService.swift`;
Modify `Tests/MustardTests/GmailSyncPlannerTests.swift`, `Tests/MustardTests/GmailServiceTests.swift`.

- [ ] **Step 1: Failing planner test** — add to GmailSyncPlannerTests:

```swift
    func testGiveUpIDsAfterCap() {
        var fails: [String: Int] = ["a": 2]
        let give = GmailSyncPlanner.registerFailures(&fails, ids: ["a", "b"], giveUpAt: 3)
        XCTAssertEqual(give, ["a"])          // a hits 3 → give up; b now at 1
        XCTAssertEqual(fails["b"], 1)
        XCTAssertNil(fails["a"])             // cleared once given up
    }

    func testRegisterFailuresBounded() {
        var fails: [String: Int] = [:]
        _ = GmailSyncPlanner.registerFailures(&fails, ids: (0..<10).map { "id\($0)" }, giveUpAt: 3, cap: 4)
        XCTAssertLessThanOrEqual(fails.count, 4)
    }
```

- [ ] **Step 2:** run → fail.
- [ ] **Step 3: Implement.** In `GmailSettings.swift`, add to `GmailSyncState`:

```swift
    /// Failed-triage attempt counts per message id — so an email that keeps producing
    /// unparseable/failed triage (e.g. an injection emitting prose) is abandoned after a
    /// few tries instead of re-running claude on it every interval forever.
    public var failedAttempts: [String: Int]
```

  Update its `init` to default `failedAttempts: [String: Int] = [:]` (keep it last so existing
  call sites/decoding still work; Codable decode of older blobs lacking the key: add a custom
  `init(from:)` OR make the property optional-backed. Simplest: give it a default in `init` and
  rely on `decodeIfPresent` — add an explicit `init(from:)` mirroring SourceProposal's pattern,
  defaulting `failedAttempts` to `[:]` when absent).

  In `GmailSyncPlanner`, add:

```swift
    /// Bump failure counts for `ids`; return the ids that have now failed `giveUpAt` times
    /// (removing them from the map). Bounded to `cap` entries (drops lowest counts first).
    public static func registerFailures(
        _ counts: inout [String: Int], ids: [String], giveUpAt: Int, cap: Int = 500
    ) -> [String] {
        var giveUp: [String] = []
        for id in ids {
            let n = (counts[id] ?? 0) + 1
            if n >= giveUpAt { counts[id] = nil; giveUp.append(id) } else { counts[id] = n }
        }
        if counts.count > cap {
            for key in counts.sorted(by: { $0.value < $1.value }).prefix(counts.count - cap).map(\.key) {
                counts[key] = nil
            }
        }
        return giveUp
    }
```

- [ ] **Step 4:** In `GmailService.poll`, in BOTH the `result.ok == false` branch and the
  `.unparseable` branch, before returning, register failures and mark give-up ids seen so they
  stop being re-triaged; and on the success (`.proposals`) branch clear any failure counts for
  the processed ids. Concretely, replace the failure/unparseable early-returns with logic that:
  loads `sync`, calls `GmailSyncPlanner.registerFailures(&sync.failedAttempts, ids: newIDs, giveUpAt: 3)`,
  appends the returned give-up ids into `sync.seenEventIDs` via `updatedSeen`, sets
  `sync.lastPolledAt = now()`, saves, then sets the summary and returns. In the `.proposals`
  success branch, also do `for id in newIDs { sync.failedAttempts[id] = nil }` before saving.
  Keep the existing summaries.

- [ ] **Step 5: Failing service test** — add to GmailServiceTests: a poll whose claude always
  returns unparseable text, called 3 times, ends with the id in `seenEventIDs` and claude not
  invoked a 4th time. (Model it on `testPollUnparseableTriageOutputLeavesIDsUnseen`, but loop
  `poll` 3× and assert the id is seen after the 3rd, and a 4th poll does not increase a claude
  call counter.)

- [ ] **Step 6:** `swift test --filter "GmailSyncPlannerTests|GmailServiceTests|GmailSettingsTests" > /tmp/h3.log 2>&1; echo EXIT:$?` → 0.
- [ ] **Step 7: Commit** `fix(gmail): abandon an email after repeated triage failures`

---

### Task H4: Gmail card actions survive label reclassification (finding C1)

**Files:** Modify `Sources/MustardKit/Gmail/GmailTriage.swift` (centralize the permalink +
add a pure detector); Modify `Sources/MustardKit/Views/RecommendationDetailView.swift`;
Modify `Tests/MustardTests/GmailTriageTests.swift`.

`IngestNormalizer` rewrites `source` to jira/shortcut by label before insert, so gating the
card actions on `rec.source == "gmail"` hides them for the headline case. The durable signal is
the Gmail permalink, which `GmailTriage` always stamps and reclassification preserves.

- [ ] **Step 1: Failing test** — add to GmailTriageTests:

```swift
    func testIsGmailSourcedDetectsPermalink() {
        XCTAssertTrue(GmailTriage.isGmailSourced("https://mail.google.com/mail/u/0/#all/m1"))
        XCTAssertFalse(GmailTriage.isGmailSourced("https://app.shortcut.com/story/1"))
        XCTAssertFalse(GmailTriage.isGmailSourced(nil))
        XCTAssertFalse(GmailTriage.isGmailSourced(""))
    }
```

  Also assert `testParseJoinsProvenanceFromFetchNotModel`'s existing `sourceURL` expectation
  still equals the permalink built from the shared constant (no behavior change).

- [ ] **Step 2:** run → fail.
- [ ] **Step 3: Implement.** In `GmailTriage`, add a constant + helpers and use the constant in
  `parseOutcome` instead of the inline string:

```swift
    static let permalinkPrefix = "https://mail.google.com/mail/u/0/#all/"
    static func permalink(messageID: String) -> String { permalinkPrefix + messageID }
    /// True when a recommendation's sourceURL is a Gmail permalink — the durable signal that a
    /// rec came in over the Gmail transport, surviving IngestNormalizer's source reclassification
    /// (a Jira/Shortcut-labelled email is stored source=jira/shortcut but keeps this URL).
    public static func isGmailSourced(_ sourceURL: String?) -> Bool {
        (sourceURL ?? "").hasPrefix(permalinkPrefix)
    }
```

  In `parseOutcome`, replace the inline `sourceURL: "https://mail.google.com/mail/u/0/#all/\(m.id)"`
  with `sourceURL: permalink(messageID: m.id)`.

- [ ] **Step 4:** In `RecommendationDetailView.gmailActions`, change the gate from
  `rec.source == SourceID.gmail.rawValue` to `GmailTriage.isGmailSourced(rec.sourceURL)` (keep the
  other two conditions: non-empty `rec.sourceEventID`, `gmail.state == .connected`).

- [ ] **Step 5:** `swift test --filter GmailTriageTests > /tmp/h4.log 2>&1; echo EXIT:$?` → 0;
  `swift build > /tmp/h4b.log 2>&1; echo EXIT:$?` → 0.
- [ ] **Step 6: Commit** `fix(gmail): gate card actions on the Gmail permalink, not logical source`

---

### Task H5: Cheap defense-in-depth (review notes)

**Files:** `Sources/MustardKit/Gmail/GmailService.swift`, `GmailParser.swift`,
`Sources/MustardKit/Views/RecommendationDetailView.swift`, `Sources/Mustard/MustardApp.swift`.

- [ ] **H5a — recipient in the send confirmation.** In `RecommendationDetailView`, the confirm
  dialog message should name who the reply goes to. Add a `@State private var sendRecipient = ""`;
  before showing the dialog, resolve and store the recipient. Simplest: add
  `GmailService.replyRecipient(forMessageID:) async -> String?` that fetches the original and returns
  `replyTo.isEmpty ? from : replyTo`; set `sendRecipient` in the button action before
  `confirmingSend = true`, and render `Text("Reply goes to \(sendRecipient). Sends on the original thread with the current draft.")`.
  If resolution fails, fall back to the current generic text. (Build-verified.)
- [ ] **H5b — ReDoS guard.** In `GmailParser.strippedHTML`, cap input before the regex passes:
  `let html = String(html.prefix(20_000))` at the top (add a param default or inline). Add a test
  `testStrippedHTMLHandlesLargeInput` that passes 100k chars and asserts it returns quickly and
  non-nil (behavioral, not timed).
- [ ] **H5c — bounded summary.** In `GmailService.poll`, cap raw claude text in the failure
  summary: `"Triage failed: \(String(result.text.prefix(200)))"`.
- [ ] **H5d — poll re-entrancy guard.** Add `private var isPolling = false` to GmailService; at the
  top of `poll`, `guard !isPolling else { return }; isPolling = true; defer { isPolling = false }`.
  (It's @MainActor, so this is a safe non-atomic guard.)
- [ ] **H5e — gate release in defer.** In `poll`, change the execution-gate usage so `release` runs
  via `defer` immediately after a successful `tryAcquire`, not a bare call after the claude await.
- [ ] **H5f — cadence survives restart.** In `MustardApp` scheduler's Gmail due-check, use the
  persisted stamp: `GmailSettings.isDue(lastPolledAt: GmailSyncStateStore.load().lastPolledAt, ...)`
  instead of `gmail.lastPolled`. Removes the dead-field confusion the reviewer flagged.
- [ ] **Verify:** `swift test > /tmp/h5.log 2>&1; echo EXIT:$?` → 0; `swift build` → 0.
- [ ] **Commit** `fix(gmail): defense-in-depth from deep-review notes`

---

### Task H6: Docs + full verification

- [ ] Update `docs/adr/0012-mustard-owned-gmail-inbox.md` Consequences: the triage run is now
  tool-restricted (deny exec/write/network/MCP, non-bypass mode) via `ClaudeRunner.restrictedRun`;
  the residual is that Read/Grep/Glob stay for grounding so a read secret could reach a local capped
  card field but never the network or an outward action; and the tool-restriction's precedence over a
  machine `bypassPermissions` default must be verified on the host before first activation.
- [ ] `swift test > /tmp/final.log 2>&1; echo EXIT:$?` → 0 (report count); `swift build` → 0;
  `./build-ios.sh > /tmp/ios.log 2>&1; echo EXIT:$?` → 0.
- [ ] Commit `docs(gmail): record the tool-restricted triage invocation in ADR-0012`
