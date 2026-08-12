import Foundation

/// Clips (and everything else made of clips — shelf, collections) search on a
/// pre-joined haystack of payload + source app + kind, so typing "figma" or
/// "link" both narrow the grid.
extension ClipItem: NotchSearchable {
    public var searchText: String {
        "\(payload) \(sourceAppName ?? "") \(kind.rawValue)"
    }
}

#if os(macOS)
import SwiftUI
import SwiftData

/// Clips tab: the rolling clipboard history. Click = copy, Return or
/// double-click = paste into the frontmost app, drag-out for files/images,
/// context menu for shelf pinning, filing and delete.
/// Notch surfaces use explicit dark hex, never `Theme`.
struct NotchClipsTab: View {
    let searchQuery: String
    let pinnedOnly: Bool
    @Environment(\.modelContext) private var context
    /// Optional: the notch renders (read-only, no copy/paste) even before the
    /// clipboard layer is injected into the environment.
    @Environment(ClipboardServices.self) private var services: ClipboardServices?
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var clips: [ClipItem]
    @Query(sort: \ClipCollection.sortOrder) private var collections: [ClipCollection]
    @State private var kindFilter: ClipKind?
    @State private var selectedUID: String?

    /// Filed clips live in their collection's tab, not in history.
    private var history: [ClipItem] { clips.filter { $0.collection == nil } }

    private var visible: [ClipItem] {
        var items = history
        if pinnedOnly { items = items.filter(\.pinnedToShelf) }
        if let kindFilter { items = items.filter { $0.kind == kindFilter } }
        return NotchSearch.filter(items, query: searchQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterChips
            if visible.isEmpty {
                // "Nothing here yet" is about the history this tab shows —
                // filed clips live in their collection's tab and must not
                // make an empty history look populated.
                Text(history.isEmpty ? "Copy anything — it lands here" : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8
                    ) {
                        ForEach(visible, id: \.uid) { clip in
                            ClipCardView(clip: clip)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            selectedUID == clip.uid
                                                ? Color(hex: "#6E9FFF") : .clear,
                                            lineWidth: 1))
                                // Double-tap must be attached FIRST so it wins
                                // the gesture race against the single tap.
                                .onTapGesture(count: 2) { paste(clip) }
                                .onTapGesture { select(clip) }
                                .onDrag { dragProvider(for: clip) }
                                .contextMenu { menu(for: clip) }
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
        }
        // Without this the grid can never hold focus, and `onKeyPress` below
        // is dead code — the panel itself also has to be key-capable
        // (`NotchPanel` in NotchSurface.swift).
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let clip = visible.first(where: { $0.uid == selectedUID }) else {
                return .ignored
            }
            paste(clip)
            return .handled
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                chip(nil, label: "All")
                ForEach([ClipKind.text, .link, .image, .file, .color, .dictation], id: \.self) {
                    chip($0, label: $0.rawValue.capitalized)
                }
            }
        }
    }

    private func chip(_ kind: ClipKind?, label: String) -> some View {
        let selected = kindFilter == kind
        return Button { kindFilter = kind } label: {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(selected ? .black : .white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    selected
                        ? AnyShapeStyle(.white.opacity(0.9))
                        : AnyShapeStyle(.white.opacity(0.07)),
                    in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Click = select + copy. Image clips carry their bytes rather than a
    /// payload string, so they copy as an image; anything with an empty
    /// payload is left alone rather than wiping the user's clipboard.
    private func select(_ clip: ClipItem) {
        selectedUID = clip.uid
        guard let paster = services?.paster else { return }
        if clip.kind == .image {
            guard let data = clip.imageData ?? clip.thumbnailData, !data.isEmpty else { return }
            paster.copy(imageData: data)
        } else {
            paster.copy(text: clip.payload)
        }
    }

    /// Paste-back is text-only for v1 — Return or a double-click on an image
    /// clip does nothing (it copies on the first click and drags out).
    private func paste(_ clip: ClipItem) {
        guard let services, !clip.payload.isEmpty else { return }
        Task { _ = await services.paster.paste(text: clip.payload) }
    }

    private func dragProvider(for clip: ClipItem) -> NSItemProvider {
        switch clip.kind {
        case .file:
            return NSItemProvider(contentsOf: URL(fileURLWithPath: clip.payload))
                ?? NSItemProvider(object: clip.payload as NSString)
        case .image:
            if let data = clip.imageData ?? clip.thumbnailData,
               let image = NSImage(data: data) {
                return NSItemProvider(object: image)
            }
            return NSItemProvider(object: clip.payload as NSString)
        default:
            return NSItemProvider(object: clip.payload as NSString)
        }
    }

    @ViewBuilder private func menu(for clip: ClipItem) -> some View {
        Button(clip.pinnedToShelf ? "Unpin from Shelf" : "Pin to Shelf") {
            clip.pinnedToShelf.toggle()
            try? context.save()
        }
        if !collections.isEmpty {
            Menu("Add to collection") {
                ForEach(collections, id: \.uid) { collection in
                    Button(collection.name) {
                        clip.collection = collection
                        try? context.save()
                    }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            context.delete(clip)
            try? context.save()
        }
    }
}
#endif
