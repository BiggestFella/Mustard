import Foundation

/// Pure hover/pin state for the notch panel (spec §2: hover peeks with a
/// collapse grace period; click/hotkey pins; Esc/click-away unpins).
/// The controller feeds events and polls `shouldCollapse` on a short timer;
/// all timing decisions live here with injected clocks.
public struct NotchPinState: Equatable {
    /// How long the panel survives a pointer exit before collapsing.
    public static let collapseGrace: TimeInterval = 0.3

    public private(set) var isPinned = false
    private var isHovering = false
    private var hoverExitedAt: Date?
    private var isPeeked = false

    public init() {}

    public var isExpanded: Bool { isPinned || isPeeked }

    public mutating func hoverChanged(isInside: Bool, now: Date) {
        isHovering = isInside
        if isInside {
            isPeeked = true
            hoverExitedAt = nil
        } else {
            hoverExitedAt = now
        }
    }

    public mutating func pin() {
        isPinned = true
    }

    /// Esc / click-away. Keeps the peek only while the pointer is inside.
    public mutating func unpin() {
        isPinned = false
        if !isHovering {
            isPeeked = false
            hoverExitedAt = nil
        }
    }

    public func shouldCollapse(now: Date) -> Bool {
        guard !isPinned, isPeeked, !isHovering, let exitedAt = hoverExitedAt else {
            return false
        }
        return now.timeIntervalSince(exitedAt) >= Self.collapseGrace
    }

    public mutating func collapseIfDue(now: Date) {
        guard shouldCollapse(now: now) else { return }
        isPeeked = false
        hoverExitedAt = nil
    }
}
