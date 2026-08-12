import SwiftUI
import SwiftData

/// Standalone Settings screen (BAK-133): Sources + Trust, reachable from the sidebar ⚙.
/// Trust is intentionally surfaced here AND in the Agent header (CLAUDE.md — "surfaced
/// in the Agent header pill and Settings"); both bind the same @AppStorage, so they
/// stay in sync.
public struct SettingsView: View {
    @Environment(AgentService.self) private var agent
    @AppStorage("trustLevel") private var trustRaw = TrustLevel.manual.rawValue
    private var trust: TrustLevel { TrustLevel(rawValue: trustRaw) ?? .manual }

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

                // Sources (its own "PROJECTS" header + connect affordances).
                SourceSettingsView()
                CalendarSettingsView()

                VStack(alignment: .leading, spacing: 10) {
                    Text("TRUST")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Picker("", selection: Binding(
                        get: { trust },
                        set: { level in
                            trustRaw = level.rawValue
                            Task { await agent.applyTrust(level) }
                        }
                    )) {
                        ForEach(TrustLevel.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).tint(Theme.Palette.agent).fixedSize()
                    Text(trust.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text("🔒 Email, Slack and tickets are always reviewed by you — at every trust level.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("VOICE")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.06)
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
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Theme.Palette.bg)
    }
}
