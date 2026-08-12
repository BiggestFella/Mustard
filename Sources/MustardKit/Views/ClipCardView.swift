#if os(macOS)
import SwiftUI

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

    /// `Color(hex:)` scans whatever it's given, so a non-hex color literal
    /// (`rgb(…)`, which the classifier also calls `.color`) falls back to
    /// white rather than rendering as black.
    private var normalizedHex: String {
        clip.payload.hasPrefix("#") ? clip.payload : "#FFFFFF"
    }

    private var cardBackground: Color {
        clip.kind == .dictation ? Color(hex: "#7F77DD").opacity(0.14) : .white.opacity(0.06)
    }
}
#endif
