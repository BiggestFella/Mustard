import AppKit
import SwiftUI

/// Installs a SwiftUI root as a panel's content **without** letting the hosting
/// view become the window's `contentView`.
///
/// Every one of Mustard's floating panels is positioned and sized by its own
/// controller, so none of them wants SwiftUI negotiating the window's content
/// size. When an `NSHostingView` *is* the `contentView`, AppKit's constraint
/// pass calls `updateWindowContentSizeExtremaIfNecessary` → `sizeThatFits`; a
/// view-graph change during that call re-dirties the hosting view and AppKit
/// throws from `_postWindowNeedsUpdateConstraints`, which macOS 27 turns into a
/// crash. It killed the notch on a tab switch, and again — with nobody touching
/// the app — when a meeting suggestion rendered.
///
/// Setting `sizingOptions = []` was not enough on its own: the extrema pass
/// still ran. Nesting the hosting view one level down removes the precondition
/// entirely — a hosting view that is not the content view has no window extrema
/// to update.
@MainActor
public func installPanelContent(_ rootView: some View, in panel: NSPanel) {
    let hosting = NSHostingView(rootView: rootView)
    hosting.sizingOptions = []
    let container = NSView()
    panel.contentView = container
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
}
