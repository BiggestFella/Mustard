#if os(macOS)
import SwiftUI
import SwiftData

/// Shelf: deliberate keeps. Items arrive by drag-in (onto the notch, handled
/// in `NotchSurface`) or "Pin to Shelf" (from the Clips tab's context menu);
/// they leave only by explicit unpin/delete. Never auto-pruned.
/// Notch surfaces use explicit dark hex, never `Theme`.
struct NotchShelfTab: View {
    let searchQuery: String
    @Environment(\.modelContext) private var context
    /// Optional: the notch renders (read-only, no copy) even before the
    /// clipboard layer is injected into the environment.
    @Environment(ClipboardServices.self) private var services: ClipboardServices?
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var clips: [ClipItem]

    private var shelf: [ClipItem] {
        NotchSearch.filter(clips.filter(\.pinnedToShelf), query: searchQuery)
    }

    var body: some View {
        Group {
            if shelf.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20)).foregroundStyle(.white.opacity(0.3))
                    Text("Drop files or text here — or pin a clip")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(shelf, id: \.uid) { clip in
                            ClipCardView(clip: clip)
                                .onTapGesture { services?.paster.copy(text: clip.payload) }
                                .onDrag { NSItemProvider(object: clip.payload as NSString) }
                                .contextMenu {
                                    Button("Unpin") {
                                        clip.pinnedToShelf = false
                                        try? context.save()
                                    }
                                    Button("Delete", role: .destructive) {
                                        context.delete(clip)
                                        try? context.save()
                                    }
                                }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }
}
#endif
