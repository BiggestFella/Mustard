#if os(macOS)
import SwiftUI

/// Manual meeting-recorder controls inside the expanded notch (Meetings
/// Task 6, BAK-298). The notch is intentionally dark (explicit hex, not
/// Theme — see CLAUDE.md); every decision lives in
/// `MeetingCaptureCoordinator`, this view only renders and dispatches.
/// Consent is explicit: Start Meeting only raises the prompt; recording
/// begins on Confirm and never otherwise.
public struct MeetingRecordingNotchView: View {
    @Environment(MeetingCaptureCoordinator.self) private var recorder: MeetingCaptureCoordinator?

    public init() {}

    public var body: some View {
        if let recorder {
            content(recorder)
        }
    }

    @ViewBuilder
    private func content(_ recorder: MeetingCaptureCoordinator) -> some View {
        switch recorder.state {
        case .idle:
            Button {
                Task { await recorder.requestStart(title: "Meeting") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 11, weight: .medium))
                    Text("Start Meeting")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        case .preparing:
            consentCard(recorder)

        case .recording(let startedAt):
            HStack(spacing: 8) {
                Circle().fill(Color(hex: "#FF5F57")).frame(width: 7, height: 7)
                Text(recorder.activeMeeting?.title ?? "Recording")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(Self.elapsed(from: startedAt, to: timeline.date))
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                if case .paused(let reason) = recorder.sourceState(.systemAudio) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: "#FFBD2E"))
                        .help("Meeting audio paused: \(reason)")
                }
                Spacer(minLength: 4)
                notchButton("pause.fill") { Task { await recorder.pause() } }
                notchButton("stop.fill") { Task { await recorder.stop() } }
            }

        case .paused:
            HStack(spacing: 8) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#FFBD2E"))
                Text("Recording paused")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 4)
                notchButton("play.fill") { Task { await recorder.resume() } }
                notchButton("stop.fill") { Task { await recorder.stop() } }
            }

        case .finalizingAudio, .finalizingTranscript, .summarizing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Finishing the recording…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }

        case .ready:
            statusRow(recorder, icon: "checkmark.circle.fill",
                      color: "#5DCAA5", text: "Meeting saved")

        case .partial(let reason):
            statusRow(recorder, icon: "exclamationmark.triangle",
                      color: "#FFBD2E", text: reason)

        case .failed(let reason):
            statusRow(recorder, icon: "exclamationmark.triangle",
                      color: "#FF5F57", text: reason)
        }
    }

    /// Explicit consent (spec: the app never records a meeting without a
    /// user confirmation, and says what it captures).
    private func consentCard(_ recorder: MeetingCaptureCoordinator) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Record this meeting?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            switch recorder.pendingConfirmation {
            case .consent:
                Text("Records your microphone and everything playing on this Mac. A red indicator stays visible while recording; audio never leaves this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            case .degraded(let available, let missing):
                Text("Only \(available.map(Self.label).joined(separator: " + ")) is available — \(missing.map(Self.label).joined(separator: ", ")) needs a grant in Voice Setup. Record anyway?")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#FFBD2E"))
            case nil:
                EmptyView()
            }
            HStack(spacing: 10) {
                Button {
                    let sources: [MeetingAudioSource]
                    switch recorder.pendingConfirmation {
                    case .consent(let all): sources = all
                    case .degraded(let available, _): sources = available
                    case nil: sources = []
                    }
                    Task { await recorder.confirmStart(sources: sources) }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: "#FF5F57")).frame(width: 6, height: 6)
                        Text("Start recording").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button("Cancel") { recorder.cancelStart() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func statusRow(
        _ recorder: MeetingCaptureCoordinator, icon: String, color: String, text: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: color))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Done") { recorder.reset() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func notchButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private static func label(_ source: MeetingAudioSource) -> String {
        switch source {
        case .microphone: "your microphone"
        case .systemAudio: "meeting audio"
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif
