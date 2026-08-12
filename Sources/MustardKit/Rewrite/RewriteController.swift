#if os(macOS)
import AppKit
import ApplicationServices
import FoundationModels
import SwiftUI

/// Owns the whole ⌃⌥R surface: the live coordinator, the Carbon chord, and the
/// one non-activating panel the card lives in. Sibling of
/// `SystemDictationCoordinator.live()` — `MustardApp` only calls `activate()`.
///
/// Every decision still lives in the pure units (`RewriteGate`,
/// `SelectionLadder`, `RewriteCoordinator`); this file is wiring and window
/// management only.
@available(macOS 26.0, *)
@MainActor
public final class RewriteController {
    public let coordinator: RewriteCoordinator

    private let hotKey = RewriteHotKey()
    private var panel: RewriteCardPanel?
    private var isObserving = false
    private let openVoiceSetup: () -> Void

    /// The chord registration, so a conflict can be surfaced rather than
    /// silently leaving ⌃⌥R dead.
    public var registration: HotKeyRegistration? { hotKey.registration }

    public init(coordinator: RewriteCoordinator, openVoiceSetup: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.openVoiceSetup = openVoiceSetup
    }

    /// Production wiring: live AX reader, live selection reader, the on-device
    /// model, and dictation's verified inserter.
    public static func live(openVoiceSetup: @escaping () -> Void = {}) -> RewriteController {
        let selectionReader = AccessibilitySelectionReader.live()
        let focusReader = AccessibilityFocusReader.live()
        let restorer = SelectionRestorer.live(reader: focusReader)
        let inserter = TextInserter.live(reader: focusReader)
        let language = OnDeviceLanguageService.live()

        // Loaded once: the prompt text does not change while the app runs.
        let instructions = RewriteWiring.bandInstructions()

        let coordinator = RewriteCoordinator(
            // `RewriteRoles.textual`, not dictation's narrower set: without it
            // an AXWebArea (Gmail, Slack) would be refused before it is read.
            snapshotFocus: { try? focusReader.snapshot(roles: RewriteRoles.textual) },
            focusedRole: { RewriteWiring.focusedRole() },
            hasAccessibility: { AXIsProcessTrusted() },
            applicationName: { pid in
                NSRunningApplication(processIdentifier: pid)?.localizedName ?? "that app"
            },
            maxWords: {
                RewriteBudget.maxWords(contextSize: SystemLanguageModel.default.contextSize)
            },
            bandInstructions: { instructions },
            readSelection: { await selectionReader.read($0) },
            generate: { selection, intent in
                try await language.generate(
                    RewriteDraft.self,
                    instructions: RewritePrompt.instructions(
                        intent: intent, bandInstructions: instructions, styleRules: []),
                    prompt: RewritePrompt.prompt(selection: selection))
            },
            reassertSelection: { restorer.reassert(on: $0) },
            writeBack: { text, target in await inserter.insert(text, into: target) })

        return RewriteController(coordinator: coordinator, openVoiceSetup: openVoiceSetup)
    }

    /// Claim the chord and start mirroring phase into the panel.
    @discardableResult
    public func activate() -> HotKeyRegistration {
        hotKey.onPress = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.invoke(intent: .default) }
        }
        let registration = hotKey.register()
        startObserving()
        return registration
    }

    public func deactivate() {
        isObserving = false
        hotKey.unregister()
        hidePanel()
    }

    // MARK: - Panel

    /// The card is a pure function of `phase`, so the panel simply follows it:
    /// anything but `.idle` is on screen.
    ///
    /// Driven by `withObservationTracking` rather than a poll — a timer would
    /// wake the CPU forever for a surface that is idle almost all the time.
    /// `onChange` fires *before* the new value is stored, so the re-read and
    /// the re-subscription both happen on the next main-actor hop.
    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        syncPanel()
        observePhase()
    }

    private func observePhase() {
        withObservationTracking {
            _ = coordinator.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                // `deactivate()` clears the flag, which is what stops this
                // chain re-arming itself for the life of the process.
                guard let self, self.isObserving else { return }
                self.syncPanel()
                self.observePhase()
            }
        }
    }

    private func syncPanel() {
        if case .idle = coordinator.phase { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        if panel == nil {
            let panel = RewriteCardPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 220))
            panel.contentView = NSHostingView(rootView: RewriteCardView(
                coordinator: coordinator, openVoiceSetup: openVoiceSetup))
            self.panel = panel
        }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - 120))
        }
        // Ordered front and made key WITHOUT activating Mustard: the card needs
        // return/esc, but `NSApp.activate` would pull the whole app forward and
        // disturb the selection being rewritten.
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }
}
#endif
