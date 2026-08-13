import SwiftUI

/// Settings → HOTKEYS: one recorder row per action, grouped by where the chord
/// works, live registration status for the global four, the triage snooze
/// preset, and a reset-all footer.
struct HotKeySettingsSection: View {
    @Environment(HotKeyBindingsStore.self) private var hotKeys
    @AppStorage(TriageSnoozePreset.storageKey) private var snoozePreset = TriageSnoozePreset.default.rawValue

    private struct Group: Identifiable {
        let scope: HotKeyAction.Scope
        let caption: String
        var id: String { caption }
        var actions: [HotKeyAction] { HotKeyAction.allCases.filter { $0.scope == scope } }
    }

    private let groups: [Group] = [
        Group(scope: .global, caption: "Anywhere on the Mac"),
        Group(scope: .inApp, caption: "While Mustard is frontmost"),
        Group(
            scope: .triage,
            caption: "Agent console — single keys, ignored while you're typing"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOTKEYS")
                .font(Theme.Fonts.sectionHeader).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)

            ForEach(groups) { group in
                Text(group.caption)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, 6)
                ForEach(group.actions) { action in
                    row(action)
                    if action == .triageSnooze { snoozeLengthRow }
                }
            }

            Button("Reset all to defaults") { hotKeys.resetAll() }
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)
                .padding(.top, 6)
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

    /// How far the snooze key defers — it has no menu to pick from, unlike the
    /// console's Snooze button.
    private var snoozeLengthRow: some View {
        HStack(spacing: 10) {
            Text("Snooze key defers by")
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Picker("", selection: $snoozePreset) {
                ForEach(TriageSnoozePreset.allCases) { preset in
                    Text(preset.label).tag(preset.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.leading, 14)
    }

    /// Live rebind status if the user changed this chord this session,
    /// otherwise the launch-time registration from the shared board.
    private func registration(for action: HotKeyAction) -> HotKeyRegistration? {
        if let live = hotKeys.globalStatus[action] { return live }
        guard let purpose = action.registrationPurpose else { return nil }
        return PushToTalkHotKey.registrationBoard[purpose]?.registration
    }
}
