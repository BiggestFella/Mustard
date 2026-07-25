import SwiftUI
import SwiftData
import AppKit

/// The agent console: vault source row + Recommendations queue (master-detail
/// list │ detail). Output review now lives on the board's Needs Review column
/// (ADR-0010) — there is no console review queue. Things-3-calm throughout.
public struct AgentConsoleView: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    @AppStorage("vaultPath") private var vaultPath = ""
    @AppStorage("meetingVaultPath") private var meetingVaultPath = ""
    @AppStorage("trustLevel") private var trustRaw = TrustLevel.manual.rawValue
    @AppStorage("autoOpenSourceOnSelect") private var autoOpenSource = true
    @Environment(SourcePanelController.self) private var sourcePanel
    @State private var selected: Recommendation?

    private var trust: TrustLevel { TrustLevel(rawValue: trustRaw) ?? .manual }
    @Query(sort: \Recommendation.createdAt, order: .reverse) private var recommendations: [Recommendation]

    public init() {}

    private var pending: [Recommendation] {
        RecommendationQueue.pending(recommendations, now: .now)
    }

    public var body: some View {
        HSplitView {
            masterColumn
                .frame(minWidth: 360, idealWidth: 480)
            detailColumn
                .frame(minWidth: 320, idealWidth: 420)
        }
        .background(Theme.Palette.bg)
        .onAppear {
            if selected == nil {
                selected = RecommendationSelection.nextSelection(current: nil, pending: pending)
            }
        }
        .onChange(of: pending.map(\.persistentModelID)) { _, _ in
            let next = RecommendationSelection.nextSelection(current: selected, pending: pending)
            if next !== selected { selected = next }
        }
    }

    private var masterColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                sourceRow
                meetingSourceRow
                SourceSettingsView()
                if let error = agent.lastError {
                    Text(error)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.error)
                        .padding(.vertical, 8)
                }

                sectionLabel("RECOMMENDATIONS", count: pending.count)
                if pending.isEmpty {
                    emptyLine("Nothing waiting on you. Run a sweep.")
                }
                // Rows are elevated cards (Craft pass Phase 1) — spacing separates
                // them; a hairline divider against a bordered card reads doubled.
                ForEach(SourceGrouping.grouped(pending)) { group in
                    if group.isMultiSource {
                        SourceGroupHeader(rec: group.header)
                        ForEach(group.members) { rec in
                            RecommendationRow(rec: rec, inGroup: true,
                                              isSelected: selected === rec,
                                              onSelect: { select(rec) })
                                .padding(.bottom, 8)
                        }
                    } else {
                        RecommendationRow(rec: group.header, inGroup: false,
                                          isSelected: selected === group.header,
                                          onSelect: { select(group.header) })
                            .padding(.bottom, 8)
                    }
                }

                // Output review now lives on the board's Needs Review column (ADR-0010).
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
    }

    private var detailColumn: some View {
        Group {
            if let selected {
                // Key to the selected rec so its detail view (and the @State comment
                // field inside) is rebuilt fresh per selection — no carry-over.
                ScrollView { RecommendationDetailView(rec: selected).id(selected.persistentModelID).padding(20) }
            } else {
                detailEmpty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.bg)
    }

    private var detailEmpty: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(Theme.Palette.textTertiary)
            Text(pending.isEmpty ? "Nothing waiting on you." : "Select a recommendation.")
                .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// Select a recommendation and, only on this explicit selection, auto-open its
    /// source if the setting is on and it has a web source. Programmatic re-selection
    /// (arrival / queue churn) does not auto-open — avoids surprise page loads.
    private func select(_ rec: Recommendation?) {
        selected = rec
        guard let rec,
              RecommendationSelection.shouldAutoOpenSource(settingOn: autoOpenSource, rec: rec),
              let link = SourceLink(from: rec) else { return }
        sourcePanel.open(link)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent")
                    .font(Theme.Fonts.header)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(agent.isSweeping ? "reviewing your sources…" : "plans your day with you")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            if agent.isExecuting {
                ProgressView().controlSize(.small)
                Text("working…")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Toggle(isOn: $autoOpenSource) {
                Text("Auto-open source").font(Theme.Fonts.meta)
            }
            .toggleStyle(.switch).controlSize(.mini)
            .help("When on, selecting a recommendation that has a source also opens it in the side panel.")
        }
        .padding(.bottom, 12)
    }

    /// Picker for the meeting-notes vault (Leon's "Codeheroes work/" root). Tasks
    /// harvest automatically on the 60s loop; the last digest shows here.
    private var meetingSourceRow: some View {
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
        .padding(.bottom, 4)
    }

    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            Picker("", selection: Binding(
                get: { trust },
                set: { level in
                    trustRaw = level.rawValue
                    Task { await agent.applyTrust(level) }
                }
            )) {
                ForEach(TrustLevel.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .tint(Theme.Palette.agent)
            .fixedSize()
            .help(trust.blurb)
          }
          // Always-visible trust blurb + gated-action footer note (BAK-112).
          Text(trust.blurb)
              .font(Theme.Fonts.label)
              .foregroundStyle(Theme.Palette.textSecondary)
          Text("🔒 Email, Slack and tickets are always reviewed by you — at every trust level.")
              .font(Theme.Fonts.caption)
              .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.vertical, 10)
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
            if count > 0 {
                Text("\(count)")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.agent)
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.meta)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.vertical, 12)
    }
}

