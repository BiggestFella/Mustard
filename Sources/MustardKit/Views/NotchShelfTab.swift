#if os(macOS)
import SwiftUI

/// Shelf tab: deliberate keeps, never auto-pruned. Stub until the Shelf-tab
/// task fills in the grid and drag-in; the shell already hands it the live
/// search query. Notch surfaces use explicit dark hex, never `Theme`.
struct NotchShelfTab: View {
    let searchQuery: String

    var body: some View {
        Text("Shelf")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.4))
    }
}
#endif
