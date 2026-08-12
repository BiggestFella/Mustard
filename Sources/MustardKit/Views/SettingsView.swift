import SwiftData
import SwiftUI

/// The settings home (BAK-133, expanded by the 2026-08-12 settings spec):
/// sources & agent, calendar, voice, hotkeys. The Agent console is pure
/// triage — everything configurable lives here now, including trust (this is
/// its only surface since the console strip-down).
public struct SettingsView: View {
    /// Navigates to the Voice Setup screen (BAK-280); RootView owns the route.
    private let onVoiceSetup: (() -> Void)?

    public init(onVoiceSetup: (() -> Void)? = nil) {
        self.onVoiceSetup = onVoiceSetup
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(Theme.Fonts.header)
                    .foregroundStyle(Theme.Palette.textPrimary)

                AgentSettingsSection()
                CalendarSettingsView()
                voiceSection
                HotKeySettingsSection()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Theme.Palette.bg)
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VOICE")
                .font(Theme.Fonts.sectionHeader).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)
            Button {
                onVoiceSetup?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(Theme.Fonts.meta)
                    Text("Voice Setup…")
                        .font(Theme.Fonts.body)
                }
                .foregroundStyle(Theme.Palette.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Microphone, speech, accessibility, system audio and calendar permissions — plus the on-device speech model.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}
