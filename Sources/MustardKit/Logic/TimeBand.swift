import Foundation

/// Soft time-of-day grouping for the Today spine (Actions-style grouping, softened to
/// rail labels). Pure so it unit-tests with a pinned calendar. Boundaries: morning is
/// before 12:00, afternoon is 12:00–16:59, evening is 17:00 and later.
public enum TimeBand: String, CaseIterable, Equatable {
    case morning, afternoon, evening

    public var label: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        }
    }

    /// The band for a timed date; `nil` for an untimed (`nil`) item.
    public static func of(_ date: Date?, calendar: Calendar = .current) -> TimeBand? {
        guard let date else { return nil }
        switch calendar.component(.hour, from: date) {
        case ..<12: return .morning
        case 12..<17: return .afternoon
        default: return .evening
        }
    }
}
