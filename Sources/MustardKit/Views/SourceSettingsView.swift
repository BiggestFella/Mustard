import SwiftUI
import AppKit

/// Minimal multi-project source settings: the KB folders Mustard sweeps on a
/// schedule, one project per KB. Each row is an isolated source (its own cwd,
/// interval, and state). Build + eye-verified (not unit-tested — it's a view).
/// Google Calendar lives in its own `CalendarSettingsView` (settings spec
/// 2026-08-12) — this view is projects-only.
struct SourceSettingsView: View {
    @State private var settings: SourceSettings = SourceSettingsStore.loadOrMigrate()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROJECTS")
                    .font(Theme.Fonts.sectionHeader).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Button(action: addProject) {
                    Label("Add project…", systemImage: "plus").font(Theme.Fonts.meta)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.accent)
            }

            if settings.sources.isEmpty {
                Text("No projects yet. Add a knowledge-base folder to sweep.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            ForEach(Array(settings.sources.enumerated()), id: \.offset) { index, config in
                projectRow(index: index, config: config)
            }
        }
    }

    @ViewBuilder
    private func projectRow(index: Int, config: SourceConfig) -> some View {
        let state = settings.state.first { $0.id == config.id && $0.project == config.project }
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { settings.sources[index].enabled },
                set: { settings.sources[index].enabled = $0; persist() }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)

            VStack(alignment: .leading, spacing: 1) {
                Text(config.project.isEmpty ? "(unnamed)" : config.project)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(statusLine(config: config, state: state))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(state?.lastError != nil ? Theme.Palette.error : Theme.Palette.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            Menu(intervalLabel(config.intervalHours)) {
                Button("Off") { setInterval(index, 0) }
                Button("Hourly") { setInterval(index, 1) }
                Button("Every 4 hours") { setInterval(index, 4) }
                Button("Daily") { setInterval(index, 24) }
            }
            .controlSize(.small).fixedSize()

            Button {
                settings.sources.remove(at: index)
                persist()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove project")
        }
    }

    private func statusLine(config: SourceConfig, state: SourceState?) -> String {
        if let err = state?.lastError { return "error · \(err)" }
        let last = state?.lastSweptAt.map { " · last " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return (config.workingDirectory.isEmpty ? "no folder set" : config.workingDirectory) + last
    }

    private func intervalLabel(_ hours: Double) -> String {
        switch hours {
        case 0: return "Off"
        case 1: return "Hourly"
        case 24: return "Daily"
        default: return "\(Int(hours))h"
        }
    }

    private func setInterval(_ index: Int, _ hours: Double) {
        settings.sources[index].intervalHours = hours
        persist()
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !settings.sources.contains(where: { $0.workingDirectory == url.path }) else { return }
        settings.sources.append(
            SourceConfig(id: .vault, project: url.lastPathComponent, enabled: true,
                         intervalHours: 1, workingDirectory: url.path)
        )
        persist()
    }

    private func persist() { SourceSettingsStore.save(settings) }
}
