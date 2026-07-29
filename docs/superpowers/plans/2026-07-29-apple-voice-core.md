# Apple Voice Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared on-device Apple speech, language-model, asset, and permission foundation used by all Mustard voice features.

**Architecture:** Framework-specific objects stay behind injected protocols in `MustardKit/Voice`. Feature coordinators consume Mustard value types and async streams, allowing deterministic tests without microphones or live models.

**Tech Stack:** Swift 6, macOS 26/27, Speech (`SpeechAnalyzer`, Apple `SpeechTranscriber`, `SpeechDetector`, `AssetInventory`), Foundation Models (`SystemLanguageModel`, guided generation), AVFoundation, SwiftUI, XCTest.

---

### Task 1: Select the macOS 27 toolchain and raise the deployment floor

**Files:**
- Modify: `Package.swift`
- Modify: `README.md`
- Modify: `build-app.sh`

- [ ] **Step 1: Install/select Xcode 27 beta and prove the SDK is active**

Run:

```bash
sudo xcode-select -s /Applications/Xcode-beta.app
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

Expected: Xcode 27 beta and a macOS 27 SDK. Do not start API implementation while
the selected SDK remains 26.5.

- [ ] **Step 2: Raise the package and app metadata floor**

Change `Package.swift` to:

```swift
platforms: [.macOS(.v26)],
```

Set `LSMinimumSystemVersion` to `26.0` in the Info.plist emitted by
`build-app.sh`, and update README prerequisites to macOS 26+ / Xcode 27 beta.

- [ ] **Step 3: Verify the baseline**

Run:

```bash
swift test
swift build
```

Expected: the existing suite passes and both targets build with the selected SDK.

- [ ] **Step 4: Commit**

```bash
git add Package.swift README.md build-app.sh
git commit -m "build(voice): target modern Apple speech stack" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 2: Define framework-independent voice contracts

**Files:**
- Create: `Sources/MustardKit/Voice/VoiceTypes.swift`
- Create: `Sources/MustardKit/Voice/VoiceServices.swift`
- Test: `Tests/MustardTests/VoiceTypesTests.swift`

- [ ] **Step 1: Write failing normalization tests**

Cover stable/provisional mapping, ordered timestamps, optional confidence, and
supported/unavailable readiness states:

```swift
func testStableSegmentKeepsSourceAndTiming() {
    let segment = VoiceTranscriptSegment(
        id: "s1", text: "Send the notes", startSeconds: 1.2,
        endSeconds: 2.8, isFinal: true, confidence: 0.91, source: .microphone)
    XCTAssertTrue(segment.isFinal)
    XCTAssertEqual(segment.source, .microphone)
    XCTAssertEqual(segment.startSeconds, 1.2)
}
```

- [ ] **Step 2: Run the focused test and verify failure**

```bash
swift test --filter VoiceTypesTests
```

Expected: FAIL because `VoiceTranscriptSegment` is undefined.

- [ ] **Step 3: Add value types and protocols**

Define:

```swift
public enum VoiceAudioSource: String, Codable, Sendable {
    case microphone, meeting
}

public struct VoiceTranscriptSegment: Equatable, Sendable {
    public let id: String
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let isFinal: Bool
    public let confidence: Double?
    public let source: VoiceAudioSource
}

public enum VoiceReadiness: Equatable, Sendable {
    case ready
    case needsAssetDownload
    case permissionDenied
    case unsupportedLocale
    case unavailable(String)
}

public protocol VoiceTranscribing: Sendable {
    func readiness() async -> VoiceReadiness
    func prepare() async throws
    func start(source: VoiceAudioSource) async throws -> AsyncThrowingStream<VoiceTranscriptSegment, Error>
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) async throws
    func finish() async throws -> [VoiceTranscriptSegment]
    func cancel() async
}
```

Import AVFoundation in `VoiceServices.swift`, not in pure `VoiceTypes.swift`.

- [ ] **Step 4: Run tests**

```bash
swift test --filter VoiceTypesTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Voice Tests/MustardTests/VoiceTypesTests.swift
git commit -m "feat(voice): define shared voice contracts" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 3: Implement speech asset readiness

**Files:**
- Create: `Sources/MustardKit/Voice/VoiceAssetReadiness.swift`
- Test: `Tests/MustardTests/VoiceAssetReadinessTests.swift`

- [ ] **Step 1: Write failing readiness-state tests**

Use an injected asset closure and verify ready, download-needed, unsupported
locale, download error, and cancelled download transitions.

- [ ] **Step 2: Verify failure**

```bash
swift test --filter VoiceAssetReadinessTests
```

Expected: FAIL because `VoiceAssetReadiness` is undefined.

- [ ] **Step 3: Implement the state machine**

```swift
public struct VoiceAssetReadiness {
    public var resolveLocale: @Sendable (Locale) async -> Locale?
    public var installAssets: @Sendable (Locale) async throws -> Void

