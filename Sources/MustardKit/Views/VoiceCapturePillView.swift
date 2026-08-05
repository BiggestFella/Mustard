#if os(macOS)
import SwiftUI

/// The floating push-to-talk pill (F25 v1): live transcript while the hotkey is
/// held, then a brief committed/cancelled flash. Renders `VoiceTaskCaptureCoordinator`
/// state only — every decision lives in the pure `VoiceCapture`.
public struct VoiceCapturePillView: View {
    private let controller: VoiceTaskCaptureCoordinator
    @State private var pulsing = false

    public init(controller: VoiceTaskCaptureCoordinator) {
        self.controller = controller
    }

    public var body: some View {
        HStack(spacing: 10) {
            icon
            text
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .elevation(.float, cornerRadius: 28)   // bg ground + hairline + soft shadow
        .padding(8)
        .animation(Theme.Motion.settle, value: controller.phase)
        // Escape hatch: the panel is non-activating (it must never steal focus
        // mid-capture), so a click is the only input it can reliably take.
        // Whatever goes wrong, one click always dismisses and frees the mic.
        .contentShape(Rectangle())
        .onTapGesture { controller.abandon() }
        .help("Click to cancel this capture")
    }

    @ViewBuilder private var icon: some View {
        switch controller.phase {
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(Theme.Palette.accent)
                .scaleEffect(pulsing ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
                .onDisappear { pulsing = false }
        case .finalizing:
            ProgressView().controlSize(.small)
        case .committed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.done)
        case .cancelled:
            Image(systemName: "mic.slash").foregroundStyle(Theme.Palette.textTertiary)
        case .denied, .unavailable:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.Palette.warning)
        case .idle:
            Image(systemName: "mic").foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    @ViewBuilder private var text: some View {
        switch controller.phase {
        case .recording:
            Text(controller.liveTranscript.isEmpty ? "Listening…" : controller.liveTranscript)
                .font(Theme.Fonts.body)
                .foregroundStyle(controller.liveTranscript.isEmpty
                                 ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                .lineLimit(2)
        case .finalizing:
            Text("Finishing…")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        case .committed(let title):
            Text("Added — \(title)")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
        case .cancelled:
            Text("Nothing captured")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textTertiary)
        case .denied:
            Text("Allow the microphone and speech recognition in System Settings → Privacy")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
        case .unavailable(let reason):
            Text(reason)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
        case .idle:
            Text("")
        }
    }
}
#endif
