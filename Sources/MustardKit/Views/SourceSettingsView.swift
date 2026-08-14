import SwiftUI
import AppKit

/// Minimal multi-project source settings: the KB folders Mustard sweeps on a
/// schedule, one project per KB. Each row is an isolated source (its own cwd,
/// interval, and state). Build + eye-verified (not unit-tested — it's a view).
/// Google Calendar lives in its own `CalendarSettingsView` (settings spec
/// 2026-08-12) — this view is projects-only.
struct SourceSettingsView: View {
    @State private var settings: SourceSettings = SourceSettingsStore.loadOrMigrate()
    @State private var codeHeroesSettings = CodeHeroesQueueSettingsStore.load()
    @Environment(AgentService.self) private var agent

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

            codeHeroesSection
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    // MARK: - Code Heroes decision queue

    @ViewBuilder
    private var codeHeroesSection: some View {
        Divider().padding(.vertical, 8)

        HStack {
            Text("CODE HEROES DECISION QUEUE")
                .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer()
            Toggle("Automatic refresh preference", isOn: Binding(
                get: { codeHeroesSettings.enabled },
                set: { codeHeroesSettings.enabled = $0; persistCodeHeroesSettings() }
            ))
            .font(Theme.Fonts.caption)
            .toggleStyle(.switch)
            .controlSize(.mini)
        }

        Text("Phase 6A refreshes this read-only repository projection manually. The automatic-refresh preference is saved for a later phase.")
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        codeHeroesPathRow(
            label: "Repository root",
            placeholder: "/path/to/Code Heroes",
            value: Binding(
                get: { codeHeroesSettings.repositoryRoot },
                set: { codeHeroesSettings.repositoryRoot = $0; persistCodeHeroesSettings() }
            ),
            choose: chooseCodeHeroesRepositoryRoot
        )
        codeHeroesPathRow(
            label: "Queue file",
            placeholder: "/path/to/decision-queue.json",
            value: Binding(
                get: { codeHeroesSettings.queuePath },
                set: { codeHeroesSettings.queuePath = $0; persistCodeHeroesSettings() }
            ),
            choose: chooseCodeHeroesQueue
        )

        HStack(spacing: 8) {
            Button {
                Task { await agent.importCodeHeroesDecisionQueue(settings: codeHeroesSettings) }
            } label: {
                if agent.isImportingCodeHeroesQueue {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh now", systemImage: "arrow.clockwise")
                }
            }
            .font(Theme.Fonts.meta)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!CodeHeroesQueueRefreshPresentation.canRefresh(
                settings: codeHeroesSettings,
                isImporting: agent.isImportingCodeHeroesQueue
            ))

            if codeHeroesSettings.enabled {
                Text("Manual refresh remains available while the preference is on.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                Text("Manual refresh works while automatic refresh is off.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }

        if let error = agent.lastCodeHeroesImportError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        } else if let summary = agent.lastCodeHeroesImportSummary {
            Label(summary, systemImage: "checkmark.circle.fill")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.done)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeHeroesPathRow(
        label: String,
        placeholder: String,
        value: Binding<String>,
        choose: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: 7) {
                TextField(placeholder, text: value)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Fonts.meta)
                Button("Choose…", action: choose)
                    .controlSize(.small)
            }
        }
    }

    private func chooseCodeHeroesRepositoryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        codeHeroesSettings.repositoryRoot = url.path
        persistCodeHeroesSettings()
    }

    private func chooseCodeHeroesQueue() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !codeHeroesSettings.repositoryRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: codeHeroesSettings.repositoryRoot, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        codeHeroesSettings.queuePath = url.path
        persistCodeHeroesSettings()
    }

    private func persistCodeHeroesSettings() {
        CodeHeroesQueueSettingsStore.save(codeHeroesSettings)
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
