import SwiftUI
import AppKit
import AVFoundation
import Speech
import EventKit
import ApplicationServices

/// Async probes behind the Voice Setup surface, injected so the view never
/// touches TCC in previews or headless builds. `readStatus` is passive —
/// it must never fire an OS prompt (the surface can be opened casually;
/// spec §Permissions: do not request every permission on launch). Prompts
/// happen only through `request`, one capability at a time, on user action.
public struct VoiceSetupProbes {
    public var readStatus: @Sendable () async -> VoicePermissionStatus
    /// Fires the OS prompt for one capability and returns the resulting state.
    public var request: @Sendable (VoiceCapability) async -> GrantState
    /// Resolves the locale and installs on-device speech assets (a no-op when
    /// installed). Explicit user action — may download.
    public var prepareAssets: @Sendable () async -> VoiceReadiness

    public init(
        readStatus: @escaping @Sendable () async -> VoicePermissionStatus,
        request: @escaping @Sendable (VoiceCapability) async -> GrantState,
        prepareAssets: @escaping @Sendable () async -> VoiceReadiness
    ) {
        self.readStatus = readStatus
        self.request = request
        self.prepareAssets = prepareAssets
    }

    /// Production probes. Speech-recognition TCC is read/requested through the
    /// `SFSpeechRecognizer` class methods — the OS has no other surface for
    /// that grant; transcription itself stays on SpeechAnalyzer (ADR: never
    /// SFSpeechRecognizer as an engine). Accessibility and screen capture are
    /// boolean checks: Accessibility can only be granted in System Settings
    /// (read maps false → `.denied`, so the row routes there), and an unasked
    /// screen-capture grant reads `.notDetermined` so its row may prompt once.
    public static func live(locale: Locale = .current) -> VoiceSetupProbes {
        VoiceSetupProbes(
            readStatus: {
                VoicePermissionStatus(
                    microphone: GrantState(av: AVCaptureDevice.authorizationStatus(for: .audio)),
                    speech: GrantState(sf: SFSpeechRecognizer.authorizationStatus()),
                    accessibility: AXIsProcessTrusted() ? .granted : .denied,
                    // The OS exposes only a boolean here and prompts at most
                    // once; a persisted asked-flag disambiguates "never asked"
                    // (Request may prompt) from "refused" (only System
                    // Settings can fix it).
                    systemAudio: CGPreflightScreenCaptureAccess()
                        ? .granted
                        : (UserDefaults.standard.bool(forKey: "voiceRequestedScreenCapture")
                            ? .denied : .notDetermined),
                    calendar: GrantState(ek: EKEventStore.authorizationStatus(for: .event))
                )
            },
            request: { capability in
                switch capability {
                case .microphone:
                    return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
                case .speech:
                    return await withCheckedContinuation { continuation in
                        SFSpeechRecognizer.requestAuthorization { status in
                            continuation.resume(returning: GrantState(sf: status))
                        }
                    }
                case .accessibility:
                    // No in-app grant exists; the row shows Open Settings instead.
                    return AXIsProcessTrusted() ? .granted : .denied
                case .systemAudio:
                    UserDefaults.standard.set(true, forKey: "voiceRequestedScreenCapture")
                    return CGRequestScreenCaptureAccess() ? .granted : .denied
                case .calendar:
                    let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
                    return granted ? .granted : .denied
                }
            },
            prepareAssets: {
                await VoiceAssetReadiness.live().prepare(locale: locale)
            }
        )
    }
}

/// Voice Setup (Voice Core Task 6, BAK-280): explains and reports the five
/// voice permissions independently, with the exact System Settings route for
/// anything refused, plus the on-device speech-asset readiness row. Statuses
/// are re-read when the app becomes active again, so a trip to System
/// Settings reflects here without a manual refresh.
public struct VoiceSetupView: View {
    private let probes: VoiceSetupProbes
    @State private var status = VoicePermissionStatus()
    @State private var assets = AssetRowState.unknown
    @State private var requesting: VoiceCapability?

    public init(probes: VoiceSetupProbes = .live()) {
        self.probes = probes
    }

    private enum AssetRowState: Equatable {
        case unknown, preparing
        case result(VoiceReadiness)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Voice Setup")
                        .font(Theme.Fonts.header)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Everything voice runs on this Mac — audio and transcripts never leave it. Each permission powers one feature, so denying one only pauses that feature.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("PERMISSIONS")
                    ForEach(VoiceCapability.allCases) { capability in
                        permissionRow(capability)
                        if capability != VoiceCapability.allCases.last {
                            Divider().overlay(Theme.Palette.hairline)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("ON-DEVICE SPEECH ASSETS")
                    assetRow
                }

                if !PushToTalkHotKey.registrationBoard.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("SHORTCUTS")
                        ForEach(PushToTalkHotKey.registrationBoard.keys.sorted(), id: \.self) { purpose in
                            shortcutRow(purpose: purpose)
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Theme.Palette.bg)
        .task { status = await probes.readStatus() }
        // Coming back from System Settings re-activates the app; re-read so
        // grants flipped there show up without a refresh control.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { status = await probes.readStatus() }
        }
    }

