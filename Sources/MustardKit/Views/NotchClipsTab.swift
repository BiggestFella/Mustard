#if os(macOS)
import SwiftUI

/// Clips tab: the rolling clipboard history. Stub until the Clips-tab task
/// fills in cards, filters and paste-back; the shell already hands it the
/// live search query and the pinned-only filter.
/// Notch surfaces use explicit dark hex, never `Theme`.
struct NotchClipsTab: View {
    let searchQuery: String
    let pinnedOnly: Bool

    var body: some View {
        Text("Clips")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.4))
    }
}
#endif
