import SwiftUI

/// Settings → HOTKEYS: one recorder row per action, live registration status
/// for the global three, and a reset-all footer.
struct HotKeySettingsSection: View {
    @Environment(HotKeyBindingsStore.self) private var hotKeys

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOTKEYS")
                .font(Theme.Fonts.sectionHeader).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)

            ForEach(HotKeyAction.allCases) { action in
                row(action)
            }

            Button("Reset all to defaults") { hotKeys.resetAll() }
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)

            Text("The first three work anywhere on the Mac; the rest while Mustard is frontmost.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func row(_ action: HotKeyAction) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.label)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if case .conflict = registration(for: action) {
                    Text("In use by another app — pick a different chord, or free it there.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.error)
                }
            }
            Spacer()
            HotKeyRecorderView(action: action)
        }
    }

    /// Live rebind status if the user changed this chord this session,
    /// otherwise the launch-time registration from the shared board.
    private func registration(for action: HotKeyAction) -> HotKeyRegistration? {
        if let live = hotKeys.globalStatus[action] { return live }
        guard let purpose = action.registrationPurpose else { return nil }
        return PushToTalkHotKey.registrationBoard[purpose]?.registration
    }
}
