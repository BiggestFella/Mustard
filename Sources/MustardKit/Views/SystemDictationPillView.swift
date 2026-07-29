#if os(macOS)
import SwiftUI
import AppKit

/// The floating system-dictation pill (Dictation Task 5, BAK-291): live
/// transcript while ⌃⌥D is held, then inserting/inserted/refused states.
/// Renders `SystemDictationCoordinator` state only. The panel is
/// nonactivating — dictation must never steal focus from the field being
/// dictated into; the recoverable Copy / Try Current Field buttons are the
/// only interactive affordances.
public struct SystemDictationPillView: View {
    private let coordinator: SystemDictationCoordinator
    @State private var pulsing = false
    @State private var copied = false

    public init(coordinator: SystemDictationCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        HStack(spacing: 10) {
            icon
            text
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .elevation(.float, cornerRadius: 28)
        .padding(8)
        .animation(Theme.Motion.settle, value: coordinator.phase)
    }

    @ViewBuilder private var icon: some View {
        switch coordinator.phase {
        case .listening:
            Image(systemName: "waveform")
                .foregroundStyle(Theme.Palette.accent)
                .scaleEffect(pulsing ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
                .onDisappear { pulsing = false }
        case .inserting:
            ProgressView().controlSize(.small)
        case .inserted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.done)
        case .recoverable:
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Theme.Palette.warning)
        case .denied:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.Palette.warning)
        case .idle:
            Image(systemName: "waveform").foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    @ViewBuilder private var text: some View {
        switch coordinator.phase {
        case .listening:
            Text(coordinator.liveTranscript.isEmpty ? "Listening…" : coordinator.liveTranscript)
                .font(Theme.Fonts.body)
                .foregroundStyle(coordinator.liveTranscript.isEmpty
                                 ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                .lineLimit(2)
        case .inserting:
            Text("Inserting…")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        case .inserted:
            Text("Inserted")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textPrimary)
        case .recoverable(let reason), .denied(let reason):
            Text(reason)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(3)
        case .idle:
            Text("")
        }
    }

    /// Recovery affordances — the words are preserved on the coordinator; the
    /// user can copy them or aim at a newly focused field and retry.
    @ViewBuilder private var actions: some View {
        if case .recoverable = coordinator.phase, coordinator.recoveredTranscript != nil {
            Spacer(minLength: 4)
            Button(copied ? "Copied" : "Copy") {
                guard let transcript = coordinator.recoveredTranscript else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript, forType: .string)
                copied = true
            }
            .buttonStyle(.plain)
            .font(Theme.Fonts.meta)
            .foregroundStyle(Theme.Palette.accent)
            Button("Try Current Field") {
                copied = false
                coordinator.retryIntoCurrentField()
            }
            .buttonStyle(.plain)
            .font(Theme.Fonts.meta)
            .foregroundStyle(Theme.Palette.accent)
        }
    }
}
#endif