/// Compact, selectable summary row for the recommendations master list. The full
/// triage workspace lives in `RecommendationDetailView` (the detail pane).
struct RecommendationRow: View {
    let rec: Recommendation
    let inGroup: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    init(rec: Recommendation, inGroup: Bool = false, isSelected: Bool = false, onSelect: @escaping () -> Void = {}) {
        self.rec = rec
        self.inGroup = inGroup
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    private var confidenceSegments: Int { Int((rec.confidence * 5).rounded(.down)) }
    private var confidenceColor: Color { Theme.confidenceColor(rec.confidence) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !inGroup { ProvenancePill(rec: rec) }
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.Palette.agent)
                Text(rec.title).font(Theme.Fonts.title).foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                if rec.action.isGated {
                    Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Theme.Palette.textTertiary)
                        .help("Email, Slack, and ticket actions are always gated regardless of trust.")
                }
                Spacer()
                SourceLinkButton(rec: rec)
            }
            HStack(spacing: 6) {
                Text(String(format: "%.2f", rec.confidence))
                    .font(Theme.Fonts.caption.weight(.medium)).foregroundStyle(confidenceColor)
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i < confidenceSegments ? confidenceColor : Theme.Palette.surface)
                            .frame(width: 14, height: 4)
                    }
                }
                Spacer()
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 11)
        // Selection tint + bar sit above the card ground; .elevation's clip rounds
        // the bar's corners with the card (Craft pass Phase 1).
        .background(isSelected ? Theme.Palette.accent.opacity(0.07) : .clear)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Theme.Palette.accent).frame(width: 2) }
        }
        .elevation(.card, cornerRadius: Theme.Metrics.rLg)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

/// Provenance pill shown above each recommendation (or group header).
struct ProvenancePill: View {
    let rec: Recommendation
    var body: some View {
        let badge = SourceBadge.badge(forRaw: rec.source)
        HStack(spacing: 6) {
            if badge.isQuiet {
                Text(badge.label.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                HStack(spacing: 4) {
                    SourceLogo(source: badge.id, size: 13)
                    Text(badge.label)
                }
                .font(Theme.Fonts.caption.weight(.medium))
                .foregroundStyle(Color(hex: badge.fgHex))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color(hex: badge.bgHex), in: Capsule())
            }
            if !rec.sourceContext.isEmpty {
                Text("· \(rec.sourceContext)").font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary).lineLimit(1)
            }
            Spacer()
            if let s = rec.sourceURL, let url = URL(string: s) {
                Link("Open ↗", destination: url).font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }
}

/// Header for a multi-source fan-out group: shows the provenance pill and,
/// if available, an expand/collapse toggle for the original email body.
struct SourceGroupHeader: View {
    let rec: Recommendation
    @State private var showEmail = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProvenancePill(rec: rec)
            if let original = rec.originalSource, !original.isEmpty {
                Button { withAnimation(Theme.Motion.settle) { showEmail.toggle() } } label: {
                    Label(showEmail ? "Hide original" : "Original email",
                          systemImage: showEmail ? "chevron.down" : "chevron.right")
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textTertiary)
                }.buttonStyle(.plain)
                if showEmail {
                    Text(original).font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                        .textSelection(.enabled)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.Palette.hairline).frame(width: 1) }
                }
            }
        }
        .padding(.top, 6).padding(.bottom, 2)
    }
}

/// The re-bucket chip row.
struct FlowChips: View {
    let selected: RecommendationAction
    let onSelect: (RecommendationAction) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 92), spacing: 6, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(RecommendationAction.allCases) { action in
                let isOn = action == selected
                Button { onSelect(action) } label: {
                    Text(action.label)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(isOn ? Theme.Palette.agentTextDeep : Theme.Palette.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isOn ? Theme.Palette.agent : Theme.Palette.hairline,
                                        lineWidth: isOn ? 1 : 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

