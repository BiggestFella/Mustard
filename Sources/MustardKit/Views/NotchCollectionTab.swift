#if os(macOS)
import SwiftUI
import SwiftData

/// One custom collection's contents. Same cards; filing/unfiling via
/// context menu. Deleting the collection unfiles (nullify), never deletes.
struct NotchCollectionTab: View {
    let name: String
    let searchQuery: String
    @Environment(\.modelContext) private var context
    @Environment(ClipboardServices.self) private var services: ClipboardServices?
    @Query(sort: \ClipCollection.sortOrder) private var collections: [ClipCollection]

    private var collection: ClipCollection? {
        collections.first { $0.name == name }
    }
    private var items: [ClipItem] {
        let filed = (collection?.items ?? []).sorted { $0.createdAt > $1.createdAt }
        return NotchSearch.filter(filed, query: searchQuery)
    }

    /// Click = copy, same shape as the Clips tab: an image clip carries bytes
    /// rather than a payload string, so copying its (empty) payload would be a
    /// silent no-op. Nothing empty is ever written — that would wipe whatever
    /// the user already had on the clipboard.
    private func copy(_ clip: ClipItem) {
        guard let paster = services?.paster else { return }
        if clip.kind == .image {
            guard let data = clip.imageData ?? clip.thumbnailData, !data.isEmpty else { return }
            paster.copy(imageData: data)
        } else {
            guard !clip.payload.isEmpty else { return }
            paster.copy(text: clip.payload)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text("Empty — file clips here from their context menu")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(items, id: \.uid) { clip in
                            ClipCardView(clip: clip)
                                .onTapGesture { copy(clip) }
                                .onDrag { ClipDragProvider.provider(for: clip) }
                                .contextMenu {
                                    Button("Remove from \(name)") {
                                        clip.collection = nil
                                        try? context.save()
                                    }
                                    Button("Delete clip", role: .destructive) {
                                        context.delete(clip)
                                        try? context.save()
                                    }
                                }
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
            Spacer(minLength: 0)
            Button("Delete collection", role: .destructive) {
                if let collection { context.delete(collection); try? context.save() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(Color(hex: "#FF5F57").opacity(0.8))
        }
    }
}
#endif
