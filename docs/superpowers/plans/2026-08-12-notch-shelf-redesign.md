# Notch Shelf Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the notch into a tabbed, pinnable command shelf (Today · Agent · Meetings · Clips · Shelf · custom collections) with Mustard-owned clipboard history, per spec `docs/superpowers/specs/2026-08-12-notch-shelf-redesign-design.md`.

**Architecture:** All decisions in pure `Logic/` units (TDD); capture/IO in a new `Sources/MustardKit/Clipboard/` service layer; SwiftData models `ClipItem`/`ClipCollection`; `NotchSurface.swift` decomposes into a shell + one file per tab. Paste-back reuses the dictation ⌘V machinery. The notch stays explicitly dark (never `Theme`).

**Tech Stack:** Swift 6.2 SPM (Swift-5 mode pin), SwiftUI + AppKit, SwiftData, Carbon hotkeys, XCTest.

**Conventions (read first):**
- Run tests with `swift test --filter <Suite>` and check the **exit code**, not output grep.
- Every commit message ends with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` (add it to every `git commit` below; omitted from the snippets for brevity).
- Date logic in tests pins `TimeZone(identifier: "UTC")` and injects `now:`.
- View code is verified by `swift build` + Leon's eye, never unit tests.
- Notch views use explicit dark hex (`Color(hex:)`), never `Theme`.

---

### Task 1: ClipKind + ClipClassifier (pure logic, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/ClipClassifier.swift`
- Test: `Tests/MustardTests/ClipClassifierTests.swift`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class ClipClassifierTests: XCTestCase {
    func testHexColorIsColor() {
        XCTAssertEqual(ClipClassifier.classify(text: "#2D7FF9"), .color)
        XCTAssertEqual(ClipClassifier.classify(text: "#fff"), .color)
        XCTAssertEqual(ClipClassifier.classify(text: "  #A1B2C3  "), .color)
    }

    func testRGBFunctionIsColor() {
        XCTAssertEqual(ClipClassifier.classify(text: "rgb(45, 127, 249)"), .color)
        XCTAssertEqual(ClipClassifier.classify(text: "rgba(45,127,249,0.5)"), .color)
    }

    func testHexLikeButInvalidIsText() {
        XCTAssertEqual(ClipClassifier.classify(text: "#GGGGGG"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "#12345"), .text)  // 5 digits
        XCTAssertEqual(ClipClassifier.classify(text: "#2D7FF9 is our accent"), .text)
    }

    func testHTTPURLIsLink() {
        XCTAssertEqual(ClipClassifier.classify(text: "https://www.supaste.com/"), .link)
        XCTAssertEqual(ClipClassifier.classify(text: "http://localhost:3000/x?y=1"), .link)
    }

    func testNonHTTPSchemesAndProseAreText() {
        XCTAssertEqual(ClipClassifier.classify(text: "ssh deploy@host"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "see https://a.com and https://b.com"), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "hello world"), .text)
    }

    func testEmptyAndWhitespaceIsText() {
        XCTAssertEqual(ClipClassifier.classify(text: ""), .text)
        XCTAssertEqual(ClipClassifier.classify(text: "   \n"), .text)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipClassifierTests`
Expected: compile FAILURE — `ClipClassifier` not defined.

- [x] **Step 3: Write minimal implementation**

```swift
import Foundation

/// What kind of thing a clip is. String-backed for SwiftData persistence.
/// `.image`/`.file`/`.dictation` are assigned by the capture path, never by
/// text classification.
public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, link, color, image, file, dictation
}

