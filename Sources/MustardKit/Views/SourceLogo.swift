import SwiftUI

/// Brand-mark glyph for a triage item's source. The artwork is each brand's real,
/// official logo mark — traced from Simple Icons (simpleicons.org), which publishes
/// brand icons precisely for this kind of "which service did this come from" use —
/// bundled as template PNGs in `Resources/Assets.xcassets` and tinted with the
/// brand's documented hex. `id` comes from `SourceBadge.id`/`SourceLink.id` so
/// callers never re-parse the raw `Recommendation.source` string.
public struct SourceLogo: View {
    let source: SourceID
    let size: CGFloat

    public init(source: SourceID, size: CGFloat = 13) {
        self.source = source
        self.size = size
    }

    public var body: some View {
        switch source {
        case .gmail:
            // Gmail's mark ships as a plain colored glyph, not a tile — matches how
            // Google presents it.
            mark("gmail-logo").foregroundStyle(Color(hex: "#EA4335"))
                .frame(width: size, height: size)
        case .jira:
            tile(hex: "#0052CC") { mark("jira-logo") }
        case .shortcut:
            tile(hex: "#58B1E4") { mark("shortcut-logo") }
        case .vault:
            Image(systemName: "books.vertical")
                .font(.system(size: size * 0.85))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private func mark(_ assetName: String) -> some View {
        Image(assetName, bundle: .module)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    /// A colored rounded-square tile with a white glyph inset — how Jira and
    /// Shortcut present their marks as app/product icons.
    private func tile<Glyph: View>(hex: String, @ViewBuilder glyph: () -> Glyph) -> some View {
        let s = size
        return RoundedRectangle(cornerRadius: s * 0.24)
            .fill(Color(hex: hex))
            .overlay {
                glyph()
                    .foregroundStyle(.white)
                    .padding(s * 0.22)
            }
            .frame(width: s, height: s)
    }
}
