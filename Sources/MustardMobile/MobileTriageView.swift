import SwiftUI
import SwiftData

/// Mobile Triage tab — the Tinder-style swipe deck (BAK-119) over the pending queue.
/// Swipe right = approve · left = reject · down = snooze · tap = open the BAK-115 detail
/// sheet. Gated actions (email/Slack/ticket) can NEVER be approved by a swipe — a right
/// fling on a gated card routes to the detail sheet for explicit sign-off (TriageDeck).
/// A trust chip tap-cycles Manual→Supervised→Trusted→Autonomous (raising it auto-clears
/// eligible recs via AgentService.applyTrust). Every swipe leaves a one-tap Undo.
/// Decisions reuse the tested AgentService; the queue is RecommendationQueue.pending.
struct MobileTriageView: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    @Query private var recommendations: [Recommendation]
    @AppStorage("trustLevel") private var trustRaw = TrustLevel.manual.rawValue

    @State private var selected: Recommendation?
    @State private var drag: CGSize = .zero
    @State private var flinging = false
    @State private var undo: UndoSnapshot?

    private let threshold: CGFloat = 96
    private var trust: TrustLevel { TrustLevel(rawValue: trustRaw) ?? .manual }
    private var pending: [Recommendation] {
        RecommendationQueue.pending(recommendations, now: .now).sorted { $0.confidence > $1.confidence }
    }

    /// Enough to restore the pre-swipe state for a one-tap Undo. `createdTask` is the task
    /// an approve newly created (found by identity-diff, since createTask links nothing on
    /// the rec) — deleted on undo. Nil for reject/snooze and for approves that reuse an
    /// existing delegated task, so a pre-existing task is never deleted.
    private struct UndoSnapshot: Identifiable {
        let id = UUID()
        let rec: Recommendation
        let decisionRaw: String
        let snoozedUntil: Date?
        let createdTask: MustardTask?
        let verb: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                trustChip
                if pending.isEmpty {
                    allClear
                } else {
                    deck
                    actionButtons
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Triage")
            .sheet(item: $selected) { MobileRecommendationSheet(rec: $0) }
            .overlay(alignment: .bottom) { undoToast }
            .animation(Theme.Motion.easeOut(), value: undo?.id)
            .task(id: undo?.id) {
                guard undo != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                undo = nil
            }
        }
    }

    // MARK: Trust chip (tap-cycle)

    private var trustChip: some View {
        Button {
            let nextLevel = trust.next
            trustRaw = nextLevel.rawValue
            Task { await agent.applyTrust(nextLevel) }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "dial.medium").font(.caption)
                    Text("Trust · \(trust.label)").font(.caption.weight(.semibold))
                    Image(systemName: "arrow.trianglehead.clockwise").font(.caption2)
                }
                .foregroundStyle(Theme.Palette.agentTextDeep)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.Palette.agentTintFaint, in: Capsule())
                Text(trust.blurb).font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).lineLimit(2)
            }
        }.buttonStyle(.plain)
    }

    // MARK: Deck

    private var deck: some View {
        ZStack {
            ForEach(Array(pending.prefix(3).enumerated()).reversed(), id: \.element.id) { idx, rec in
                if idx == 0 {
                    topCard(rec).zIndex(1)
                } else {
                    DeckCard(rec: rec)
                        .scaleEffect(1 - CGFloat(idx) * 0.04)
                        .offset(y: CGFloat(idx) * 12)
                        .opacity(idx == 1 ? 1 : 0.6)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Smoothly restack the cards behind when the top one leaves.
        .animation(Theme.Motion.reflow, value: pending.count)
    }

    private func topCard(_ rec: Recommendation) -> some View {
        DeckCard(rec: rec)
            .overlay(alignment: .top) { hintBadge() }
            .offset(drag)
            .rotationEffect(.degrees(Double(drag.width / 26)), anchor: .bottom)
            // No implicit .animation on `drag`: the card must track the finger 1:1 while
            // dragging. Snap-back and fling are animated explicitly (onDragEnd / fling),
            // and the onEnded flinging-guard blocks a second flick during a fling.
            .gesture(
                DragGesture()
                    .onChanged { if !flinging { drag = $0.translation } }
                    .onEnded { if !flinging { onDragEnd($0.translation, rec) } }
            )
            .onTapGesture { selected = rec }
    }

    /// The colored intent label that fades in as you drag the top card.
    @ViewBuilder private func hintBadge() -> some View {
        if let (text, color) = currentHint() {
            Text(text)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(color)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
                .rotationEffect(.degrees(-8))
                .opacity(Double(min(1, max(abs(drag.width), drag.height) / threshold)))
                .padding(.top, 22)
        }
    }

    private func currentHint() -> (String, Color)? {
        guard let dir = direction(drag) else { return nil }
        switch TriageDeck.outcome(for: dir) {
        case .approve: return ("APPROVE", Theme.Palette.done)
        case .reject: return ("REJECT", Theme.Palette.priorityUrgentBg)
        case .snooze: return ("SNOOZE", Theme.Palette.warnText)
        }
    }

    // MARK: Gesture resolution

    private func direction(_ t: CGSize) -> TriageDeck.SwipeDirection? {
        if abs(t.width) > abs(t.height) {
            if t.width > threshold { return .right }
            if t.width < -threshold { return .left }
        } else if t.height > threshold {
            return .down
        }
        return nil
    }

    private func onDragEnd(_ t: CGSize, _ rec: Recommendation) {
        guard let dir = direction(t) else {
            withAnimation(Theme.Motion.drag) { drag = .zero }
            return
        }
        fling(rec, dir, TriageDeck.outcome(for: dir))
    }

    /// Animate the card off-screen in the swipe direction, then — exactly when that
    /// animation finishes (completion callback, not a fixed sleep) — apply the decision
    /// and reset for the next card. Applying only after the fling means the @Query drop
    /// and the drag reset land in one pass, so the incoming card doesn't flash in.
    private func fling(_ rec: Recommendation, _ dir: TriageDeck.SwipeDirection, _ outcome: TriageDeck.Outcome) {
        flinging = true
        // Carry the card past the screen edge in the drag's current direction so the exit
        // continues the finger's motion rather than snapping to a fixed vector.
        let off: CGSize = switch dir {
        case .right: CGSize(width: 900, height: drag.height)
        case .left: CGSize(width: -900, height: drag.height)
        case .down: CGSize(width: drag.width, height: 1100)
        }
        withAnimation(Theme.Motion.easeOut(0.28)) {
            drag = off
        } completion: {
            Task {
                await apply(outcome, to: rec)
                drag = .zero
                flinging = false
            }
        }
    }

    @MainActor private func apply(_ outcome: TriageDeck.Outcome, to rec: Recommendation) async {
        let decisionRaw = rec.decisionRaw
        let snoozedUntil = rec.snoozedUntil
        // Snapshot task identities before the decision so we can find (and later undo) a
        // task an approve creates — createTask links nothing on the rec, so diff instead.
        let priorTaskIDs = Set((try? context.fetch(FetchDescriptor<MustardTask>()))?.map(\.persistentModelID) ?? [])
        switch outcome {
        case .approve: await agent.decide(rec, .approved)
        case .reject: rec.decision = .denied
        case .snooze: agent.snooze(rec, until: SnoozeTargets.tomorrow9())
        }
        let created: MustardTask? = outcome == .approve
            ? (try? context.fetch(FetchDescriptor<MustardTask>()))?.first { !priorTaskIDs.contains($0.persistentModelID) }
            : nil
        undo = UndoSnapshot(rec: rec, decisionRaw: decisionRaw, snoozedUntil: snoozedUntil,
                            createdTask: created, verb: verb(outcome))
    }

    private func performUndo(_ snap: UndoSnapshot) {
        snap.rec.decisionRaw = snap.decisionRaw
        snap.rec.snoozedUntil = snap.snoozedUntil
        if let created = snap.createdTask { context.delete(created) }
        undo = nil
    }

    private func verb(_ o: TriageDeck.Outcome) -> String {
        switch o {
        case .approve: "Approved"
        case .reject: "Rejected"
        case .snooze: "Snoozed"
        }
    }

    // MARK: Manual action buttons (swipe alternative + discoverability)

    private var actionButtons: some View {
        HStack(spacing: 28) {
            circle("xmark", Theme.Palette.priorityUrgentBg) { if let r = pending.first { fling(r, .left, .reject) } }
            circle("moon.zzz.fill", Theme.Palette.warnText) { if let r = pending.first { fling(r, .down, .snooze) } }
            circle("checkmark", Theme.Palette.done) { if let r = pending.first { fling(r, .right, .approve) } }
        }
        .disabled(flinging)
    }

    private func circle(_ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 56, height: 56)
                .background(Theme.Palette.bg, in: Circle())
                .overlay(Circle().stroke(color.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        }.buttonStyle(.plain)
    }

    // MARK: Empty + undo

    private var allClear: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(Theme.Palette.done)
            Text("All clear").font(.title3.bold())
            Text("Nothing waiting on you.").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var undoToast: some View {
        if let undo {
            HStack(spacing: 12) {
                Text("\(undo.verb) “\(undo.rec.title)”").font(Theme.Fonts.meta.weight(.medium))
                    .foregroundStyle(.white).lineLimit(1)
                Button("Undo") { performUndo(undo) }
                    .font(Theme.Fonts.meta.weight(.semibold))
                    .foregroundStyle(Theme.Palette.agentTintOnDark)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.Palette.textPrimary, in: Capsule())
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// One recommendation card face — shared by the top (interactive) card and the peeked
/// cards behind it. Pure presentation; all gestures live on the top card in the deck.
private struct DeckCard: View {
    let rec: Recommendation

    private var area: String? { AreaMapping.areaName(forProject: rec.project) }
    private var draftPreview: String {
        let s = rec.draft.isEmpty ? rec.body : rec.draft
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let badge = SourceBadge.badge(forRaw: rec.source)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if !badge.isQuiet {
                    HStack(spacing: 4) {
                        SourceLogo(source: badge.id, size: 12)
                        Text(badge.label)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(hex: badge.fgHex))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(hex: badge.bgHex), in: Capsule())
                }
                Text("✦ \(rec.action.label)").font(.caption.weight(.medium)).foregroundStyle(Theme.Palette.agentTextDeep)
                Spacer(minLength: 0)
                if rec.action.isGated {
                    Label("Gated", systemImage: "lock").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(rec.title).font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Area + when — quick context on where this came from and how fresh it is.
            if area != nil || rec.occurredAt != nil {
                HStack(spacing: 8) {
                    if let area {
                        Text(area).font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.Palette.surface, in: Capsule())
                    }
                    Text((rec.occurredAt ?? rec.createdAt).formatted(.relative(presentation: .named)))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if !rec.reasoning.isEmpty {
                Text(rec.reasoning).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            if !rec.sourceContext.isEmpty {
                Text(rec.sourceContext).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }

            // Original email/source preview — context for the draft, before opening detail.
            if let preview = OriginalSourceDisplay.previewText(rec.originalSource) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(OriginalSourceDisplay.sectionLabel(source: rec.source, sourceURL: rec.sourceURL))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            }

            // Proposed draft preview — the actual content the agent wants to send/write.
            if !draftPreview.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DRAFT").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(draftPreview).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.titleBar, in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(String(format: "%.2f", rec.confidence))
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.confidenceColor(rec.confidence))
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i < Int((rec.confidence * 5).rounded(.down)) ? Theme.confidenceColor(rec.confidence) : Theme.Palette.confidenceUnfilled)
                            .frame(width: 16, height: 5)
                    }
                }
                Spacer(minLength: 0)
                if let s = rec.sourceURL, let url = URL(string: s) {
                    Link("Open ↗", destination: url).font(.caption2).foregroundStyle(Theme.Palette.accent)
                }
                Text("Tap for detail").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.bg, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        .overlay(alignment: .leading) {
            Theme.Palette.agent.frame(width: 3).clipShape(Capsule()).padding(.vertical, 18)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}
