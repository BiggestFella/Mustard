import Foundation

/// Lightweight, testable stand-in for `NSScreen` so screen-selection policy
/// can be unit tested without a live display list.
public struct NotchScreenDescriptor: Equatable {
    public let id: AnyHashable
    public let hasNotch: Bool
    public let isMain: Bool

    public init(id: AnyHashable, hasNotch: Bool, isMain: Bool) {
        self.id = id
        self.hasNotch = hasNotch
        self.isMain = isMain
    }
}

/// Decides which screen the notch panel renders on: prefer a connected
/// external (non-notch) display over the built-in notch screen, so the
/// panel follows the monitor actually in use instead of staying stuck on
/// the laptop's physical notch whenever the lid is open.
public enum NotchScreenPicker {
    public static func choose(from screens: [NotchScreenDescriptor]) -> NotchScreenDescriptor? {
        if screens.count > 1, let external = screens.first(where: { !$0.hasNotch }) {
            return external
        }
        if let notch = screens.first(where: { $0.hasNotch }) {
            return notch
        }
        if let main = screens.first(where: { $0.isMain }) {
            return main
        }
        return screens.first
    }
}

#if os(macOS)
import AppKit

extension NotchScreenPicker {
    /// The one place panels resolve "which display is the notch display".
    /// Used by the notch panel, the voice pill, the dictation pill, and the
    /// quick-edit card so they can never land on different screens.
    @MainActor
    public static func currentScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let descriptors = screens.enumerated().map { index, screen in
            NotchScreenDescriptor(
                id: index,
                hasNotch: screen.safeAreaInsets.top > 0,
                isMain: screen == NSScreen.main)
        }
        guard let chosen = choose(from: descriptors),
              let index = chosen.id as? Int else { return NSScreen.main }
        return screens[index]
    }
}
#endif