    /// One chord's registration outcome — a conflict is shown with the failed
    /// shortcut and the route to change it (spec: never silent).
    @ViewBuilder
    private func shortcutRow(purpose: String) -> some View {
        if let entry = PushToTalkHotKey.registrationBoard[purpose] {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(purpose) — \(entry.chord)")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if case .conflict = entry.registration {
                        Text("Another app already owns \(entry.chord). Change Mustard's chord (defaults: voiceHotKeyCode / dictationHotKeyCode) and relaunch, or free it in the other app.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 12)
                switch entry.registration {
                case .registered:
                    Label("Active", systemImage: "checkmark")
                        .foregroundStyle(Theme.Palette.done)
                        .font(Theme.Fonts.meta)
                case .conflict:
                    Label("In use by another app", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Palette.warning)
                        .font(Theme.Fonts.meta)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold)).tracking(0.06)
            .foregroundStyle(Theme.Palette.textTertiary)
    }

    private func permissionRow(_ capability: VoiceCapability) -> some View {
        let state = status[capability]
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(capability.explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer(minLength: 12)
            stateLabel(state)
            actionButton(for: capability, state: state)
        }
    }

    private func stateLabel(_ state: GrantState) -> some View {
        Group {
            switch state {
            case .granted:
                Label("Granted", systemImage: "checkmark")
                    .foregroundStyle(Theme.Palette.done)
            case .notDetermined:
                Text("Not yet asked")
                    .foregroundStyle(Theme.Palette.textTertiary)
            case .denied:
                Text("Denied")
                    .foregroundStyle(Theme.Palette.textSecondary)
            case .restricted:
                Text("Restricted")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .font(Theme.Fonts.meta)
    }

    @ViewBuilder
    private func actionButton(for capability: VoiceCapability, state: GrantState) -> some View {
        switch state.setupAction {
        case .request:
            Button(requesting == capability ? "Requesting…" : "Request…") {
                requesting = capability
                Task {
                    status[capability] = await probes.request(capability)
                    requesting = nil
                }
            }
            .disabled(requesting != nil)
        case .openSettings:
            Button("Open Settings…") {
                NSWorkspace.shared.open(capability.settingsPane)
            }
        case .none:
            EmptyView()
        }
    }

    private var assetRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Speech model")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("The on-device transcription model for your language. Installing may download once; after that it works offline.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer(minLength: 12)
            switch assets {
            case .unknown:
                Text("Not checked")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Button("Check & Install…") { prepareAssets() }
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Preparing…")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
            case .result(let readiness):
                assetResultLabel(readiness)
                if case .ready = readiness {} else {
                    Button("Retry…") { prepareAssets() }
                }
            }
        }
    }

    @ViewBuilder
    private func assetResultLabel(_ readiness: VoiceReadiness) -> some View {
        Group {
            switch readiness {
            case .ready:
                Label("Ready", systemImage: "checkmark")
                    .foregroundStyle(Theme.Palette.done)
            case .needsAssetDownload:
                Text("Download needed")
                    .foregroundStyle(Theme.Palette.textSecondary)
            case .permissionDenied:
                Text("Blocked by a permission above")
                    .foregroundStyle(Theme.Palette.textSecondary)
            case .unsupportedLocale:
                Text("Language not supported on-device")
                    .foregroundStyle(Theme.Palette.textSecondary)
            case .unavailable(let reason):
                Text(reason)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
            }
        }
        .font(Theme.Fonts.meta)
    }

    private func prepareAssets() {
        assets = .preparing
        Task { assets = .result(await probes.prepareAssets()) }
    }
}

// MARK: - Framework status → GrantState adapters (view-side; the Voice types stay pure)

private extension GrantState {
    init(av status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }

    init(sf status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }

    init(ek status: EKAuthorizationStatus) {
        switch status {
        case .fullAccess: self = .granted
        // Write-only can't read events, so meeting suggestions stay off.
        case .writeOnly, .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }
}

#Preview {
    VoiceSetupView(probes: VoiceSetupProbes(
        readStatus: {
            VoicePermissionStatus(
                microphone: .granted,
                speech: .notDetermined,
                accessibility: .denied,
                systemAudio: .notDetermined,
                calendar: .restricted
            )
        },
        request: { _ in .granted },
        prepareAssets: { .ready }
    ))
    .frame(width: 760, height: 560)
}
