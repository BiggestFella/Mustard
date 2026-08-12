#if os(macOS)
import SwiftUI

/// What a clip card hands a drop target when it is dragged out. Shared by all
/// three grids (Clips, Shelf, collections) because the naive
/// `NSItemProvider(object: clip.payload as NSString)` is wrong for exactly the
/// kinds the Shelf collects: an image clip's payload is EMPTY (its bytes live
/// on the model), so the receiver gets an empty string, and a file clip's
/// payload is a path, so Finder gets text instead of the file.
enum ClipDragProvider {
    static func provider(for clip: ClipItem) -> NSItemProvider {
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
}

/// One clip card: type-appropriate preview + source badge + relative time.
/// Shared by the Clips, Shelf and collection grids.
/// Notch surfaces use explicit dark hex, never `Theme`.
struct ClipCardView: View {
    let clip: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Text(clip.sourceAppName ?? "—")
                Text("·")
                Text(clip.createdAt, format: .relative(presentation: .named))
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(1)
        }
        .padding(8)
        .frame(height: 76)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var preview: some View {
        switch clip.kind {
        case .color:
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(hex: normalizedHex))
                .frame(height: 28)
                .overlay(alignment: .bottomLeading) {
                    Text(clip.payload)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(3)
                }
        case .image:
            if let data = clip.thumbnailData ?? clip.imageData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "photo").foregroundStyle(.white.opacity(0.4))
            }
        case .file:
            HStack(spacing: 5) {
                Image(systemName: "doc").font(.system(size: 12))
                Text((clip.payload as NSString).lastPathComponent)
                    .font(.system(size: 10.5))
                    .lineLimit(2)
            }
            .foregroundStyle(.white.opacity(0.75))
        case .link:
            Text(clip.payload)
                .font(.system(size: 10.5))
                .foregroundStyle(Color(hex: "#6E9FFF"))
                .lineLimit(3)
        case .dictation, .text:
            Text(clip.payload)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(3)
        }
    }

    /// `Color(hex:)` scans a 6-digit string only: shorthand (`#F00`) would
    /// scan as `0x000F00` and a non-hex color literal (`rgb(…)`, which the
    /// classifier also calls `.color`) as black. Expand the first; give the
    /// second a neutral swatch that keeps the white hex overlay readable.
    private var normalizedHex: String {
        let payload = clip.payload
        guard payload.hasPrefix("#") else { return "#3A3A3C" }
        let digits = payload.dropFirst()
        switch digits.count {
        case 3: return "#" + String(digits.flatMap { [$0, $0] })
        case 6: return payload
        default: return "#3A3A3C"
        }
    }

    private var cardBackground: Color {
        clip.kind == .dictation ? Color(hex: "#7F77DD").opacity(0.14) : .white.opacity(0.06)
    }
}
#endif
