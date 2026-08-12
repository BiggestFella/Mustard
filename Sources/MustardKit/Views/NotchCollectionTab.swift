#if os(macOS)
import SwiftUI

/// One custom collection's contents. Stub until the collections task fills
/// in the grid and filing actions; the shell already hands it the
/// collection name and the live search query.
/// Notch surfaces use explicit dark hex, never `Theme`.
struct NotchCollectionTab: View {
    let name: String
    let searchQuery: String

    var body: some View {
        Text(name)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.4))
    }
}
#endif