    public func prepare(locale: Locale) async -> VoiceReadiness {
        guard let supported = await resolveLocale(locale) else {
            return .unsupportedLocale
        }
        do {
            try await installAssets(supported)
            return .ready
        } catch is CancellationError {
            return .unavailable("Asset installation cancelled")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
```

The live closure uses `SpeechTranscriber.supportedLocale(equivalentTo:)` and
`AssetInventory.assetInstallationRequest(supporting:)`.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter VoiceAssetReadinessTests
git add Sources/MustardKit/Voice/VoiceAssetReadiness.swift Tests/MustardTests/VoiceAssetReadinessTests.swift
git commit -m "feat(voice): prepare on-device speech assets" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 4: Implement `AppleSpeechSession`

**Files:**
- Create: `Sources/MustardKit/Voice/AppleSpeechSession.swift`
- Test: `Tests/MustardTests/AppleSpeechSessionTests.swift`

- [ ] **Step 1: Write failing result-mapping tests**

Test provisional/final mapping, attributed-string conversion, audio time,
confidence normalization, cancellation, finalization, and analyzer errors using
an injected `SpeechAnalyzerDriving` seam.

- [ ] **Step 2: Verify failure**

```bash
swift test --filter AppleSpeechSessionTests
```

- [ ] **Step 3: Implement the live adapter**

Construct the Apple module with the current SDK's macOS 27 reporting options:

```swift
let transcriber = Speech.SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults, .alternativeTranscriptions],
    attributeOptions: [.audioTimeRange, .transcriptionConfidence]
)
let detector = SpeechDetector()
let format = await SpeechAnalyzer.bestAvailableAudioFormat(
    compatibleWith: [transcriber, detector])
let analyzer = SpeechAnalyzer(modules: [transcriber, detector])
```

Use `AnalyzerInputConverter` to convert incoming PCM buffers, yield
`AnalyzerInput` into one `AsyncStream`, consume `transcriber.results` in a
structured task, and call `finalizeAndFinishThroughEndOfInput()` on release.

- [ ] **Step 4: Add contextual vocabulary**

Expose `setContext(_ terms: [String])` and apply an `AnalysisContext` whose
general contextual strings contain deduplicated, nonempty area/project/contact
terms. Test deterministic truncation to a bounded list.

- [ ] **Step 5: Run focused and full tests**

```bash
swift test --filter AppleSpeechSessionTests
swift test
swift build
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MustardKit/Voice/AppleSpeechSession.swift Tests/MustardTests/AppleSpeechSessionTests.swift
git commit -m "feat(voice): add SpeechAnalyzer transcription session" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 5: Implement the on-device language service

**Files:**
- Create: `Sources/MustardKit/Voice/OnDeviceLanguageService.swift`
- Create: `Sources/MustardKit/Voice/PromptCatalog.swift`
- Test: `Tests/MustardTests/OnDeviceLanguageServiceTests.swift`

- [ ] **Step 1: Write failing availability and prompt-band tests**

Pin selections for macOS 26.0–26.3, 26.4, and 27.0+, plus disabled, ineligible,
model-not-ready, unsupported-locale, and context-overflow results.

- [ ] **Step 2: Verify failure**

```bash
swift test --filter OnDeviceLanguageServiceTests
```

- [ ] **Step 3: Define the injected service**

```swift
public struct LocalModelCapabilities: Equatable, Sendable {
    public let contextSize: Int
    public let promptBand: String
    public let osBuild: String
}

public protocol OnDeviceGenerating: Sendable {
    func capabilities(locale: Locale) async -> Result<LocalModelCapabilities, LocalModelFailure>
    func generate<Output: Generable & Sendable>(
        _ type: Output.Type, instructions: String, prompt: String
    ) async throws -> Output
}
```

The live implementation uses `SystemLanguageModel.default`,
`model.availability`, `model.supportsLocale`, `model.contextSize`,
`LanguageModelSession`, and guided generation. Prompt selection uses
`#available(macOS 27, *)`, then 26.4, then 26.0.

- [ ] **Step 4: Add bounded prewarming**

Add `prepareForLikelyUse()` and `releaseIdleResources()`; keep session ownership
inside the actor and test that repeated prepare calls are idempotent.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter OnDeviceLanguageServiceTests
swift build
git add Sources/MustardKit/Voice Tests/MustardTests/OnDeviceLanguageServiceTests.swift
git commit -m "feat(voice): add on-device language service" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 6: Add Voice Setup and final verification

**Files:**
- Create: `Sources/MustardKit/Voice/VoicePermissionStatus.swift`
- Create: `Sources/MustardKit/Views/VoiceSetupView.swift`
- Modify: `Sources/MustardKit/Views/RootView.swift`
- Test: `Tests/MustardTests/VoicePermissionStatusTests.swift`
- Modify: `README.md`

- [ ] **Step 1: Write failing independent-permission tests**

Verify microphone, speech, accessibility, system audio, and calendar states
remain independent and produce the correct settings route.

- [ ] **Step 2: Implement status aggregation**

```swift
public struct VoicePermissionStatus: Equatable {
    public var microphone: GrantState
    public var speech: GrantState
    public var accessibility: GrantState
    public var systemAudio: GrantState
    public var calendar: GrantState
}
```

Add per-row explanation, current state, Request/Open Settings action, and a
speech asset readiness row. Do not request every permission on launch.

- [ ] **Step 3: Run verification**

```bash
swift test
swift build
./build-app.sh
```

Expected: all tests pass, build succeeds, and `build/Mustard.app` is assembled.
Leon manually confirms setup states on macOS 27 beta.

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Voice/VoicePermissionStatus.swift Sources/MustardKit/Views/VoiceSetupView.swift Sources/MustardKit/Views/RootView.swift Tests/MustardTests/VoicePermissionStatusTests.swift README.md
git commit -m "feat(voice): add voice capability setup" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```
