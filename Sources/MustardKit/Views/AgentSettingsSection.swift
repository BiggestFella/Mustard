import AppKit
import SwiftUI

/// SOURCES & AGENT: the vaults the sweeps read, the per-project schedule,
/// sweep-now, trust, and auto-open-source. Moved here from the Agent console
/// (settings spec 2026-08-12) — the console is pure triage now.
struct AgentSettingsSection: View {
    @Environment(AgentService.self) private var agent
    @AppStorage("vaultPath") private var vaultPath = ""
    @AppStorage("meetingVaultPath") private var meetingVaultPath = ""
    @AppStorage("trustLevel") private var trustRaw = TrustLevel.manual.rawValue
    @AppStorage("autoOpenSourceOnSelect") private var autoOpenSource = true

    private var trust: TrustLevel { TrustLevel(rawValue: trustRaw) ?? .manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SOURCES & AGENT")
                .font(Theme.Fonts.sectionHeader).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)

            vaultRow
            meetingRow
            SourceSettingsView()
            trustBlock

            Toggle(isOn: $autoOpenSource) {
                Text("Auto-open source").font(Theme.Fonts.meta)
            }
            .toggleStyle(.switch).controlSize(.mini)
            .help("When on, selecting a recommendation that has a source also opens it in the side panel.")

            if let error = agent.lastError {
                Text(error)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.error)
            }
        }
    }

    private var vaultRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(vaultPath.isEmpty ? "Choose your knowledge base folder…" : vaultPath)
                .font(Theme.Fonts.meta)
                .foregroundStyle(vaultPath.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    vaultPath = url.path
                }
            }
            .controlSize(.small)
            Spacer()
            Button {
                Task { await agent.sweep(vaultPath: vaultPath) }
            } label: {
                if agent.isSweeping {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Sweeping…")
                    }
                } else {
                    Label("✦ Sweep", systemImage: "wand.and.stars")
                }
            }
            .disabled(vaultPath.isEmpty || agent.isSweeping)
            .tint(Theme.Palette.accent)
        }
    }

    private var meetingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(meetingVaultPath.isEmpty ? "Choose your meeting-notes vault…" : meetingVaultPath)
                .font(Theme.Fonts.meta)
                .foregroundStyle(meetingVaultPath.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    meetingVaultPath = url.path
                }
            }
            .controlSize(.small)
            Spacer()
            if let summary = agent.lastMeetingSummary {
                Text(summary)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private var trustBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            .help(trust.blurb)
            Text(trust.blurb)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("🔒 Email, Slack and tickets are always reviewed by you — at every trust level.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.top, 4)
    }
}
