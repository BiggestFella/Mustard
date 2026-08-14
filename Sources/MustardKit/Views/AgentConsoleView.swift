import SwiftUI
import SwiftData
import AppKit

/// The agent console: pure triage over the Recommendations queue and in-flight
/// gates (master-detail list │ detail). All config (sources, calendar, voice,
/// trust, hotkeys) moved to `SettingsView` (settings spec 2026-08-12) — the
/// gear button jumps there. Output review lives on the board's Needs Review
/// column (ADR-0010) — there is no console review queue. Things-3-calm throughout.
public struct AgentConsoleView: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    @AppStorage("autoOpenSourceOnSelect") private var autoOpenSource = true
    @Environment(SourcePanelController.self) private var sourcePanel
    @Environment(AgentTaskCoordinator.self) private var taskAgent
    @Environment(HotKeyBindingsStore.self) private var hotKeys
    /// Selection + key routing. An object, not @State: the triage key monitor is
    /// an escaping callback and must see the live selection and queue.
    @State private var console = TriageConsoleState()
    /// Approval-gate spec (2026-08-14): reveals the held meeting-task rows.
    @State private var showBackgroundMaintenance = false

    @Query(sort: \Recommendation.createdAt, order: .reverse) private var recommendations: [Recommendation]
    @Query private var allTasks: [MustardTask]

    /// Jumps to the Settings screen (RootView owns the route) — all console
    /// config moved there (settings spec 2026-08-12).
    private let onOpenSettings: (() -> Void)?

    public init(onOpenSettings: (() -> Void)? = nil) {
        self.onOpenSettings = onOpenSettings
    }

    private var pending: [Recommendation] {
        RecommendationQueue.pending(recommendations, now: .now)
    }

    private var attention: AgentInbox.AgentAttention { AgentInbox.attention(allTasks) }

    public var body: some View {
        @Bindable var console = console
        return HSplitView {
            masterColumn
                .frame(minWidth: 360, idealWidth: 480)
            detailColumn
                .frame(minWidth: 320, idealWidth: 420)
        }
        .background(Theme.Palette.bg)
        .onAppear {
            syncQueue()
            if console.selected == nil {
                console.selected = RecommendationSelection.nextSelection(current: nil, pending: pending)
            }
            startTriageKeys()
        }
        .onDisappear { console.removeMonitor() }
        .onChange(of: pending.map(\.persistentModelID)) { _, _ in
            syncQueue()
            let next = RecommendationSelection.nextSelection(current: console.selected, pending: pending)
            if next !== console.selected { console.selected = next }
        }
    }

    /// Keep the object's copy of the visible order in step with the query — the
    /// key monitor walks this, not the view struct it was installed with.
    private func syncQueue() {
        console.order = TriageShortcuts.visibleOrder(SourceGrouping.grouped(pending))
    }

    /// Install the console-only triage keys. Environment objects are captured
    /// once, here, so the escaping monitor never reads `@Environment` after body.
    private func startTriageKeys() {
        let agent = self.agent
        let hotKeys = self.hotKeys
        let console = self.console
        console.installMonitor(chords: { hotKeys.chords }) { command in
            Self.perform(command, console: console, agent: agent)
        }
    }

    /// The keyboard mirror of the detail pane's buttons — same outcomes, same
    /// guards, so a key and a click are never two different decisions.
    private static func perform(
        _ command: TriageCommand, console: TriageConsoleState, agent: AgentService
    ) {
        switch command {
        case .next:
            console.selected = TriageShortcuts.step(from: console.selected, in: console.order, by: 1)
        case .previous:
            console.selected = TriageShortcuts.step(from: console.selected, in: console.order, by: -1)
        case .approve:
            // `isExecuting` disables the Approve button; the key stands down too.
            guard let rec = console.selected, !agent.isExecuting else { return }
            switch TriageShortcuts.approveOutcome(for: rec) {
            case .keep: agent.keep(rec)
            case .approveAndRun: Task { await agent.decide(rec, .approved) }
            }
        case .ignore:
            console.selected?.decision = .denied
        case .snooze:
            guard let rec = console.selected else { return }
            agent.snooze(rec, until: TriageSnoozePreset.current().target())
        }
    }

    private var masterColumn: some View {
        // ScrollViewReader so a keyboard-moved selection scrolls itself into
        // view — walking the queue with J/K must never leave you looking at
        // a card the selection has already left.
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if taskAgent.authenticationRequired { authBanner }

                if !attention.inFlight.isEmpty {
                    sectionLabel("IN FLIGHT · NEEDS YOU", count: attention.inFlight.count)
                    ForEach(attention.inFlight) { gateRow($0) }
                }
                if !attention.background.isEmpty {
                    DisclosureGroup(isExpanded: $showBackgroundMaintenance) {
                        ForEach(attention.background) { attentionRow($0, label: "Background") }
                    } label: {
                        sectionLabel("BACKGROUND MAINTENANCE", count: attention.background.count)
                    }
                    .padding(.top, 8)
                }

                sectionLabel("RECOMMENDATIONS", count: pending.count)
                if pending.isEmpty {
                    emptyLine("Nothing waiting on you. Run a sweep from Settings or the command bar.")
                }
                // Rows are elevated cards (Craft pass Phase 1) — spacing separates
                // them; a hairline divider against a bordered card reads doubled.
                ForEach(SourceGrouping.grouped(pending)) { group in
                    if group.isMultiSource {
                        SourceGroupHeader(rec: group.header)
                        ForEach(group.members) { rec in
                            RecommendationRow(rec: rec, inGroup: true,
                                              isSelected: console.selected === rec,
                                              onSelect: { select(rec) })
                                .id(rec.persistentModelID)
                                .padding(.bottom, 8)
                        }
                    } else {
                        RecommendationRow(rec: group.header, inGroup: false,
                                          isSelected: console.selected === group.header,
                                          onSelect: { select(group.header) })
                            .id(group.header.persistentModelID)
                            .padding(.bottom, 8)
                    }
                }

                // Output review now lives on the board's Needs Review column (ADR-0010).
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .onChange(of: console.selected?.persistentModelID) { _, id in
            guard let id else { return }
            withAnimation(Theme.Motion.settle) { proxy.scrollTo(id, anchor: .center) }
        }
        }
    }

    private var detailColumn: some View {
        Group {
            // A task under review opens HERE, in the same pane the triage items
            // use — not as a modal card over the top of it (Leon, 2026-08-13).
            if let task = console.sheetTask {
                ConsoleTaskDetail(task: task, onClose: { console.sheetTask = nil })
                    .id(task.persistentModelID)
            } else if let selected = console.selected {
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
        // Both share the detail column, and a task takes precedence there, so
        // picking a recommendation has to release the task or the pane sticks.
        console.sheetTask = nil
        console.selected = rec
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
            Button {
                onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Sources, trust and hotkeys moved to Settings.")
        }
        .padding(.bottom, 12)
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

    /// One banner for a runtime that needs sign-in — not repeated per task row.
    private var authBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Agent sign-in needed", systemImage: "lock")
                .font(Theme.Fonts.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.warnText)
            Text("The Claude CLI isn't logged in. Run `claude /login` (or `claude setup-token`) in a terminal, then retry.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") { Task { await taskAgent.retryAuthentication() } }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 12)
    }

    /// The gate-kind spine colour: purple (approval), amber (answer), green (review).
    /// Enumerates the gate stages (`TaskStage.isGate`) — keep in sync with `gateSubmeta`
    /// and `AgentInbox.gateAction` if a gate stage is added.
    private func gateSpineColor(_ stage: TaskStage) -> Color {
        switch stage {
        case .needsApproval: return Theme.Palette.agent
        case .needsInput: return Theme.Palette.warning
        case .needsReview: return Theme.Palette.done
        default: return Theme.Palette.hairline
        }
    }

    /// The muted sub-meta line under a gate row's title. Enumerates the gate stages
    /// (`TaskStage.isGate`) — keep in sync with `gateSpineColor` / `AgentInbox.gateAction`.
    private func gateSubmeta(_ task: MustardTask) -> String {
        switch task.stage {
        case .needsApproval: return task.isGated ? "gated · approve to run" : "approve to run"
        case .needsInput: return "agent asked · your answer needed"
        case .needsReview: return "finished · check the output"
        default: return ""
        }
    }

    /// One-click advance for a gate row, mirroring MustardBoardCard.approveGate: the
    /// pure PersonalBoard.approveTarget decides the destination (needsApproval → queued
    /// / needsReview; needsReview → done), so acting here and on the board stay coherent.
    private func advanceGate(_ task: MustardTask) {
        guard let target = PersonalBoard.approveTarget(for: task) else { return }
        PersonalBoard.move(task, to: target)
    }

    /// A compact, actionable gate row (Needs Approval / You / Review) — deliberately
    /// distinct from the rich proposal cards. Meeting tasks expose both quick Do and
    /// Don't decisions here; tapping the row still opens the full task sheet.
    private func gateRow(_ task: MustardTask) -> some View {
        let action = AgentInbox.gateAction(for: task.stage)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(gateSpineColor(task.stage))
                .frame(width: 3)
            if let area = task.list?.area {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: area.colorHex)).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(Theme.Fonts.body).foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(gateSubmeta(task)).font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let action {
                Button {
                    if action.oneClick { advanceGate(task) } else { console.sheetTask = task }
                } label: {
                    Text(task.source == "meeting" && task.stage == .needsApproval ? "Do" : action.label)
                        .font(Theme.Fonts.caption.weight(.semibold))
                        .foregroundStyle(action.oneClick ? .white : Theme.Palette.textSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background {
                            if action.oneClick {
                                RoundedRectangle(cornerRadius: 7).fill(gateSpineColor(task.stage))
                            } else {
                                RoundedRectangle(cornerRadius: 7).stroke(Theme.Palette.hairline, lineWidth: 0.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                if task.source == "meeting", task.stage == .needsApproval {
                    Button("Don't") { rejectGate(task) }
                        .font(Theme.Fonts.caption.weight(.medium))
                        .foregroundStyle(Theme.Palette.confidenceLow)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Palette.hairline, lineWidth: 0.5))
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { console.sheetTask = task }
        .padding(.bottom, 8)
    }

    private func rejectGate(_ task: MustardTask) {
        let vaultRoot = UserDefaults.standard.string(forKey: "meetingVaultPath") ?? ""
        _ = MeetingTaskSync.reject(task, context: context, vaultRoot: vaultRoot)
    }

    /// A compact attention row (Needs You / Needs Review) that opens the task's
    /// conversation in the detail sheet.
    private func attentionRow(_ task: MustardTask, label: String? = nil) -> some View {
        Button { console.sheetTask = task } label: {
            HStack(spacing: 8) {
                if let area = task.list?.area {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: area.colorHex)).frame(width: 7, height: 7)
                }
                Text(task.title).font(Theme.Fonts.body).foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(label ?? (task.stage == .needsInput ? "Answer" : "Review"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(task.stage == .needsInput ? Theme.Palette.warnText : Theme.Palette.reviewText)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { console.sheetTask = task }
        .padding(.bottom, 8)
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

/// Console host for the task detail: the task review, plus its companion draft
/// panel when a draft is open.
///
/// This renders **inside the console's detail column**, so reviewing a task
/// looks like triaging a recommendation instead of throwing a modal card over
/// the whole console. `TaskDetailSheet`'s own Done button drives `onClose`,
/// which just clears the selection and returns the pane to the recommendation.
private struct ConsoleTaskDetail: View {
    let task: MustardTask
    let onClose: () -> Void
    @State private var draftPanel = AgentDraftPanelState()

    var body: some View {
        HStack(spacing: 0) {
            if draftPanel.draft != nil {
                AgentDraftPanelView(state: draftPanel)
                    .frame(width: 440)
                Divider().overlay(Theme.Palette.hairline)
            }
            TaskDetailSheet(task: task, onClose: onClose)
                .environment(draftPanel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.Motion.expand, value: draftPanel.draft?.uid)
    }
}
