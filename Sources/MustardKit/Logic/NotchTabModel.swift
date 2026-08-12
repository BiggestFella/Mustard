import Foundation

/// One pill in the notch's tab row.
public enum NotchTab: Equatable, Hashable, Sendable {
    case today, agent, meetings, clips, shelf
    case collection(name: String)

    public var title: String {
        switch self {
        case .today: return "Today"
        case .agent: return "Agent"
        case .meetings: return "Meetings"
        case .clips: return "Clips"
        case .shelf: return "Shelf"
        case .collection(let name): return name
        }
    }
}

/// Pure tab-row composition and landing decisions (spec §2).
public enum NotchTabModel {
    public static func tabs(collectionNames: [String]) -> [NotchTab] {
        [.today, .agent, .meetings, .clips, .shelf]
            + collectionNames.map { NotchTab.collection(name: $0) }
    }

    /// Where the panel opens: Meetings while a recording is live/preparing,
    /// Today otherwise.
    public static func defaultTab(recordingActive: Bool) -> NotchTab {
        recordingActive ? .meetings : .today
    }

    /// ⌃⌥V lands here with search focused.
    public static let clipsHotKeyTab: NotchTab = .clips
}

/// Per-tab expanded panel sizes: fixed, testable, capped well under any
/// screen. Grid tabs get more height than list tabs.
public enum NotchPanelMetrics {
    public struct Size: Equatable {
        public let width: Double
        public let height: Double
        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public static func expandedSize(for tab: NotchTab) -> Size {
        switch tab {
        case .today, .agent: return Size(width: 480, height: 500)
        case .meetings: return Size(width: 480, height: 520)
        case .clips, .shelf, .collection: return Size(width: 480, height: 560)
        }
    }
}
