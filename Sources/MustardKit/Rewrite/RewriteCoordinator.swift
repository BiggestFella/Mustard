// macOS-only: `RewriteDraft` is guided-generation output, which does not exist
// on the iOS floor this package also compiles against.
#if os(macOS)
import Foundation
import Observation

/// Sequences one rewrite: snapshot → gate → read → gate → generate → review →
/// accept → re-assert → write. Every OS edge is an injected closure, so the
/// ordering guarantees in the spec are unit-testable without AX or a model.
///
/// Ordering that is load-bearing, not incidental:
/// - `RewriteGate.admits` runs BEFORE `readSelection`, because read rung 3
///   synthesizes ⌘C into the target and must never reach a password field.
/// - `reassertSelection` runs immediately BEFORE `writeBack`, so the write
///   lands on the range that was snapshotted rather than on whatever the app
///   left selected while the card had key focus.
@available(macOS 26.0, iOS 26.0, *)
@MainActor
@Observable
public final class RewriteCoordinator {
    public private(set) var phase: RewritePhase = .idle

    private let snapshotFocus: () -> FocusedTextTarget?
    private let focusedRole: () -> String?
    private let hasAccessibility: () -> Bool
    private let applicationName: (pid_t) -> String
    private let maxWords: () -> Int
    private let bandInstructions: () -> String
    private let readSelection: (FocusedTextTarget) async -> SelectionLadder.Resolution
    private let generate: (String, RewriteIntent) async throws -> RewriteDraft
    private let reassertSelection: (FocusedTextTarget) -> SelectionRestorer.Outcome
    private let writeBack: (String, FocusedTextTarget) async -> TextInsertionOutcome

    public init(
        snapshotFocus: @escaping () -> FocusedTextTarget?,
        focusedRole: @escaping () -> String?,
        hasAccessibility: @escaping () -> Bool,
        applicationName: @escaping (pid_t) -> String,
        maxWords: @escaping () -> Int,
        bandInstructions: @escaping () -> String,
        readSelection: @escaping (FocusedTextTarget) async -> SelectionLadder.Resolution,
        generate: @escaping (String, RewriteIntent) async throws -> RewriteDraft,
        reassertSelection: @escaping (FocusedTextTarget) -> SelectionRestorer.Outcome,
        writeBack: @escaping (String, FocusedTextTarget) async -> TextInsertionOutcome
    ) {
        self.snapshotFocus = snapshotFocus
        self.focusedRole = focusedRole
        self.hasAccessibility = hasAccessibility
        self.applicationName = applicationName
        self.maxWords = maxWords
        self.bandInstructions = bandInstructions
        self.readSelection = readSelection
        self.generate = generate
        self.reassertSelection = reassertSelection
        self.writeBack = writeBack
    }

    /// ⌃⌥R. While a review is open this is "another take" — it regenerates
    /// against the same original rather than re-snapshotting focus, which by
    /// then belongs to the card.
    public func invoke(intent: RewriteIntent) async {
        if case .reviewing(let review) = phase {
            await regenerate(review: review, intent: intent)
            return
        }

        guard let target = snapshotFocus() else {
            phase = .refused(.accessibilityPermissionMissing)
            return
        }
        let role = focusedRole()
        RewriteLog.snapshot(
            role: role, subrole: nil, range: target.selectedRange, secure: target.isSecure)

        let refusal = RewriteGate.admits(
            target: target, role: role, hasAccessibility: hasAccessibility())
        RewriteLog.gate(refusal)
        if let refusal {
            phase = .refused(refusal)
            return
        }

        phase = .reading
        let resolution = await readSelection(target)
        RewriteLog.read(
            rung: resolution.rung,
            outcome: resolution.read,
            characters: { if case .text(let text) = resolution.read { return text.count } else { return 0 } }())
        let application = applicationName(target.applicationPID)
        switch RewriteGate.accepts(
            read: resolution.read, application: application, maxWords: maxWords()) {
        case .failure(let refusal):
            phase = .refused(refusal)
        case .success(let selection):
            await produce(original: selection, intent: intent, target: target)
        }
    }

    /// 1–4 in the card.
    public func change(intent: RewriteIntent) async {
        guard case .reviewing(let review) = phase else { return }
        await regenerate(review: review, intent: intent)
    }

    /// Return in the card.
    public func accept() async {
        guard case .reviewing(var review) = phase else { return }

        let outcome = reassertSelection(review.target)
        RewriteLog.reassert(outcome)
        guard outcome.permitsWrite else {
            phase = .refused(.focusChanged)
            return
        }

        let written = await writeBack(review.rewritten, review.target)
        RewriteLog.wrote(written)
        switch written {
        case .insertedDirectly, .insertedByPaste:
            phase = .idle
        case .recoverable(let reason):
            // Keep the card open: the rewrite is still on screen and the
            // user's original is untouched in the application.
            review.writeFailure = reason
            phase = .reviewing(review)
        }
    }

    /// Esc in the card.
    public func discard() {
        phase = .idle
    }

    // MARK: - Private

    private func produce(original: String, intent: RewriteIntent, target: FocusedTextTarget) async {
        phase = .generating(intent)
        do {
            let draft = try await generate(original, intent)
            RewriteLog.generated(
                intent: intent,
                characters: draft.rewritten.count,
                band: PromptCatalog.currentBand.rawValue)
            phase = .reviewing(RewriteReview(
                original: original,
                rewritten: draft.rewritten,
                changeNote: draft.changeNote,
                intent: intent,
                target: target))
        } catch {
            phase = .refused(Self.refusal(for: error))
        }
    }

    private func regenerate(review: RewriteReview, intent: RewriteIntent) async {
        await produce(original: review.original, intent: intent, target: review.target)
    }

    /// Maps a thrown error onto the refusal vocabulary. Anything unrecognised
    /// keeps its own description rather than being flattened to "unavailable".
    static func refusal(for error: Error) -> RewriteRefusal {
        if let failure = error as? LocalModelFailure { return .model(failure) }
        if let mapped = OnDeviceLanguageService.mappedFailure(error) { return .model(mapped) }
        return .model(.unavailable(String(describing: error)))
    }
}
#endif
