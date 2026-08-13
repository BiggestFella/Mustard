import Foundation

/// One keyboard decision in the Agent console. Deliberately single-key by
/// default (A · X · S · J · K): triage is a rhythm, and a modifier chord per
/// card breaks it. The console installs a local key monitor and owns the
/// AppKit edges; every *decision* — which command a press is, whether it may
/// fire at all, where the selection lands — lives here so it is testable.
public enum TriageCommand: String, CaseIterable, Sendable {
    case approve, ignore, snooze, next, previous

    /// The rebindable action holding this command's chord (Settings → Hotkeys).
    public var hotKeyAction: HotKeyAction {
        switch self {
        case .approve: .triageApprove
        case .ignore: .triageIgnore
        case .snooze: .triageSnooze
        case .next: .triageNext
        case .previous: .triagePrevious
        }
    }

    /// Held-key auto-repeat walks the queue but never re-fires an outcome — a
    /// leaned-on A must not approve six recommendations.
    public var allowsKeyRepeat: Bool {
        switch self {
        case .next, .previous: true
        case .approve, .ignore, .snooze: false
        }
    }
}

/// How far the snooze key defers a recommendation. Editable in Settings →
/// Hotkeys; the detail pane's Snooze menu still offers all three explicitly.
public enum TriageSnoozePreset: String, CaseIterable, Identifiable, Sendable {
    case hour, afternoon, tomorrow

    public var id: String { rawValue }
    public static let storageKey = "triageSnoozePreset"
    public static let `default`: TriageSnoozePreset = .tomorrow

    public var label: String {
        switch self {
        case .hour: "1 hour"
        case .afternoon: "This afternoon"
        case .tomorrow: "Next day"
        }
    }

    public func target(from now: Date = .now, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour: now.addingTimeInterval(3600)
        case .afternoon: SnoozeTargets.afternoon(after: now, calendar: calendar)
        case .tomorrow: SnoozeTargets.tomorrow9(after: now, calendar: calendar)
        }
    }

    /// The stored choice, falling back to the default when unset or unknown.
    public static func current(store: UserDefaults = .standard) -> TriageSnoozePreset {
        guard let raw = store.string(forKey: storageKey), let preset = TriageSnoozePreset(rawValue: raw)
        else { return .default }
        return preset
    }
}

public enum TriageShortcuts {
    /// The command a keypress means, or nil when the chord is bound to nothing.
    /// Modifiers must match exactly, so ⌘A (select all) is not the bare-A approve.
    public static func command(
        keyCode: UInt32, carbonModifiers: UInt32, chords: [HotKeyAction: HotKeyChord]
    ) -> TriageCommand? {
        let pressed = HotKeyChord(keyCode: keyCode, carbonModifiers: carbonModifiers)
        return TriageCommand.allCases.first {
            (chords[$0.hotKeyAction] ?? $0.hotKeyAction.defaultChord) == pressed
        }
    }

    /// Whether a matched press may actually fire. Text editing wins over every
    /// triage key — in the draft editor, the comment field or the command bar a
    /// bare key is a character, not a decision.
    public static func shouldHandle(
        _ command: TriageCommand, isRepeat: Bool, isEditingText: Bool, isModalPresented: Bool
    ) -> Bool {
        if isEditingText || isModalPresented { return false }
        if isRepeat, !command.allowsKeyRepeat { return false }
        return true
    }

    /// The master list's visible order — the grouped view flattened, so
    /// next/previous walk exactly what the eye sees.
    public static func visibleOrder(_ groups: [RecGroup]) -> [Recommendation] {
        groups.flatMap(\.members)
    }

    /// The neighbour `steps` away from `current`, clamped at both ends: a triage
    /// pass has a start and an end, and wrapping would silently re-show a rec you
    /// just walked past. Nothing selected (or a rec that has left the queue)
    /// starts at the top. Identity-based, like `RecommendationSelection`.
    public static func step(
        from current: Recommendation?, in order: [Recommendation], by steps: Int
    ) -> Recommendation? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(where: { $0 === current }) else {
            return order.first
        }
        return order[min(max(index + steps, 0), order.count - 1)]
    }

    /// What the approve key does to a card, mirroring its primary button.
    public enum ApproveOutcome: Equatable, Sendable { case keep, approveAndRun }

    /// An FYI card's primary button is "Keep" (file it to the log), not
    /// "Approve & run" — the key must do what the card shows.
    public static func approveOutcome(for rec: Recommendation) -> ApproveOutcome {
        rec.action == .fyi ? .keep : .approveAndRun
    }
}