/// Pure text → kind classification for pasteboard string payloads.
public enum ClipClassifier {
    /// A whole-string hex color (#RGB, #RRGGBB) or rgb()/rgba() literal → .color;
    /// a single whole-string http(s) URL → .link; everything else → .text.
    public static func classify(text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }
        if isHexColor(trimmed) || isRGBFunction(trimmed) { return .color }
        if isSingleHTTPURL(trimmed) { return .link }
        return .text
    }

    private static func isHexColor(_ s: String) -> Bool {
        guard s.hasPrefix("#") else { return false }
        let digits = s.dropFirst()
        guard digits.count == 3 || digits.count == 6 else { return false }
        return digits.allSatisfy { $0.isHexDigit }
    }

    private static func isRGBFunction(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard lower.hasPrefix("rgb(") || lower.hasPrefix("rgba("), lower.hasSuffix(")") else {
            return false
        }
        let inner = lower.drop(while: { $0 != "(" }).dropFirst().dropLast()
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (3...4).contains(parts.count) && parts.allSatisfy { Double($0) != nil }
    }

    private static func isSingleHTTPURL(_ s: String) -> Bool {
        guard !s.contains(where: { $0.isWhitespace }),
              let url = URL(string: s),
              let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClipClassifierTests`
Expected: PASS (6 tests), exit 0.

- [x] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/ClipClassifier.swift Tests/MustardTests/ClipClassifierTests.swift
git commit -m "feat(clips): ClipKind + pure text classifier"
```

---

### Task 2: ClipItem + ClipCollection models, container registration

**Files:**
- Create: `Sources/MustardKit/Models/ClipItem.swift`
- Create: `Sources/MustardKit/Models/ClipCollection.swift`
- Modify: `Sources/MustardKit/MustardContainer.swift:13-16` (schema list)

Models are CloudKit-shaped like every other `@Model` (all fields optional or defaulted). No unit test of the models themselves — they're exercised through Task 4's store tests; this task just has to build.

- [x] **Step 1: Create ClipItem**

```swift
import Foundation
import SwiftData

/// One captured clipboard item (notch shelf spec §3–4). Clips are automatic
/// history; `pinnedToShelf` flips one into a deliberate keep. Filed items
/// (non-nil `collection`) and pinned items are exempt from pruning.
@Model
public final class ClipItem {
    public var uid: String = UUID().uuidString
    public var kindRaw: String = ClipKind.text.rawValue
    /// Text payload: the string itself, URL absoluteString, color literal,
    /// file path, or dictation transcript. Empty for image clips.
    public var payload: String = ""
    /// Downsampled preview for image clips (≤ 480 px long edge, JPEG).
    @Attribute(.externalStorage) public var thumbnailData: Data?
    /// Original image, only when ≤ 5 MB (spec §8); larger images keep just
    /// the thumbnail.
    @Attribute(.externalStorage) public var imageData: Data?
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var pinnedToShelf: Bool = false
    public var createdAt: Date = Date.now
    public var collection: ClipCollection?

    public init(kind: ClipKind = .text, payload: String = "") {
        self.kindRaw = kind.rawValue
        self.payload = payload
    }

    public var kind: ClipKind {
        get { ClipKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }
}
```

- [x] **Step 2: Create ClipCollection**

```swift
import Foundation
import SwiftData

/// A user-named bucket of clips (the Supaste "+" tabs: Prompts, Colors, …).
/// Deleting a collection unfiles its items (nullify), never deletes them.
@Model
public final class ClipCollection {
    public var uid: String = UUID().uuidString
    public var name: String = ""
    public var sortOrder: Int = 0
    public var createdAt: Date = Date.now
    @Relationship(deleteRule: .nullify, inverse: \ClipItem.collection)
    public var items: [ClipItem]? = []

    public init(name: String = "", sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
    }
}
```

- [x] **Step 3: Register in the container**

In `MustardContainer.make()`, extend the model list:

```swift
            let container = try ModelContainer(
                for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
                AgentRun.self, AgentMessage.self, AgentDraft.self, CalendarEvent.self, NoteIndexEntry.self,
                MeetingRecord.self, MeetingTranscriptSegment.self, MeetingActionProposal.self,
                ClipItem.self, ClipCollection.self,
                configurations: config
            )
```

- [x] **Step 4: Build and run the full suite**

Run: `swift build && swift test`
Expected: build succeeds, all existing tests pass (additive schema change), exit 0.

- [x] **Step 5: Commit**

```bash
git add Sources/MustardKit/Models/ClipItem.swift Sources/MustardKit/Models/ClipCollection.swift Sources/MustardKit/MustardContainer.swift
git commit -m "feat(clips): ClipItem/ClipCollection models, container registration"
```

---

### Task 3: ClipStoreRules (pure accept/dedupe/prune decisions, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/ClipStoreRules.swift`
- Test: `Tests/MustardTests/ClipStoreRulesTests.swift`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class ClipStoreRulesTests: XCTestCase {
    private func candidate(
        _ text: String = "hello", bundleID: String? = "com.apple.Safari",
        concealed: Bool = false, transient: Bool = false
    ) -> ClipCandidate {
        ClipCandidate(
            text: text, imageData: nil, fileURLs: [],
            sourceBundleID: bundleID, sourceAppName: "Safari",
            isConcealed: concealed, isTransient: transient)
    }

    func testAcceptsOrdinaryText() {
        XCTAssertTrue(ClipStoreRules.shouldCapture(candidate(), latestPayload: nil))
    }

    func testRejectsConcealedAndTransient() {
        XCTAssertFalse(ClipStoreRules.shouldCapture(candidate(concealed: true), latestPayload: nil))
        XCTAssertFalse(ClipStoreRules.shouldCapture(candidate(transient: true), latestPayload: nil))
    }

    func testRejectsExcludedBundles() {
        for bundle in ClipStoreRules.excludedBundleIDs {
            XCTAssertFalse(
                ClipStoreRules.shouldCapture(candidate(bundleID: bundle), latestPayload: nil),
                bundle)
        }
    }

    func testRejectsConsecutiveDuplicate() {
        XCTAssertFalse(ClipStoreRules.shouldCapture(candidate("same"), latestPayload: "same"))
        XCTAssertTrue(ClipStoreRules.shouldCapture(candidate("new"), latestPayload: "old"))
    }

    func testRejectsEmptyCandidate() {
        let empty = ClipCandidate(
            text: "   ", imageData: nil, fileURLs: [], sourceBundleID: nil,
            sourceAppName: nil, isConcealed: false, isTransient: false)
        XCTAssertFalse(ClipStoreRules.shouldCapture(empty, latestPayload: nil))
    }

    func testAcceptsImageOnlyCandidate() {
        let image = ClipCandidate(
            text: nil, imageData: Data([0xFF]), fileURLs: [], sourceBundleID: "com.figma.Desktop",
            sourceAppName: "Figma", isConcealed: false, isTransient: false)
        XCTAssertTrue(ClipStoreRules.shouldCapture(image, latestPayload: nil))
    }

    // MARK: prune

    private struct Row: ClipPrunable {
        let uid: String
        let createdAt: Date
        let pinnedToShelf: Bool
        let isFiled: Bool
    }

    private func rows(_ n: Int, pinned: Set<Int> = [], filed: Set<Int> = []) -> [Row] {
        (0..<n).map { i in
            Row(uid: "c\(i)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                pinnedToShelf: pinned.contains(i), isFiled: filed.contains(i))
        }
    }

    func testNoPruneUnderLimit() {
        XCTAssertEqual(ClipStoreRules.pruneUIDs(rows(200), limit: 200), [])
    }

    func testPrunesOldestUnpinnedBeyondLimit() {
        // 203 unpinned clips → the 3 oldest go.
        XCTAssertEqual(ClipStoreRules.pruneUIDs(rows(203), limit: 200), ["c0", "c1", "c2"])
    }

    func testPinnedAndFiledAreExemptAndDontCountTowardTheLimit() {
        // 202 clips, the two oldest pinned/filed: history size is 200 → no prune.
        XCTAssertEqual(
            ClipStoreRules.pruneUIDs(rows(202, pinned: [0], filed: [1]), limit: 200), [])
        // 203 with oldest pinned: prune skips it and takes the next-oldest.
        XCTAssertEqual(
            ClipStoreRules.pruneUIDs(rows(203, pinned: [0]), limit: 200), ["c1", "c2"])
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipStoreRulesTests`
Expected: compile FAILURE — `ClipCandidate`/`ClipStoreRules` not defined.

- [x] **Step 3: Write minimal implementation**

```swift
import Foundation

/// A pasteboard observation, already read off NSPasteboard by the monitor.
/// Pure value so accept/classify decisions are unit-testable.
public struct ClipCandidate: Equatable, Sendable {
    public var text: String?
    public var imageData: Data?
    public var fileURLs: [URL]
    public var sourceBundleID: String?
    public var sourceAppName: String?
    /// org.nspasteboard.ConcealedType or AutoGeneratedType present.
    public var isConcealed: Bool
    /// org.nspasteboard.TransientType present.
    public var isTransient: Bool

    public init(
        text: String?, imageData: Data?, fileURLs: [URL], sourceBundleID: String?,
        sourceAppName: String?, isConcealed: Bool, isTransient: Bool
    ) {
        self.text = text
        self.imageData = imageData
        self.fileURLs = fileURLs
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.isConcealed = isConcealed
        self.isTransient = isTransient
    }
}

/// Minimal shape `pruneUIDs` needs, so the rule tests need no SwiftData.
public protocol ClipPrunable {
    var uid: String { get }
    var createdAt: Date { get }
    var pinnedToShelf: Bool { get }
    var isFiled: Bool { get }
}

/// Pure capture/retention policy for the clipboard layer (spec §3–4).
public enum ClipStoreRules {
    /// Rolling history size (unpinned, unfiled clips only).
    public static let historyLimit = 200

    /// Bundle IDs whose copies are never recorded. Constants for now
    /// (editable config is out of scope per spec §7).
    public static let excludedBundleIDs: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    public static func shouldCapture(_ candidate: ClipCandidate, latestPayload: String?) -> Bool {
        if candidate.isConcealed || candidate.isTransient { return false }
        if let bundle = candidate.sourceBundleID, excludedBundleIDs.contains(bundle) {
            return false
        }
        let trimmed = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasContent = !trimmed.isEmpty || candidate.imageData != nil
            || !candidate.fileURLs.isEmpty
        guard hasContent else { return false }
        if !trimmed.isEmpty, trimmed == latestPayload { return false }
        return true
    }

    /// UIDs to delete: oldest unpinned/unfiled clips beyond `limit`.
    public static func pruneUIDs(_ clips: [any ClipPrunable], limit: Int = historyLimit) -> [String] {
        let history = clips
            .filter { !$0.pinnedToShelf && !$0.isFiled }
            .sorted { $0.createdAt < $1.createdAt }
        let overflow = history.count - limit
        guard overflow > 0 else { return [] }
        return history.prefix(overflow).map(\.uid)
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClipStoreRulesTests`
Expected: PASS (9 tests), exit 0.

- [x] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/ClipStoreRules.swift Tests/MustardTests/ClipStoreRulesTests.swift
git commit -m "feat(clips): pure capture/dedupe/prune rules"
```

---

### Task 4: ClipStore (SwiftData application of the rules)

**Files:**
- Create: `Sources/MustardKit/Clipboard/ClipStore.swift`
- Test: `Tests/MustardTests/ClipStoreTests.swift`

- [x] **Step 1: Write the failing test** (in-memory container, same pattern as existing store tests)

```swift
import XCTest
import SwiftData
@testable import MustardKit

@MainActor
final class ClipStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ClipItem.self, ClipCollection.self, configurations: config)
        return ModelContext(container)
    }

    private func candidate(_ text: String, bundle: String = "com.apple.Safari") -> ClipCandidate {
        ClipCandidate(
            text: text, imageData: nil, fileURLs: [], sourceBundleID: bundle,
            sourceAppName: "Safari", isConcealed: false, isTransient: false)
    }

    func testIngestInsertsClassifiedClip() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.ingest(candidate("https://supaste.com"))
        let clips = try context.fetch(FetchDescriptor<ClipItem>())
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].kind, .link)
        XCTAssertEqual(clips[0].payload, "https://supaste.com")
        XCTAssertEqual(clips[0].sourceAppName, "Safari")
    }

    func testIngestSkipsConsecutiveDuplicate() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.ingest(candidate("same"))
        store.ingest(candidate("same"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<ClipItem>()).count, 1)
    }

    func testIngestPrunesOldestBeyondLimit() throws {
        let context = try makeContext()
        let store = ClipStore(context: context, historyLimit: 3)
        for i in 0..<5 { store.ingest(candidate("item \(i)")) }
        let clips = try context.fetch(FetchDescriptor<ClipItem>())
            .sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(clips.map(\.payload), ["item 2", "item 3", "item 4"])
    }

    func testPinnedSurvivesPrune() throws {
        let context = try makeContext()
        let store = ClipStore(context: context, historyLimit: 2)
        store.ingest(candidate("keep me"))
        let first = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        first.pinnedToShelf = true
        for i in 0..<4 { store.ingest(candidate("item \(i)")) }
        let payloads = try context.fetch(FetchDescriptor<ClipItem>()).map(\.payload)
        XCTAssertTrue(payloads.contains("keep me"))
        XCTAssertEqual(payloads.count, 3)  // pinned + 2 history
    }

    func testAddDictation() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.addDictation(transcript: "note to self")
        let clip = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        XCTAssertEqual(clip.kind, .dictation)
        XCTAssertEqual(clip.payload, "note to self")
        XCTAssertEqual(clip.sourceAppName, "Dictation")
    }

    func testAddShelfDropString() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.addShelfDrop(text: "dropped words")
        let clip = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        XCTAssertTrue(clip.pinnedToShelf)
        XCTAssertEqual(clip.kind, .text)
    }

    func testAddShelfDropFile() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.addShelfDrop(fileURL: URL(fileURLWithPath: "/tmp/report.pdf"))
        let clip = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        XCTAssertTrue(clip.pinnedToShelf)
        XCTAssertEqual(clip.kind, .file)
        XCTAssertEqual(clip.payload, "/tmp/report.pdf")
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipStoreTests`
Expected: compile FAILURE — `ClipStore` not defined.

- [x] **Step 3: Write minimal implementation**

`ClipItem` needs `isFiled` for the prune protocol — add to `ClipItem.swift`:

```swift
extension ClipItem: ClipPrunable {
    public var isFiled: Bool { collection != nil }
}
```

Then the store:

```swift
import Foundation
import SwiftData

/// Applies `ClipStoreRules` to candidates and writes results into SwiftData.
/// No decisions live here beyond fetch/insert/delete plumbing.
@MainActor
public final class ClipStore {
    private let context: ModelContext
    private let historyLimit: Int

    public init(context: ModelContext, historyLimit: Int = ClipStoreRules.historyLimit) {
        self.context = context
        self.historyLimit = historyLimit
    }

    private var latest: ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [.init(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Pasteboard observation → maybe a stored clip + prune.
    public func ingest(_ candidate: ClipCandidate) {
        guard ClipStoreRules.shouldCapture(candidate, latestPayload: latest?.payload) else {
            return
        }
        let trimmed = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clip: ClipItem
        if let fileURL = candidate.fileURLs.first {
            clip = ClipItem(kind: .file, payload: fileURL.path)
        } else if let image = candidate.imageData {
            clip = ClipItem(kind: .image, payload: "")
            store(imageData: image, on: clip)
        } else {
            clip = ClipItem(kind: ClipClassifier.classify(text: trimmed), payload: trimmed)
        }
        clip.sourceBundleID = candidate.sourceBundleID
        clip.sourceAppName = candidate.sourceAppName
        context.insert(clip)
        prune()
        try? context.save()
    }

    public func addDictation(transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clip = ClipItem(kind: .dictation, payload: trimmed)
        clip.sourceAppName = "Dictation"
        context.insert(clip)
        prune()
        try? context.save()
    }

    public func addShelfDrop(text: String) {
        let clip = ClipItem(kind: ClipClassifier.classify(text: text), payload: text)
        clip.pinnedToShelf = true
        context.insert(clip)
        try? context.save()
    }

    public func addShelfDrop(fileURL: URL) {
        let clip = ClipItem(kind: .file, payload: fileURL.path)
        clip.pinnedToShelf = true
        context.insert(clip)
        try? context.save()
    }

    public func addShelfDrop(imageData: Data) {
        let clip = ClipItem(kind: .image, payload: "")
        store(imageData: imageData, on: clip)
        clip.pinnedToShelf = true
        context.insert(clip)
        try? context.save()
    }

    /// Spec §8: originals only up to 5 MB; always a ≤480 px JPEG thumbnail.
    private func store(imageData: Data, on clip: ClipItem) {
        if imageData.count <= 5 * 1024 * 1024 { clip.imageData = imageData }
        clip.thumbnailData = ClipThumbnail.jpegThumbnail(from: imageData, maxEdge: 480)
    }

    private func prune() {
        let all = (try? context.fetch(FetchDescriptor<ClipItem>())) ?? []
        let doomed = Set(ClipStoreRules.pruneUIDs(all, limit: historyLimit))
        guard !doomed.isEmpty else { return }
        for clip in all where doomed.contains(clip.uid) {
            context.delete(clip)
        }
    }
}
```

And the tiny AppKit thumbnail helper in the same file (macOS-only, not unit-tested — image codec territory):

```swift
#if os(macOS)
import AppKit

enum ClipThumbnail {
    static func jpegThumbnail(from data: Data, maxEdge: CGFloat) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
#endif
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClipStoreTests`
Expected: PASS (7 tests), exit 0.

- [x] **Step 5: Commit**

```bash
git add Sources/MustardKit/Clipboard/ClipStore.swift Sources/MustardKit/Models/ClipItem.swift Tests/MustardTests/ClipStoreTests.swift
git commit -m "feat(clips): ClipStore — rules applied to SwiftData, image caps"
```

---

### Task 5: ClipboardMonitor (pasteboard polling behind a protocol)

**Files:**
- Create: `Sources/MustardKit/Clipboard/ClipboardMonitor.swift`
- Test: `Tests/MustardTests/ClipboardMonitorTests.swift`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    private final class FakePasteboard: PasteboardReading {
        var changeCount = 0
        var candidateToReturn: ClipCandidate?
        var readCount = 0
        func readCandidate() -> ClipCandidate? {
            readCount += 1
            return candidateToReturn
        }
    }

    private func textCandidate(_ text: String) -> ClipCandidate {
        ClipCandidate(
            text: text, imageData: nil, fileURLs: [], sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari", isConcealed: false, isTransient: false)
    }

    func testEmitsOnChangeCountBump() {
        let pasteboard = FakePasteboard()
        var received: [ClipCandidate] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { received.append($0) }
        pasteboard.candidateToReturn = textCandidate("hi")

        monitor.pollOnce()   // baseline established at init: changeCount 0 → no emit
        XCTAssertTrue(received.isEmpty)

        pasteboard.changeCount = 1
        monitor.pollOnce()
        XCTAssertEqual(received.map(\.text), ["hi"])
    }

    func testNoReadWhenChangeCountIsStable() {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { _ in }
        monitor.pollOnce()
        monitor.pollOnce()
        XCTAssertEqual(pasteboard.readCount, 0)
    }

    func testOwnWriteIsSkippedOnce() {
        let pasteboard = FakePasteboard()
        var received: [ClipCandidate] = []
        let monitor = ClipboardMonitor(pasteboard: pasteboard) { received.append($0) }
        pasteboard.candidateToReturn = textCandidate("copied from notch")

        pasteboard.changeCount = 1
        monitor.expectOwnWrite(changeCount: 1)  // notch copy button announces itself
        monitor.pollOnce()
        XCTAssertTrue(received.isEmpty)

        pasteboard.changeCount = 2              // a real copy afterwards still lands
        pasteboard.candidateToReturn = textCandidate("real copy")
        monitor.pollOnce()
        XCTAssertEqual(received.map(\.text), ["real copy"])
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClipboardMonitorTests`
Expected: compile FAILURE — `PasteboardReading`/`ClipboardMonitor` not defined.

- [x] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The slice of NSPasteboard the monitor needs, injectable for tests.
@MainActor
public protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    /// Read the current pasteboard contents as a candidate (nil = unreadable).
    func readCandidate() -> ClipCandidate?
}

/// Watches the general pasteboard by polling `changeCount` (~1 s — the only
/// supported mechanism; Supaste/Helm norm). Emits candidates; all accept/skip
/// decisions live in `ClipStoreRules` downstream. Never blocks the main actor:
/// each poll is one changeCount compare, and reads happen only on change.
@MainActor
public final class ClipboardMonitor {
    private let pasteboard: PasteboardReading
    private let onCandidate: (ClipCandidate) -> Void
    private var lastChangeCount: Int
    private var ownWriteChangeCounts: Set<Int> = []
    private var timer: Timer?

    public init(pasteboard: PasteboardReading, onCandidate: @escaping (ClipCandidate) -> Void) {
        self.pasteboard = pasteboard
        self.onCandidate = onCandidate
        self.lastChangeCount = pasteboard.changeCount
    }

    /// The notch's own copy button writes the pasteboard; that write must not
    /// re-enter history. Call with the changeCount observed after writing.
    public func expectOwnWrite(changeCount: Int) {
        ownWriteChangeCounts.insert(changeCount)
    }

    public func start(interval: TimeInterval = 1.0) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollOnce() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func pollOnce() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if ownWriteChangeCounts.remove(count) != nil { return }
        guard let candidate = pasteboard.readCandidate() else { return }
        onCandidate(candidate)
    }
}
```

And the live pasteboard adapter (macOS-only, thin, eye-verified) in the same file:

```swift
#if os(macOS)
import AppKit

/// Live NSPasteboard adapter. Reads string/image/file-URL representations
/// and flags nspasteboard.org marker types so the rules can skip them.
@MainActor
public final class LivePasteboard: PasteboardReading {
    private let board = NSPasteboard.general
    public init() {}

    public var changeCount: Int { board.changeCount }

    public func readCandidate() -> ClipCandidate? {
        let types = board.types ?? []
        let concealed = types.contains(.init("org.nspasteboard.ConcealedType"))
            || types.contains(.init("org.nspasteboard.AutoGeneratedType"))
        let transient = types.contains(.init("org.nspasteboard.TransientType"))
        let fileURLs = (board.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let text = board.string(forType: .string)
        let imageData = fileURLs.isEmpty && text == nil
            ? (board.data(forType: .png) ?? board.data(forType: .tiff)) : nil
        let source = NSWorkspace.shared.frontmostApplication
        return ClipCandidate(
            text: text, imageData: imageData, fileURLs: fileURLs,
            sourceBundleID: source?.bundleIdentifier,
            sourceAppName: source?.localizedName,
            isConcealed: concealed, isTransient: transient)
    }
}
#endif
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClipboardMonitorTests`
Expected: PASS (3 tests), exit 0.

- [x] **Step 5: Commit**

```bash
git add Sources/MustardKit/Clipboard/ClipboardMonitor.swift Tests/MustardTests/ClipboardMonitorTests.swift
git commit -m "feat(clips): changeCount-polling clipboard monitor, own-write skip"
```

---

### Task 6: NotchPinState (hover/pin state machine, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/NotchPinState.swift`
- Test: `Tests/MustardTests/NotchPinStateTests.swift`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class NotchPinStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func t(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testStartsCollapsed() {
        let state = NotchPinState()
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isPinned)
    }

    func testHoverPeeksAndExitCollapsesAfterGrace() {
        var state = NotchPinState()
        state.hoverChanged(isInside: true, now: t0)
        XCTAssertTrue(state.isExpanded)

        state.hoverChanged(isInside: false, now: t(1))
        // Still expanded during the grace window.
        XCTAssertTrue(state.isExpanded)
        XCTAssertFalse(state.shouldCollapse(now: t(1.1)))
        XCTAssertTrue(state.shouldCollapse(now: t(1.4)))

        state.collapseIfDue(now: t(1.4))
        XCTAssertFalse(state.isExpanded)
    }

    func testReenterDuringGraceCancelsCollapse() {
        var state = NotchPinState()
        state.hoverChanged(isInside: true, now: t0)
        state.hoverChanged(isInside: false, now: t(1))
        state.hoverChanged(isInside: true, now: t(1.2))
        XCTAssertFalse(state.shouldCollapse(now: t(5)))
        XCTAssertTrue(state.isExpanded)
    }

    func testClickPinsAndHoverExitNoLongerCollapses() {
        var state = NotchPinState()
        state.pin()
        XCTAssertTrue(state.isExpanded)
        XCTAssertTrue(state.isPinned)
        state.hoverChanged(isInside: false, now: t(1))
        XCTAssertFalse(state.shouldCollapse(now: t(10)))
        XCTAssertTrue(state.isExpanded)
    }

    func testUnpinCollapsesImmediately() {
        var state = NotchPinState()
        state.pin()
        state.unpin()
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isPinned)
    }

    func testUnpinWhileHoveringStaysPeeked() {
        var state = NotchPinState()
        state.hoverChanged(isInside: true, now: t0)
        state.pin()
        state.unpin()
        XCTAssertTrue(state.isExpanded)   // pointer is still inside
        XCTAssertFalse(state.isPinned)
    }

    func testCollapseIfDueIsNoopWhilePinnedOrHovering() {
        var state = NotchPinState()
        state.hoverChanged(isInside: true, now: t0)
        state.collapseIfDue(now: t(10))
        XCTAssertTrue(state.isExpanded)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter NotchPinStateTests`
Expected: compile FAILURE — `NotchPinState` not defined.

- [x] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Pure hover/pin state for the notch panel (spec §2: hover peeks with a
/// collapse grace period; click/hotkey pins; Esc/click-away unpins).
/// The controller feeds events and polls `shouldCollapse` on a short timer;
/// all timing decisions live here with injected clocks.
public struct NotchPinState: Equatable {
    /// How long the panel survives a pointer exit before collapsing.
    public static let collapseGrace: TimeInterval = 0.3

    public private(set) var isPinned = false
    private var isHovering = false
    private var hoverExitedAt: Date?
    private var isPeeked = false

    public init() {}

    public var isExpanded: Bool { isPinned || isPeeked }

    public mutating func hoverChanged(isInside: Bool, now: Date) {
        isHovering = isInside
        if isInside {
            isPeeked = true
            hoverExitedAt = nil
        } else {
            hoverExitedAt = now
        }
    }

    public mutating func pin() {
        isPinned = true
    }

    /// Esc / click-away. Keeps the peek only while the pointer is inside.
    public mutating func unpin() {
        isPinned = false
        if !isHovering {
            isPeeked = false
            hoverExitedAt = nil
        }
    }

    public func shouldCollapse(now: Date) -> Bool {
        guard !isPinned, isPeeked, !isHovering, let exitedAt = hoverExitedAt else {
            return false
        }
        return now.timeIntervalSince(exitedAt) >= Self.collapseGrace
    }

    public mutating func collapseIfDue(now: Date) {
        guard shouldCollapse(now: now) else { return }
        isPeeked = false
        hoverExitedAt = nil
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter NotchPinStateTests`
Expected: PASS (7 tests), exit 0.

- [x] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/NotchPinState.swift Tests/MustardTests/NotchPinStateTests.swift
git commit -m "feat(notch): pure hover/pin state machine with collapse grace"
```

---

### Task 7: NotchTabModel + NotchPanelMetrics (tabs, counts, sizes, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/NotchTabModel.swift`
- Test: `Tests/MustardTests/NotchTabModelTests.swift`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class NotchTabModelTests: XCTestCase {
    func testFixedTabsInOrderThenCollections() {
        let tabs = NotchTabModel.tabs(collectionNames: ["Prompts", "Colors"])
        XCTAssertEqual(tabs, [
            .today, .agent, .meetings, .clips, .shelf,
            .collection(name: "Prompts"), .collection(name: "Colors"),
        ])
    }

    func testDefaultTabIsTodayUnlessRecording() {
        XCTAssertEqual(NotchTabModel.defaultTab(recordingActive: false), .today)
        XCTAssertEqual(NotchTabModel.defaultTab(recordingActive: true), .meetings)
    }

    func testHotkeyLandsOnClips() {
        XCTAssertEqual(NotchTabModel.clipsHotKeyTab, .clips)
    }

    func testTabTitles() {
        XCTAssertEqual(NotchTab.today.title, "Today")
        XCTAssertEqual(NotchTab.collection(name: "Prompts").title, "Prompts")
    }

    func testExpandedSizes() {
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .today), .init(width: 480, height: 500))
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .agent), .init(width: 480, height: 500))
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .meetings), .init(width: 480, height: 520))
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .clips), .init(width: 480, height: 560))
        XCTAssertEqual(NotchPanelMetrics.expandedSize(for: .shelf), .init(width: 480, height: 560))
        XCTAssertEqual(
            NotchPanelMetrics.expandedSize(for: .collection(name: "x")),
            .init(width: 480, height: 560))
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter NotchTabModelTests`
Expected: compile FAILURE — `NotchTab` not defined.

- [x] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One pill in the notch's tab row.
public enum NotchTab: Equatable, Hashable, Sendable {
    case today, agent, meetings, clips, shelf
    case collection(name: String)

    public var title: String {
        switch self {
        case .today: return "Today"
        case .agent: return "Agent"
        case .meetings: return "Meetings"
        case .clips: return "Clips"
        case .shelf: return "Shelf"
        case .collection(let name): return name
        }
    }
}

/// Pure tab-row composition and landing decisions (spec §2).
public enum NotchTabModel {
    public static func tabs(collectionNames: [String]) -> [NotchTab] {
        [.today, .agent, .meetings, .clips, .shelf]
            + collectionNames.map { NotchTab.collection(name: $0) }
    }

    /// Where the panel opens: Meetings while a recording is live/preparing,
    /// Today otherwise.
    public static func defaultTab(recordingActive: Bool) -> NotchTab {
        recordingActive ? .meetings : .today
    }

    /// ⌃⌥V lands here with search focused.
    public static let clipsHotKeyTab: NotchTab = .clips
}

/// Per-tab expanded panel sizes: fixed, testable, capped well under any
/// screen. Grid tabs get more height than list tabs.
public enum NotchPanelMetrics {
    public struct Size: Equatable {
        public let width: Double
        public let height: Double
        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public static func expandedSize(for tab: NotchTab) -> Size {
        switch tab {
        case .today, .agent: return Size(width: 480, height: 500)
        case .meetings: return Size(width: 480, height: 520)
        case .clips, .shelf, .collection: return Size(width: 480, height: 560)
        }
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter NotchTabModelTests`
Expected: PASS (5 tests), exit 0.

- [x] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/NotchTabModel.swift Tests/MustardTests/NotchTabModelTests.swift
git commit -m "feat(notch): tab model, default-tab rules, panel metrics"
```

---

### Task 8: NotchSearch (fuzzy filter over the clipboard layer, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/NotchSearch.swift`
- Test: `Tests/MustardTests/NotchSearchTests.swift`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

final class NotchSearchTests: XCTestCase {
    private struct Row: NotchSearchable {
        let uid: String
        let searchText: String
    }

    private let rows = [
        Row(uid: "1", searchText: "https://supaste.com Safari"),
        Row(uid: "2", searchText: "ssh deploy@prod Terminal"),
        Row(uid: "3", searchText: "Design review notes Dictation"),
        Row(uid: "4", searchText: "#2D7FF9 Figma"),
    ]

    func testEmptyQueryReturnsEverythingInOrder() {
        XCTAssertEqual(NotchSearch.filter(rows, query: "").map(\.uid), ["1", "2", "3", "4"])
        XCTAssertEqual(NotchSearch.filter(rows, query: "  ").map(\.uid), ["1", "2", "3", "4"])
    }

    func testSubstringMatchesCaseInsensitive() {
        XCTAssertEqual(NotchSearch.filter(rows, query: "SUPASTE").map(\.uid), ["1"])
        XCTAssertEqual(NotchSearch.filter(rows, query: "deploy").map(\.uid), ["2"])
    }

    func testSubsequenceMatches() {
        // "dsgnrv" is a subsequence of "Design review".
        XCTAssertEqual(NotchSearch.filter(rows, query: "dsgnrv").map(\.uid), ["3"])
    }

    func testSubstringRanksAboveSubsequence() {
        let mixed = [
            Row(uid: "sub", searchText: "abcdef"),      // subsequence match for "ace"
            Row(uid: "exact", searchText: "an ace card"),  // substring match for "ace"
        ]
        XCTAssertEqual(NotchSearch.filter(mixed, query: "ace").map(\.uid), ["exact", "sub"])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(NotchSearch.filter(rows, query: "zzzz").isEmpty)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter NotchSearchTests`
Expected: compile FAILURE — `NotchSearchable` not defined.

- [x] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Anything the notch search box can filter (clips, shelf items, collection
/// contents). `searchText` is a pre-joined haystack: payload + app name + kind.
public protocol NotchSearchable {
    var uid: String { get }
    var searchText: String { get }
}

/// Case-insensitive fuzzy filter: substring hits rank first, then in-order
/// subsequence hits. Stable within each band (preserves input order, which
/// is newest-first at the call sites).
public enum NotchSearch {
    public static func filter<T: NotchSearchable>(_ items: [T], query: String) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        var substrings: [T] = []
        var subsequences: [T] = []
        for item in items {
            let haystack = item.searchText.lowercased()
            if haystack.contains(q) {
                substrings.append(item)
            } else if isSubsequence(q, of: haystack) {
                subsequences.append(item)
            }
        }
        return substrings + subsequences
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = needle.startIndex
        for char in haystack {
            guard index < needle.endIndex else { return true }
            if char == needle[index] { index = needle.index(after: index) }
        }
        return index == needle.endIndex
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter NotchSearchTests`
Expected: PASS (5 tests), exit 0.

- [x] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/NotchSearch.swift Tests/MustardTests/NotchSearchTests.swift
git commit -m "feat(notch): fuzzy search over the clipboard layer"
```

---

### Task 9: NotchController — pinning, per-tab size, screen observer

**Files:**
- Modify: `Sources/MustardKit/Views/NotchSurface.swift:11-109` (`NotchController` only)

View-layer wiring around the tested `NotchPinState`; verified by build + eye. The controller changes:

- [x] **Step 1: Rework NotchController**

Replace the `NotchController` class body (keep the file header comment) with:

```swift
@MainActor
public final class NotchController {
    private var panel: NSPanel?
    private let makeContent: (_ controller: NotchController) -> AnyView

    /// Tested state machine; the controller only feeds it events.
    private var pinState = NotchPinState()
    private var graceTimer: Timer?
    private var clickOutsideMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    /// The active tab drives the expanded frame (NotchPanelMetrics).
    public private(set) var activeTab: NotchTab = .today

    /// Set by the shell view so pin/tab changes re-render.
    public var onStateChange: (() -> Void)?

    public init(content: @escaping (_ controller: NotchController) -> AnyView) {
        self.makeContent = content
    }

    public var isVisible: Bool { panel?.isVisible ?? false }
    public var isPinned: Bool { pinState.isPinned }
    public var isExpanded: Bool { pinState.isExpanded }

    private var screen: NSScreen? {
        let screens = NSScreen.screens
        let descriptors = screens.enumerated().map { index, screen in
            NotchScreenDescriptor(
                id: index,
                hasNotch: screen.safeAreaInsets.top > 0,
                isMain: screen == NSScreen.main
            )
        }
        guard let chosen = NotchScreenPicker.choose(from: descriptors),
              let index = chosen.id as? Int else { return NSScreen.main }
        return screens[index]
    }

    private func idleFrame(on screen: NSScreen) -> NSRect {
        // unchanged from today
        let frame = screen.frame
        let notchHeight = screen.safeAreaInsets.top
        let width: CGFloat
        let height: CGFloat
        if notchHeight > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = frame.width - left.width - right.width + 24
            height = notchHeight + 20
        } else {
            width = 230
            height = 30
        }
        return NSRect(
            x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height
        )
    }

    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let size = NotchPanelMetrics.expandedSize(for: activeTab)
        let frame = screen.frame
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    public func toggle() {
        if let panel, panel.isVisible {
            if pinState.isPinned { unpin() }
            panel.orderOut(nil)
            return
        }
        show()
        pin()
    }

    public func show() {
        guard let screen else { return }
        if panel == nil {
            let panel = NSPanel(
                contentRect: idleFrame(on: screen),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.contentView = NSHostingView(rootView: makeContent(self))
            self.panel = panel
            // Spec §3 fix: follow display connect/disconnect (previously the
            // panel only re-resolved its screen on the next show()/hover).
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyFrame() }
            }
        }
        applyFrame()
        panel?.orderFrontRegardless()
    }

    // MARK: events from the shell view

    public func hoverChanged(_ isInside: Bool) {
        pinState.hoverChanged(isInside: isInside, now: .now)
        applyFrame()
        if !isInside { armGraceTimer() }
        onStateChange?()
    }

    public func pin() {
        pinState.pin()
        applyFrame()
        installClickOutsideMonitor()
        onStateChange?()
    }

    public func unpin() {
        pinState.unpin()
        applyFrame()
        removeClickOutsideMonitor()
        onStateChange?()
    }

    public func select(tab: NotchTab) {
        activeTab = tab
        applyFrame()
        onStateChange?()
    }

    /// ⌘⇧N / ⌃⌥V entry: open pinned on a specific tab.
    public func openPinned(on tab: NotchTab) {
        show()
        activeTab = tab
        pin()
    }

    // MARK: internals

    private func armGraceTimer() {
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(
            withTimeInterval: NotchPinState.collapseGrace + 0.05, repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pinState.collapseIfDue(now: .now)
                self.applyFrame()
                self.onStateChange?()
            }
        }
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pinState.isPinned else { return }
                // A global monitor only fires for clicks in OTHER apps/windows;
                // clicks inside the panel never reach it.
                self.unpin()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        clickOutsideMonitor = nil
    }

    private func applyFrame() {
        guard let panel, let screen else { return }
        let expanded = pinState.isExpanded
        panel.hasShadow = expanded
        panel.setFrame(
            expanded ? expandedFrame(on: screen) : idleFrame(on: screen),
            display: true, animate: true)
    }
}
```

Note the `makeContent` signature change (`(NotchController) -> AnyView`): the shell view needs the controller for pin/tab/hover callbacks. `MustardApp` is updated in Task 16; to keep this task building, update the call site now to pass the controller (the view still only uses `onHoverChange` until Task 10):

```swift
                        let controller = NotchController { controller in
                            AnyView(
                                NotchView(controller: controller)
                                    .environment(agent)
                                    ...same environment as today...
                            )
                        }
```

and in `NotchView` replace `let onHoverChange: (Bool) -> Void` + init with:

```swift
    /// Weak-ish handle for pin/tab/hover events; the controller outlives the view.
    let controller: NotchController?

    public init(controller: NotchController? = nil) {
        self.controller = controller
    }
```

and `.onHover { isIn in withAnimation(...) { hovering = isIn }; controller?.hoverChanged(isIn) }`.

Also update `Sources/MustardKit/PreviewData.swift` / any `#Preview` using `NotchView(onHoverChange:)` to `NotchView()`.

- [x] **Step 2: Build + full suite**

Run: `swift build && swift test`
Expected: build succeeds, suite green, exit 0.

- [x] **Step 3: Commit**

```bash
git add Sources/MustardKit/Views/NotchSurface.swift Sources/Mustard/MustardApp.swift Sources/MustardKit/PreviewData.swift
git commit -m "feat(notch): click-to-pin, collapse grace, per-tab size, screen observer"
```

---

### Task 10: Shell refactor — header, tab pills, banner slot, Today tab

**Files:**
- Modify: `Sources/MustardKit/Views/NotchSurface.swift` (NotchView becomes the shell; AgendaRow stays)
- Create: `Sources/MustardKit/Views/NotchTodayTab.swift`
- Modify: `Sources/MustardKit/Views/MeetingRecordingNotchView.swift` (remove `MeetingStartPromptView()` from the `.idle` case — the shell's banner slot owns it now)

All view work: `swift build` + eye. Structure:

- [x] **Step 1: Extract Today tab**

`NotchTodayTab.swift` — move `agendaSection`, `AgendaRow` helpers usage, ritual gating, progress capsule from the old `expandedContent` (drop the triage card — it moves to the Agent tab in Task 11; drop `MeetingRecordingNotchView` — it moves to Meetings in Task 12):

```swift
#if os(macOS)
import SwiftUI
import SwiftData

/// Today tab: agenda + progress + empty state. Explicit dark hex (notch
/// exception) — never Theme. Renders and dispatches only.
struct NotchTodayTab: View {
    @Environment(\.modelContext) private var context
    @Environment(NotchNavigation.self) private var nav
    @Query private var tasks: [MustardTask]
    @Query(sort: \CalendarEvent.start) private var events: [CalendarEvent]

    private var todayAgenda: [AgendaItem] {
        DayPlanner.agenda(tasks: tasks, events: events, day: .now)
    }
    private var todayProgress: (done: Int, total: Int) {
        DayPlanner.dayProgress(tasks, day: .now)
    }

    private func toggleDone(_ task: MustardTask) {
        if task.stage == .done {
            task.stage = .planned
            task.completedAt = nil
        } else {
            TaskCompletion.complete(task, in: context)
        }
    }

    private func openDetail(_ item: AgendaItem) {
        if case .task(let task) = item.kind { nav.pendingTask = task }
    }

    var body: some View {
        // …the existing agendaSection body from NotchSurface.swift:331-373,
        // verbatim, with AgendaRow unchanged…
    }
}
#endif
```

(Move `AgendaRow` into this file too — it has no other consumers.)

- [x] **Step 2: Rebuild NotchView as the shell**

In `NotchSurface.swift`, `expandedContent` becomes:

```swift
    @State private var searchQuery = ""
    @State private var showPinnedOnly = false
    @State private var activeTab: NotchTab = .today
    @Query(sort: \ClipCollection.sortOrder) private var collections: [ClipCollection]
    @Query private var clips: [ClipItem]
    @Environment(MeetingCaptureCoordinator.self) private var meetingRecorder: MeetingCaptureCoordinator?

    private var recordingActive: Bool {
        switch meetingRecorder?.state {
        case .recording, .preparing, .paused: return true
        default: return false
        }
    }

    private var tabs: [NotchTab] {
        NotchTabModel.tabs(collectionNames: collections.map(\.name))
    }

    private func count(for tab: NotchTab) -> Int? {
        switch tab {
        case .today:
            let p = DayPlanner.dayProgress(tasks, day: .now)
            return p.total - p.done > 0 ? p.total - p.done : nil
        case .agent: return waitingCount > 0 ? waitingCount : nil
        case .meetings: return nil
        case .clips: return clips.filter { !$0.pinnedToShelf && $0.collection == nil }.count
        case .shelf: return clips.filter(\.pinnedToShelf).count
        case .collection(let name):
            return collections.first { $0.name == name }?.items?.count
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 30)
            headerRow
            // Banner slot: the meeting suggestion is visible from any tab
            // (spec §2) and routes through the same consent path.
            MeetingStartPromptView()
            tabPills
            tabContent
            Spacer(minLength: 0)
            captureBar
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            activeTab = NotchTabModel.defaultTab(recordingActive: recordingActive)
            controller?.select(tab: activeTab)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            Spacer()
            Button { showPinnedOnly.toggle() } label: {
                Image(systemName: showPinnedOnly ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(showPinnedOnly ? 0.9 : 0.55))
            }.buttonStyle(.plain)
            Button {
                if controller?.isPinned == true { controller?.unpin() } else { controller?.pin() }
            } label: {
                Image(systemName: controller?.isPinned == true ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(controller?.isPinned == true ? 0.9 : 0.55))
            }.buttonStyle(.plain)
            Button { nav.openAgentConsole = false; nav.pendingTask = nil; NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }.buttonStyle(.plain)
        }
    }

    private var tabPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.self) { tab in
                    let selected = tab == activeTab
                    Button {
                        activeTab = tab
                        controller?.select(tab: tab)
                    } label: {
                        HStack(spacing: 4) {
                            if tab == .meetings && recordingActive {
                                Circle().fill(Color(hex: "#FF5F57")).frame(width: 5, height: 5)
                            }
                            Text(tab.title)
                            if let n = count(for: tab) {
                                Text("\(n)").opacity(0.5)
                            }
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(selected ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(
                            selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.08)),
                            in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                NotchNewCollectionPill()   // Task 15; stub as EmptyView() until then
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .today: NotchTodayTab()
        case .agent: NotchAgentTab()          // Task 11
        case .meetings: NotchMeetingsTab()    // Task 12
        case .clips:
            NotchClipsTab(searchQuery: searchQuery, pinnedOnly: showPinnedOnly)  // Task 13
        case .shelf: NotchShelfTab(searchQuery: searchQuery)                     // Task 14
        case .collection(let name):
            NotchCollectionTab(name: name, searchQuery: searchQuery)             // Task 15
        }
    }
```

Until Tasks 11–15 land, stub the missing tab views in their eventual files as `Text("…").foregroundStyle(.white.opacity(0.4))` placeholders so each task ships a building app — create `NotchAgentTab.swift`, `NotchMeetingsTab.swift`, `NotchClipsTab.swift`, `NotchShelfTab.swift`, `NotchCollectionTab.swift` with minimal bodies in THIS task, then fill them in their own tasks. `NotchNewCollectionPill` stubs as `EmptyView`.

Keep: idle strip (`idleContent`) byte-identical; capture bar unchanged; `.onHover` now calls `controller?.hoverChanged(_)`. Also add `.onTapGesture` on `idleContent`: `controller?.pin()` (click-to-pin from the strip). Add an Esc handler on the shell: `.onExitCommand { controller?.unpin() }`.

- [x] **Step 3: Trim MeetingRecordingNotchView**

Delete the `MeetingStartPromptView()` line from the `.idle` case (the shell banner owns it now). Everything else stays.

- [x] **Step 4: Build + full suite + eye-check note**

Run: `swift build && swift test`
Expected: build succeeds, suite green, exit 0. (Tab bodies are stubs except Today.)

- [x] **Step 5: Commit**

```bash
git add Sources/MustardKit/Views/
git commit -m "feat(notch): tabbed shell — header, pills, banner slot, Today tab extracted"
```

---

### Task 11: Agent tab

**Files:**
- Modify: `Sources/MustardKit/Views/NotchAgentTab.swift` (replace Task 10 stub)

Read-only cards; every action routes to the console (`nav.openAgentConsole = true`) — the 2026-07-02 "no inline Approve/Deny in the notch" decision stands.

- [x] **Step 1: Implement**

```swift
#if os(macOS)
import SwiftUI
import SwiftData

/// Agent tab: what's waiting on Leon — pending recommendations and
/// attention-stage tasks — as read-only rows. The notch surfaces; the
/// Agent console acts (locked decision, 2026-07-02 redesign).
struct NotchAgentTab: View {
    @Environment(NotchNavigation.self) private var nav
    @Query private var tasks: [MustardTask]
    @Query(sort: \Recommendation.createdAt, order: .reverse)
    private var recommendations: [Recommendation]

    private var pending: [Recommendation] {
        RecommendationQueue.pending(recommendations, now: .now)
    }
    private var attentionTasks: [MustardTask] {
        tasks.filter { $0.stage == .needsReview || $0.stage == .needsYou }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if pending.isEmpty && attentionTasks.isEmpty {
                    Text("Nothing waiting on you")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
                ForEach(pending, id: \.persistentModelID) { rec in
                    row(icon: "sparkles", tint: "#AFA9EC",
                        title: rec.title, subtitle: "Approval waiting")
                }
                ForEach(attentionTasks, id: \.persistentModelID) { task in
                    row(icon: task.stage == .needsYou ? "questionmark.circle" : "tray.full",
                        tint: "#AFA9EC", title: task.title,
                        subtitle: task.stage == .needsYou ? "Needs you" : "Needs review")
                }
            }
        }
        .frame(maxHeight: 300)
    }

    private func row(icon: String, tint: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: tint))
                .frame(width: 26, height: 26)
                .background(Color(hex: "#7F77DD").opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { nav.openAgentConsole = true }
    }
}
#endif
```

Check the real name of the needs-you stage in `TaskStage.swift` before building — if it is not `.needsYou`, use the actual case (grep `needsReview` there for the exact spelling of both attention stages, and reuse `AgentInbox.attentionTaskCount`'s definition for consistency).

- [x] **Step 2: Build + suite; commit**

Run: `swift build && swift test` → green, exit 0.

```bash
git add Sources/MustardKit/Views/NotchAgentTab.swift
git commit -m "feat(notch): Agent tab — read-only waiting list routing to console"
```

---

### Task 12: Meetings tab + deep link to a recording

**Files:**
- Modify: `Sources/MustardKit/Views/NotchMeetingsTab.swift` (replace stub)
- Modify: `Sources/MustardKit/Views/NotchNavigation.swift` (add `pendingMeetingUID`)
- Modify: `Sources/MustardKit/Views/RootView.swift:150-162` (consume it)
- Modify: `Sources/MustardKit/Views/MeetingReviewView.swift:57-68` (accept initial selection)

- [x] **Step 1: Extend NotchNavigation**

```swift
    /// Set by the notch's Meetings tab; RootView switches to the Meetings
    /// screen and MeetingReviewView selects this uid.
    public var pendingMeetingUID: String?
```

- [x] **Step 2: Consume in RootView**

Next to the existing `.onChange(of: notchNav.pendingTask, ...)` handlers add:

```swift
        .onChange(of: notchNav.pendingMeetingUID, initial: true) { _, uid in
            guard uid != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            selectedScreen = .meetings
            // MeetingReviewView reads and clears the uid itself.
        }
```

(Match the actual screen-selection state name used in `RootView` — the `case .meetings: MeetingReviewView()` switch at line 87 shows the pattern.)

- [x] **Step 3: MeetingReviewView initial selection**

In `MeetingReviewView`, add `@Environment(NotchNavigation.self) private var nav: NotchNavigation?` and:

```swift
        .onChange(of: nav?.pendingMeetingUID, initial: true) { _, uid in
            guard let uid else { return }
            selectedUID = uid
            nav?.pendingMeetingUID = nil
        }
```

- [x] **Step 4: Implement the tab**

```swift
#if os(macOS)
import SwiftUI
import SwiftData

/// Meetings tab: recorder (moved from Today), upcoming meetings, recent
/// recordings. Consent stays in MeetingCaptureCoordinator — this renders
/// and dispatches only.
struct NotchMeetingsTab: View {
    @Environment(NotchNavigation.self) private var nav
    @Query(sort: \CalendarEvent.start) private var events: [CalendarEvent]
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var meetings: [MeetingRecord]

    private var upcoming: [CalendarEvent] {
        events.filter { $0.start > .now && Calendar.current.isDateInToday($0.start) }
            .prefix(3).map { $0 }
    }
    private var recent: [MeetingRecord] {
        meetings.filter { $0.status != .preparing }.prefix(10).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MeetingRecordingNotchView()

                if !upcoming.isEmpty {
                    sectionHeader("UPCOMING")
                    ForEach(upcoming, id: \.persistentModelID) { event in
                        HStack(spacing: 8) {
                            Text(event.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                                .frame(width: 44, alignment: .leading)
                            Text(event.title)
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                            Spacer()
                            if let join = event.joinURL, let url = URL(string: join) {
                                Link("Join", destination: url)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(hex: "#6E9FFF"))
                            }
                        }
                    }
                }

                sectionHeader("RECENT RECORDINGS")
                if recent.isEmpty {
                    Text("No recordings yet")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
                ForEach(recent, id: \.uid) { meeting in
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title.isEmpty ? "Meeting" : meeting.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                            Text(subtitle(for: meeting))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        statusBadge(meeting.status)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { nav.pendingMeetingUID = meeting.uid }
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.08)
            .foregroundStyle(.white.opacity(0.4))
    }

    private func subtitle(for meeting: MeetingRecord) -> String {
        var parts: [String] = []
        if let started = meeting.startedAt {
            parts.append(started.formatted(date: .abbreviated, time: .shortened))
            if let ended = meeting.endedAt {
                let minutes = Int(ended.timeIntervalSince(started) / 60)
                parts.append("\(minutes) min")
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusBadge(_ status: MeetingStatus) -> some View {
        let (label, hex): (String, String) = switch status {
        case .ready: ("Ready", "#5DCAA5")
        case .partial: ("Partial", "#FFBD2E")
        case .failed: ("Failed", "#FF5F57")
        case .recording: ("Recording", "#FF5F57")
        default: ("…", "#FFFFFF")
        }
        Text(label)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Color(hex: hex))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(hex: hex).opacity(0.15), in: Capsule())
    }
}
#endif
```

(Check `CalendarEvent`'s join-URL property name against the model — `AgendaRow` uses `item.joinURL` from `AgendaItem`; the event model may spell it differently.)

- [x] **Step 5: Build + suite; commit**

Run: `swift build && swift test` → green, exit 0.

```bash
git add Sources/MustardKit/Views/NotchMeetingsTab.swift Sources/MustardKit/Views/NotchNavigation.swift Sources/MustardKit/Views/RootView.swift Sources/MustardKit/Views/MeetingReviewView.swift
git commit -m "feat(notch): Meetings tab — recorder, upcoming, recent recordings deep link"
```

---

### Task 13: Clips tab — cards, filters, copy + paste-back

**Files:**
- Create: `Sources/MustardKit/Clipboard/ClipPaster.swift`
- Create: `Sources/MustardKit/Views/ClipCardView.swift`
- Modify: `Sources/MustardKit/Views/NotchClipsTab.swift` (replace stub)
- Modify: `Sources/MustardKit/Dictation/TextInserter.swift:132-141` (extract the ⌘V CGEvent block)
- Test: `Tests/MustardTests/ClipPasterTests.swift`

- [x] **Step 1: Extract PasteKeystroke from TextInserter.live**

The CGEvent ⌘V block inside `TextInserter.live`'s `sendPaste` closure moves to a shared helper (same file or `ClipPaster.swift`):

```swift
#if os(macOS)
import CoreGraphics

/// Synthesizes ⌘V to a pid. Shared by dictation insertion and clip paste-back.
/// Requires the Accessibility grant (same one dictation already needs).
enum PasteKeystroke {
    static func send(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }
}
#endif
```

`TextInserter.live`'s `sendPaste:` closure becomes `{ pid in PasteKeystroke.send(to: pid) }` — **compare the extracted body against the original at `TextInserter.swift:132-141` first and keep the original's exact event flags/post order** (the snippet above is from the grep; the file is the truth).

- [x] **Step 2: Failing test for ClipPaster (closure-injected, like TextInserter)**

```swift
import XCTest
@testable import MustardKit

@MainActor
final class ClipPasterTests: XCTestCase {
    func testPasteWritesThenSendsCommandV() async {
        var writes: [String] = []
        var pasted: [pid_t] = []
        let paster = ClipPaster(
            writeToPasteboard: { text in writes.append(text); return 7 },
            frontmostPID: { 42 },
            sendPaste: { pid in pasted.append(pid); return true },
            markOwnWrite: { _ in })
        let ok = await paster.paste(text: "hello")
        XCTAssertTrue(ok)
        XCTAssertEqual(writes, ["hello"])
        XCTAssertEqual(pasted, [42])
    }

    func testOwnWriteIsMarkedSoMonitorSkipsIt() async {
        var marked: [Int] = []
        let paster = ClipPaster(
            writeToPasteboard: { _ in 7 },
            frontmostPID: { 42 },
            sendPaste: { _ in true },
            markOwnWrite: { marked.append($0) })
        _ = await paster.paste(text: "x")
        XCTAssertEqual(marked, [7])
    }

    func testNoFrontmostAppStillCopies() async {
        var writes: [String] = []
        let paster = ClipPaster(
            writeToPasteboard: { text in writes.append(text); return 7 },
            frontmostPID: { nil },
            sendPaste: { _ in XCTFail("no paste without a target"); return false },
            markOwnWrite: { _ in })
        let ok = await paster.paste(text: "hello")
        XCTAssertFalse(ok)              // paste didn't happen…
        XCTAssertEqual(writes, ["hello"])  // …but the copy did
    }
}
```

Run: `swift test --filter ClipPasterTests` → compile FAILURE.

- [x] **Step 3: Implement ClipPaster**

```swift
import Foundation

/// Clip → frontmost app. Copy is always the first half of paste, so a failed
/// paste still leaves the clip on the pasteboard (worst case: user ⌘V's).
@MainActor
public final class ClipPaster {
    /// Write text, return the resulting changeCount.
    private let writeToPasteboard: (String) -> Int
    private let frontmostPID: () -> pid_t?
    private let sendPaste: (pid_t) -> Bool
    /// Tell the monitor this change is ours (ClipboardMonitor.expectOwnWrite).
    private let markOwnWrite: (Int) -> Void

    public init(
        writeToPasteboard: @escaping (String) -> Int,
        frontmostPID: @escaping () -> pid_t?,
        sendPaste: @escaping (pid_t) -> Bool,
        markOwnWrite: @escaping (Int) -> Void
    ) {
        self.writeToPasteboard = writeToPasteboard
        self.frontmostPID = frontmostPID
        self.sendPaste = sendPaste
        self.markOwnWrite = markOwnWrite
    }

    /// Copy only (the click action).
    public func copy(text: String) {
        markOwnWrite(writeToPasteboard(text))
    }

    /// Copy + ⌘V into the frontmost app (Return / double-click).
    public func paste(text: String) async -> Bool {
        copy(text: text)
        guard let pid = frontmostPID() else { return false }
        return sendPaste(pid)
    }
}

#if os(macOS)
import AppKit

extension ClipPaster {
    public static func live(monitor: ClipboardMonitor) -> ClipPaster {
        ClipPaster(
            writeToPasteboard: { text in
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(text, forType: .string)
                return board.changeCount
            },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            sendPaste: { pid in PasteKeystroke.send(to: pid) },
            markOwnWrite: { [weak monitor] count in
                Task { @MainActor in monitor?.expectOwnWrite(changeCount: count) }
            })
    }
}
#endif
```

Run: `swift test --filter ClipPasterTests` → PASS (3 tests), exit 0.

- [x] **Step 4: ClipCardView + NotchClipsTab**

`ClipCardView.swift`:

```swift
#if os(macOS)
import SwiftUI

/// One clip card: type-appropriate preview + source badge + relative time.
/// Dark hex only (notch exception).
struct ClipCardView: View {
    let clip: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Text(clip.sourceAppName ?? "—")
                Text("·")
                Text(clip.createdAt, format: .relative(presentation: .named))
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(1)
        }
        .padding(8)
        .frame(height: 76)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var preview: some View {
        switch clip.kind {
        case .color:
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(hex: normalizedHex))
                .frame(height: 28)
                .overlay(alignment: .bottomLeading) {
                    Text(clip.payload).font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white).padding(3)
                }
        case .image:
            if let data = clip.thumbnailData ?? clip.imageData,
               let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "photo").foregroundStyle(.white.opacity(0.4))
            }
        case .file:
            HStack(spacing: 5) {
                Image(systemName: "doc").font(.system(size: 12))
                Text((clip.payload as NSString).lastPathComponent)
                    .font(.system(size: 10.5)).lineLimit(2)
            }
            .foregroundStyle(.white.opacity(0.75))
        case .link:
            Text(clip.payload).font(.system(size: 10.5))
                .foregroundStyle(Color(hex: "#6E9FFF")).lineLimit(3)
        case .dictation, .text:
            Text(clip.payload).font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.75)).lineLimit(3)
        }
    }

    private var normalizedHex: String {
        clip.payload.hasPrefix("#") ? clip.payload : "#FFFFFF"
    }

    private var cardBackground: Color {
        clip.kind == .dictation ? Color(hex: "#7F77DD").opacity(0.14) : .white.opacity(0.06)
    }
}
#endif
```

`NotchClipsTab.swift` — grid + chips + actions. `ClipItem` gets a `NotchSearchable` conformance in this file:

```swift
extension ClipItem: NotchSearchable {
    public var searchText: String {
        "\(payload) \(sourceAppName ?? "") \(kind.rawValue)"
    }
}
```

```swift
#if os(macOS)
import SwiftUI
import SwiftData

/// Clips tab: automatic history. Click = copy, Return/double-click = paste
/// into the frontmost app, drag-out, context menu for shelf/collections.
struct NotchClipsTab: View {
    let searchQuery: String
    let pinnedOnly: Bool
    @Environment(\.modelContext) private var context
    @Environment(ClipboardServices.self) private var services: ClipboardServices?
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var clips: [ClipItem]
    @Query(sort: \ClipCollection.sortOrder) private var collections: [ClipCollection]
    @State private var kindFilter: ClipKind?
    @State private var selectedUID: String?

    private var visible: [ClipItem] {
        var items = clips.filter { $0.collection == nil }
        if pinnedOnly { items = items.filter(\.pinnedToShelf) }
        if let kindFilter { items = items.filter { $0.kind == kindFilter } }
        return NotchSearch.filter(items, query: searchQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterChips
            if visible.isEmpty {
                Text(clips.isEmpty ? "Copy anything — it lands here" : "No matches")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(visible, id: \.uid) { clip in
                            ClipCardView(clip: clip)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(selectedUID == clip.uid
                                            ? Color(hex: "#6E9FFF") : .clear, lineWidth: 1))
                                .onTapGesture(count: 2) { paste(clip) }
                                .onTapGesture { select(clip) }
                                .onDrag { dragProvider(for: clip) }
                                .contextMenu { menu(for: clip) }
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
        }
        .onKeyPress(.return) {
            guard let clip = visible.first(where: { $0.uid == selectedUID }) else { return .ignored }
            paste(clip)
            return .handled
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                chip(nil, label: "All")
                ForEach([ClipKind.text, .link, .image, .file, .color, .dictation], id: \.self) {
                    chip($0, label: $0.rawValue.capitalized)
                }
            }
        }
    }

    private func chip(_ kind: ClipKind?, label: String) -> some View {
        let selected = kindFilter == kind
        return Button { kindFilter = kind } label: {
            Text(label)
                .font(.system(size: 10)).foregroundStyle(selected ? .black : .white.opacity(0.6))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    selected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.white.opacity(0.07)),
                    in: Capsule())
        }.buttonStyle(.plain)
    }

    private func select(_ clip: ClipItem) {
        selectedUID = clip.uid
        services?.paster.copy(text: clip.payload)
    }

    private func paste(_ clip: ClipItem) {
        guard let services else { return }
        Task { _ = await services.paster.paste(text: clip.payload) }
    }

    private func dragProvider(for clip: ClipItem) -> NSItemProvider {
        switch clip.kind {
        case .file: NSItemProvider(contentsOf: URL(fileURLWithPath: clip.payload))
            ?? NSItemProvider(object: clip.payload as NSString)
        case .image:
            if let data = clip.imageData ?? clip.thumbnailData, let image = NSImage(data: data) {
                NSItemProvider(object: image)
            } else {
                NSItemProvider(object: clip.payload as NSString)
            }
        default: NSItemProvider(object: clip.payload as NSString)
        }
    }

    @ViewBuilder private func menu(for clip: ClipItem) -> some View {
        Button(clip.pinnedToShelf ? "Unpin from Shelf" : "Pin to Shelf") {
            clip.pinnedToShelf.toggle()
            try? context.save()
        }
        if !collections.isEmpty {
            Menu("Add to collection") {
                ForEach(collections, id: \.uid) { collection in
                    Button(collection.name) {
                        clip.collection = collection
                        try? context.save()
                    }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            context.delete(clip)
            try? context.save()
        }
    }
}
#endif
```

`ClipboardServices` is a tiny `@Observable` env box created in Task 16 — define it now in `ClipStore.swift`:

```swift
/// Environment bundle for the clipboard layer (monitor + store + paster),
/// injected into the notch content the way AgentService is.
@MainActor
@Observable
public final class ClipboardServices {
    public let store: ClipStore
    public let monitor: ClipboardMonitor
    public let paster: ClipPaster

    public init(store: ClipStore, monitor: ClipboardMonitor, paster: ClipPaster) {
        self.store = store
        self.monitor = monitor
        self.paster = paster
    }
}
```

Image paste-back only copies the payload string for v1 (image → pasteboard paste is a later nicety; click-to-copy for images writes the image via a small branch in `select`: acceptable v1 = text-kinds paste, image/file drag-out).

- [x] **Step 5: Build + suite; commit**

Run: `swift build && swift test` → green, exit 0.

```bash
git add Sources/MustardKit/Clipboard/ Sources/MustardKit/Views/ClipCardView.swift Sources/MustardKit/Views/NotchClipsTab.swift Sources/MustardKit/Dictation/TextInserter.swift Tests/MustardTests/ClipPasterTests.swift
git commit -m "feat(notch): Clips tab — cards, filters, copy/paste-back, drag-out"
```

---

### Task 14: Shelf tab + drag-in

**Files:**
- Modify: `Sources/MustardKit/Views/NotchShelfTab.swift` (replace stub)
- Modify: `Sources/MustardKit/Views/NotchSurface.swift` (drop handlers on idle strip + shell)

- [x] **Step 1: Shelf tab**

```swift
#if os(macOS)
import SwiftUI
import SwiftData

/// Shelf: deliberate keeps. Items arrive by drag-in or "Pin to Shelf";
/// they leave only by explicit unpin/delete. Never auto-pruned.
struct NotchShelfTab: View {
    let searchQuery: String
    @Environment(\.modelContext) private var context
    @Environment(ClipboardServices.self) private var services: ClipboardServices?
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var clips: [ClipItem]

    private var shelf: [ClipItem] {
        NotchSearch.filter(clips.filter(\.pinnedToShelf), query: searchQuery)
    }

    var body: some View {
        Group {
            if shelf.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20)).foregroundStyle(.white.opacity(0.3))
                    Text("Drop files or text here — or pin a clip")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(shelf, id: \.uid) { clip in
                            ClipCardView(clip: clip)
                                .onTapGesture { services?.paster.copy(text: clip.payload) }
                                .onDrag { NSItemProvider(object: clip.payload as NSString) }
                                .contextMenu {
                                    Button("Unpin") {
                                        clip.pinnedToShelf = false
                                        try? context.save()
                                    }
                                    Button("Delete", role: .destructive) {
                                        context.delete(clip)
                                        try? context.save()
                                    }
                                }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }
}
#endif
```

- [x] **Step 2: Drop target on the whole notch surface**

On `NotchView`'s outermost `VStack` (both idle and expanded render inside it) add:

```swift
        .onDrop(of: [.fileURL, .image, .utf8PlainText], isTargeted: nil) { providers in
            guard let services else { return false }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in services.store.addShelfDrop(fileURL: url) }
                    }
                } else if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                        guard let data = (image as? NSImage)?.tiffRepresentation else { return }
                        Task { @MainActor in services.store.addShelfDrop(imageData: data) }
                    }
                } else {
                    _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                        guard let text = string as? String else { return }
                        Task { @MainActor in services.store.addShelfDrop(text: text) }
                    }
                }
            }
            return true
        }
```

(`import UniformTypeIdentifiers` at the top; add `@Environment(ClipboardServices.self) private var services: ClipboardServices?` to `NotchView`.)

- [x] **Step 3: Build + suite; commit**

Run: `swift build && swift test` → green, exit 0.

```bash
git add Sources/MustardKit/Views/NotchShelfTab.swift Sources/MustardKit/Views/NotchSurface.swift
git commit -m "feat(notch): Shelf tab + drag-in drop target on the notch"
```

---

### Task 15: Custom collections

**Files:**
- Modify: `Sources/MustardKit/Views/NotchCollectionTab.swift` (replace stub)
- Modify: `Sources/MustardKit/Views/NotchSurface.swift` (real `NotchNewCollectionPill`)

- [x] **Step 1: Collection tab**

```swift
#if os(macOS)
import SwiftUI
import SwiftData

/// One custom collection's contents. Same cards; filing/unfiling via
/// context menu. Deleting the collection unfiles (nullify), never deletes.
struct NotchCollectionTab: View {
    let name: String
    let searchQuery: String
    @Environment(\.modelContext) private var context
    @Environment(ClipboardServices.self) private var services: ClipboardServices?
    @Query(sort: \ClipCollection.sortOrder) private var collections: [ClipCollection]

    private var collection: ClipCollection? {
        collections.first { $0.name == name }
    }
    private var items: [ClipItem] {
        let filed = (collection?.items ?? []).sorted { $0.createdAt > $1.createdAt }
        return NotchSearch.filter(filed, query: searchQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text("Empty — file clips here from their context menu")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(items, id: \.uid) { clip in
                            ClipCardView(clip: clip)
                                .onTapGesture { services?.paster.copy(text: clip.payload) }
                                .onDrag { NSItemProvider(object: clip.payload as NSString) }
                                .contextMenu {
                                    Button("Remove from \(name)") {
                                        clip.collection = nil
                                        try? context.save()
                                    }
                                    Button("Delete clip", role: .destructive) {
                                        context.delete(clip)
                                        try? context.save()
                                    }
                                }
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
            Spacer(minLength: 0)
            Button("Delete collection", role: .destructive) {
                if let collection { context.delete(collection); try? context.save() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(Color(hex: "#FF5F57").opacity(0.8))
        }
    }
}
#endif
```

Deleting the collection while its tab is active must not strand the UI: in the shell (`NotchSurface.swift`), when `tabs` no longer contains `activeTab`, fall back to `.clips` — add to `tabPills`' container:

```swift
        .onChange(of: tabs) { _, new in
            if !new.contains(activeTab) {
                activeTab = .clips
                controller?.select(tab: .clips)
            }
        }
```

- [x] **Step 2: The "+" pill**

Replace the `NotchNewCollectionPill` stub in `NotchSurface.swift`:

```swift
private struct NotchNewCollectionPill: View {
    @Environment(\.modelContext) private var context
    @Query private var collections: [ClipCollection]
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        if naming {
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.white)
                .frame(width: 80)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.white.opacity(0.1), in: Capsule())
                .onSubmit {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, !collections.contains(where: { $0.name == trimmed }) {
                        context.insert(ClipCollection(
                            name: trimmed,
                            sortOrder: (collections.map(\.sortOrder).max() ?? -1) + 1))
                        try? context.save()
                    }
                    name = ""
                    naming = false
                }
                .onExitCommand { naming = false; name = "" }
        } else {
            Button { naming = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
```

- [x] **Step 3: Build + suite; commit**

Run: `swift build && swift test` → green, exit 0.

```bash
git add Sources/MustardKit/Views/NotchCollectionTab.swift Sources/MustardKit/Views/NotchSurface.swift
git commit -m "feat(notch): custom collections — + pill, filing, unfile-on-delete"
```

---

### Task 16: ⌃⌥V hotkey + app wiring

**Files:**
- Create: `Sources/MustardKit/Clipboard/ClipsHotKey.swift`
- Modify: `Sources/Mustard/MustardApp.swift:239-280` (services + hotkey), `:283-290` (menu)

- [x] **Step 1: ClipsHotKey**

Clone `RewriteHotKey` (`Sources/MustardKit/Rewrite/RewriteHotKey.swift`) verbatim with: class name `ClipsHotKey`, `id: UInt32 = 4`, default `keyCode` `kVK_ANSI_V`, UserDefaults keys `clipsHotKeyCode`/`clipsHotKeyModifiers`, log lines via the same pattern (use `voiceLog`-style logger or a new `ClipboardLog.logger` mirroring `RewriteLog`). Keep all three load-bearing properties from the doc comment: fall-through for foreign chords via `HotKeyDispatch.decide`, pressed-only semantics, `.conflict` surfaced. The shared "MSTD" signature disambiguates by id (capture 1, dictation 2, rewrite 3, **clips 4**).

- [x] **Step 2: Wire everything in MustardApp**

Add state alongside the existing controllers:

```swift
    @State private var clipboard: ClipboardServices?
    @State private var clipsHotKey: ClipsHotKey?
```

In the setup block (after the notch controller creation), following the existing `if x == nil` pattern:

```swift
                    if clipboard == nil {
                        // Mustard owns clipboard capture (notch shelf spec §1):
                        // one poller, concealed/transient types skipped, password
                        // managers excluded, 200-item history in SwiftData.
                        let store = ClipStore(context: container.mainContext)
                        let monitor = ClipboardMonitor(pasteboard: LivePasteboard()) { candidate in
                            store.ingest(candidate)
                        }
                        monitor.start()
                        let services = ClipboardServices(
                            store: store, monitor: monitor,
                            paster: .live(monitor: monitor))
                        clipboard = services

                        let hotKey = ClipsHotKey()
                        hotKey.onPress = { [weak notch] in
                            notch?.openPinned(on: NotchTabModel.clipsHotKeyTab)
                        }
                        hotKey.register()
                        clipsHotKey = hotKey
                    }
```

`notch` is a `@State` var, not weak-capturable — capture the controller directly:
`hotKey.onPress = { notchController?.openPinned(on: .clips) }` using whatever local
name the controller has in scope; keep it a strong capture of the controller
instance created above (it lives for the app's lifetime anyway).

Inject into the notch content closure (add to the existing `.environment` chain):

```swift
                                    .environment(clipboardServices)
```

(build the `ClipboardServices` BEFORE the `NotchController` block so it's in scope;
reorder the two `if … == nil` blocks accordingly.)

Add the menu item so the chord is discoverable:

```swift
                Button("Open Clips") { notch?.openPinned(on: .clips) }
                    .keyboardShortcut("v", modifiers: [.control, .option])
```

(SwiftUI menu shortcuts don't replace the Carbon registration — background operation needs Carbon; the menu item is for discoverability, matching how ⌘⇧N works today.)

Search-focus on hotkey open: in the shell, add `@FocusState private var searchFocused: Bool` bound to the search `TextField`, and focus it in `.onChange(of: controller?.isPinned)` when the active tab is `.clips`. Best-effort: the panel is non-activating, so keyboard focus lands only when the panel becomes key (same caveat as the capture bar today).

- [x] **Step 3: Build + suite; commit**

Run: `swift build && swift test` → green, exit 0.

```bash
git add Sources/MustardKit/Clipboard/ClipsHotKey.swift Sources/Mustard/MustardApp.swift
git commit -m "feat(clips): ⌃⌥V hotkey (id 4), clipboard services wired into the app"
```

---

### Task 17: Dictation → Clips

**Files:**
- Modify: `Sources/MustardKit/Dictation/SystemDictationCoordinator.swift` (injected hook + call sites + header comment)
- Modify: `Sources/Mustard/MustardApp.swift:272-279` (pass the hook)
- Test: extend `Tests/MustardTests/SystemDictationCoordinatorTests.swift` (file exists; follow its stub pattern)

- [x] **Step 1: Write the failing test** (add to the existing suite, reusing its fixtures/stubs — read the file first and mirror how it constructs the coordinator; the assertions to add:)

```swift
    func testFinalTranscriptIsOfferedToHistoryOnInsert() async {
        var offered: [String] = []
        // …construct the coordinator exactly as the suite's other tests do,
        // with insert stubbed to return .insertedDirectly, plus:
        //   onFinalTranscript: { offered.append($0) }
        // …drive a capture with final transcript "hello world" to completion…
        XCTAssertEqual(offered, ["hello world"])
    }

    func testSecureFieldTranscriptIsNeverOffered() async {
        var offered: [String] = []
        // …same construction, but with a secure-field target (whatever fixture
        // the suite already uses for the DictationWhitespace.insertion == nil
        // path)…
        XCTAssertTrue(offered.isEmpty)
    }

    func testPreservedTranscriptIsStillOffered() async {
        var offered: [String] = []
        // …insert stubbed to fail (the .preserved path)…
        XCTAssertEqual(offered.count, 1)
    }
```

Run: `swift test --filter SystemDictationCoordinatorTests` → FAIL (no `onFinalTranscript`).

- [x] **Step 2: Implement**

- Add to the coordinator: `private let onFinalTranscript: ((String) -> Void)?`, new init parameter defaulting to `nil`, stored alongside `insert`.
- Call it at the two insert sites (`SystemDictationCoordinator.swift:231` region and the retry at `:265` region — only on the FIRST attempt path, not the retry, to avoid double-offering; place the call **after** the `DictationWhitespace.insertion(...)` guard so secure fields never reach it, passing the pre-normalization `transcript` (the words as spoken; whitespace normalization is target-specific):

```swift
            guard let text = DictationWhitespace.insertion(text: transcript, target: target) else {
                // secure field — nothing stored, nothing inserted
                …existing code…
            }
            onFinalTranscript?(transcript)
            let outcome = await self.insert(text, target)
```

- Update the file-header comment (`:24`): dictation transcripts now ALSO land in clip history by explicit spec decision (`docs/superpowers/specs/2026-08-12-notch-shelf-redesign-design.md` §1) — the "never into Mustard's store" line changes to say secure-field dictations are never stored anywhere, ordinary transcripts go to `ClipStore` via the injected hook.
- In `SystemDictationCoordinator.live()`, add a `clipStore: ClipStore?` parameter; pass `onFinalTranscript: { [weak clipStore] t in Task { @MainActor in clipStore?.addDictation(transcript: t) } }` (adjust to the actual isolation of `.live()`).
- In `MustardApp`, pass the store: `SystemDictationCoordinator.live(clipStore: clipboard?.store)` — move dictation setup after clipboard setup in the block.

- [x] **Step 3: Run suite; commit**

Run: `swift test --filter SystemDictationCoordinatorTests` then `swift build && swift test` → green, exit 0.

```bash
git add Sources/MustardKit/Dictation/SystemDictationCoordinator.swift Sources/Mustard/MustardApp.swift Tests/MustardTests/SystemDictationCoordinatorTests.swift
git commit -m "feat(dictation): final transcripts land in clip history (spec reversal)"
```

---

### Task 18: Voice pill screen unification

**Files:**
- Modify: `Sources/MustardKit/Logic/NotchScreenPicker.swift` (add a live-chooser helper)
- Modify: `Sources/MustardKit/Capture/VoiceTaskCaptureCoordinator.swift:752` (PanelHolder placement)
- Modify: `Sources/MustardKit/Dictation/SystemDictationCoordinator.swift:413` region (same pattern)

- [x] **Step 1: Shared live chooser**

Add to `NotchScreenPicker.swift` (AppKit extension under `#if os(macOS)` — the pure `choose(from:)` stays untouched and tested):

```swift
#if os(macOS)
import AppKit

extension NotchScreenPicker {
    /// The one place panels resolve "which display is the notch display".
    /// Used by the notch panel, the voice pill, the dictation pill, and the
    /// quick-edit card so they can never land on different screens.
    @MainActor
    public static func currentScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let descriptors = screens.enumerated().map { index, screen in
            NotchScreenDescriptor(
                id: index,
                hasNotch: screen.safeAreaInsets.top > 0,
                isMain: screen == NSScreen.main)
        }
        guard let chosen = choose(from: descriptors),
              let index = chosen.id as? Int else { return NSScreen.main }
        return screens[index]
    }
}
#endif
```

- [x] **Step 2: Adopt everywhere**

- `NotchController.screen` → `NotchScreenPicker.currentScreen()` (delete the inline copy).
- `PanelHolder.show` (`VoiceTaskCaptureCoordinator.swift:752`): `if let screen = NSScreen.main` → `if let screen = NotchScreenPicker.currentScreen()`.
- The `NSScreen.main` pill placement in `SystemDictationCoordinator.swift` (~line 413): same replacement.
- `VoiceTaskQuickEditController` already computes the picker inline (~`:232-246`) — switch it to the shared helper too and delete its copy.

- [x] **Step 3: Build + suite; commit**

Run: `swift build && swift test` → green, exit 0.

```bash
git add Sources/MustardKit/Logic/NotchScreenPicker.swift Sources/MustardKit/Capture/ Sources/MustardKit/Dictation/SystemDictationCoordinator.swift Sources/MustardKit/Views/NotchSurface.swift
git commit -m "fix(voice): all top-of-screen panels resolve their display via NotchScreenPicker"
```

---

### Task 19: Docs + final verification

**Files:**
- Modify: `CLAUDE.md` (folder layout: `Clipboard/` + new Logic units; voice-capture section note about dictation history; notch description)
- Modify: `docs/build-order.md` (entry for this feature, marked shipped)
- Modify: `docs/superpowers/plans/2026-08-12-notch-shelf-redesign.md` (tick all checkboxes; sync any drift between plan blocks and shipped code)

- [x] **Step 1: Update CLAUDE.md**

- Folder layout: add `Clipboard/  ClipboardMonitor (changeCount polling, concealed/transient skip), ClipStore (+ClipboardServices), ClipPaster, ClipsHotKey (⌃⌥V, id 4)`; extend the Logic list with `ClipClassifier, ClipStoreRules, NotchPinState, NotchTabModel/NotchPanelMetrics, NotchSearch`; note NotchSurface's decomposition into tab files.
- The dictation bullet: "(transcripts also land in clip history — secure fields excepted — per the 2026-08-12 notch shelf spec)".
- Notch description: hover peek + click-to-pin + tabbed shell (Today · Agent · Meetings · Clips · Shelf · collections).

- [x] **Step 2: Full verification**

```bash
swift build && swift test && ./build-app.sh
```

Expected: build succeeds, full suite green (~1,680+: 1,634 baseline + ~40 new), app bundle assembles. Verify by exit codes.

- [x] **Step 3: Commit**

```bash
git add CLAUDE.md docs/
git commit -m "docs: notch shelf — CLAUDE.md layout, build-order entry, plan sync"
```

---

## Leon's eye-check list (goes in the PR body)

The in-session shell has no TCC, so none of this can be verified headlessly:

1. Hover the notch — expands with tabs; pointer-out collapses after a beat (no more instant-collapse flicker).
2. Click the strip — pins; Esc or clicking another app unpins. ⌘⇧N opens pinned.
3. Copy things in Safari/Terminal/Figma — they appear in Clips with the right kind + app badge. Copy something in 1Password — it must NOT appear.
4. ⌃⌥V — panel opens on Clips; click a card then ⌘V somewhere; double-click a card — pastes into the frontmost app.
5. Drag a file onto the notch — lands on Shelf; drag a card out into Finder/Slack.
6. ⌃⌥D dictate — transcript appears in Clips with the Dictation badge.
7. Meetings tab — recorder works as before (consent card, red dot), recent recordings open the Meetings screen.
8. "+" pill — create a collection, file a clip into it from the context menu, delete the collection (clip returns to history).
9. Unplug/replug the external display — notch and voice pill land on the same screen.

## As-built deviations

Where the shipped code deliberately diverges from the plan's code blocks:

- **`ClipStoreRules.pruneUIDs` is generic** (`<T: ClipPrunable>`) rather than
  `[any ClipPrunable]`, so the test-only `Row` conformer costs no existential
  overhead.
- **`ClipClassifier`'s hex check adds an ASCII guard** (`$0.isASCII &&
  $0.isHexDigit`) — Swift's `isHexDigit` accepts fullwidth Unicode digits,
  which the plan's version would have wrongly classified as `.color`; extra
  negative tests cover fullwidth digits and malformed `rgb()`/non-HTTP URLs.
- **`ClipboardMonitor` sweeps stale own-write marks**, not just the exact
  `changeCount` match: any mark ≤ the current count is dropped too, so a
  skipped intermediate change can't leave a stale entry sitting in the set
  forever. **`ClipStore`/`LivePasteboard` split image-vs-text precedence
  differently than drafted:** the pasteboard reader now always surfaces image
  bytes when there's no file URL, even alongside text (a browser's "Copy
  Image" pairs image data with the image's URL as text); `ClipStore.ingest`
  is what decides — image wins only when the accompanying text is empty or
  itself link-shaped, otherwise text wins. Extra `ClipStoreTests` cover the 5
  MB image cap (small image keeps original + thumbnail, oversize keeps only
  the thumbnail) and both sides of the image/text precedence call.
- **The Agent tab reads three gate stages, not the plan's assumed two.**
  `TaskStage` already had a real `.needsInput` case; the tab uses
  `AgentInbox.attention(tasks).inFlight` (needsApproval ∪ needsInput ∪
  needsReview, oldest-first) rather than re-deriving a waiting list, so it
  stays in lockstep with the console.
- **`pendingTab` (the one-shot hotkey-requested tab) is consumed from two
  call sites** — the shell's `onAppear` and its `stateVersion` `onChange` —
  because a hotkey fired while the panel was already visible only bumps
  `stateVersion`, it doesn't re-trigger `onAppear`.
- **`NotchController.toggle()` was replaced by `togglePinned()`.** The old
  `toggle()` hid the panel on a second press; that's wrong for a pinned
  command shelf, where ⌘⇧N should pin/unpin without ever hiding a panel that
  should stay visible while merely unpinned (e.g. hovered).
- **A `NotchPanel` `NSPanel` subclass overrides `canBecomeKey`,** which the
  plan's `NotchController` rewrite didn't call out. Needed so Return-to-paste
  and the search field/typable clip cells can accept keyboard input from a
  borderless, non-activating panel.
- **`ClipPaster` grew beyond the plan's sketch:** a `copy(imageData:)`
  overload for image clips, a guard against pasting into Mustard's own
  process (`pid != ProcessInfo.processInfo.processIdentifier`), and a
  synchronous own-write mark (`monitor?.expectOwnWrite(changeCount:)`) fired
  before the write completes, so the monitor's next poll can never race it.
- **One shared `ClipDragProvider`** backs drag-out from all three grids
  (Clips, Shelf, collections) plus `ClipCardView`, rather than each tab
  rolling its own `NSItemProvider` construction.
- **`RootView`'s screen-state property is named `screen`,** not the
  `MustardScreen`-suffixed name implied by earlier drafts.
- **The dictation → Clips hook is one `@MainActor` closure** —
  `SystemDictationCoordinator`'s `onFinalTranscript`, wired once to
  `clipStore?.addDictation(transcript:)` after the existing secure-field
  guard — not a new coordinator-level dependency.
- **Known non-goals left open, unchanged from the plan:** search-focus on
  ⌃⌥V is best-effort only, since the panel is non-activating and macOS won't
  hand it key focus reliably; `RewriteController`/`HoverPanel` still resolve
  their screen via `NSScreen.main` rather than the shared
  `NotchScreenPicker` (out of scope for this pass); drag-over does not expand
  the collapsed notch strip before a drop lands.
