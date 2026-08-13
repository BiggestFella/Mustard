import CoreGraphics

/// Pure line-breaking for a wrapping chip row (tags in the task detail).
///
/// The tag row used to be a plain `HStack`, which cannot wrap: when the chips
/// overflowed, SwiftUI compressed each one to its minimum width instead, so a
/// tag like `project:code-heroes-internal` rendered as a tall narrow column of
/// broken-up characters and ate the sheet's vertical space — squeezing the body
/// editor down to a few unreadable lines.
public enum TagFlow {
    /// Greedy break: fill a row until the next item would overflow `maxWidth`.
    /// An item wider than the container gets a row to itself rather than being
    /// squeezed — a chip is never made narrower than its own text.
    public static func rows(
        itemWidths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat
    ) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in itemWidths.enumerated() {
            let needed = current.isEmpty ? width : used + spacing + width
            if !current.isEmpty, needed > maxWidth {
                rows.append(current)
                current = [index]
                used = width
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// Total height for `rowCount` rows of `rowHeight`, separated by `spacing`.
    public static func height(
        rowCount: Int, rowHeight: CGFloat, spacing: CGFloat
    ) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * spacing
    }
}
