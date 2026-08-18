import Foundation

/// The `mustard-note://` link scheme — ONE encoding shared by every surface that
/// renders tappable wikilinks (MarkdownBlocksView's AttributedString links and
/// MarkdownTextView's NSTextStorage `.link` attributes). Extracted from the
/// old preview (Craft 2a) so a click decodes identically everywhere.
///
/// The raw target rides in a QUERY ITEM rather than the host/path, because
/// host/path round-tripping mangles spaces, case, and slashes (URL normalises the
/// authority). `URLQueryItem` percent-encodes the value on construction and
/// `URLComponents.queryItems` decodes it losslessly — so targets like "My Note",
/// "guides/Deep Dive", and unicode all survive the tap round-trip.
public enum WikilinkURL {
    private static let scheme = "mustard-note"
    private static let queryKey = "t"

    public static func url(for target: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "link"
        components.queryItems = [URLQueryItem(name: queryKey, value: target)]
        return components.url
    }

    /// The target carried by a `mustard-note://` URL; nil for foreign schemes —
    /// callers pass those through to the system.
    public static func target(from url: URL) -> String? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let item = components.queryItems?.first(where: { $0.name == queryKey })
        else { return nil }
        return item.value
    }
}
