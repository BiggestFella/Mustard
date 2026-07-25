import SwiftUI
import AppKit

/// A compact source-glyph button that opens the item's source in the inspector.
/// Renders nothing when the item has no openable (http/https) source.
struct SourceLinkButton: View {
    let link: SourceLink?

    init(rec: Recommendation) { link = SourceLink(from: rec) }
    init(task: MustardTask) { link = SourceLink(from: task) }

    var body: some View {
        if let link { SourceLinkButtonInner(link: link) }
    }
}

private struct SourceLinkButtonInner: View {
    // Optional: present in the main window (RootView injects it), absent in a
    // modal sheet's hosting context. Optional avoids a fatal @Environment trap.
    @Environment(SourcePanelController.self) private var panel: SourcePanelController?
    @Environment(\.openURL) private var openURL
    let link: SourceLink

    /// Open in the inspector when the controller is reachable; otherwise fall back
    /// to the external browser — e.g. from a modal sheet, where the inspector would
    /// be hidden behind the sheet anyway, so the browser is the better destination.
    private func open() {
        if let panel { panel.open(link) } else { openURL(link.url) }
    }

    var body: some View {
        Button { open() } label: {
            SourceLogo(source: link.id, size: 14)
        }
        .buttonStyle(.plain)
        .help("Open source — \(link.sourceName)")
        .contextMenu {
            Button("Open in panel") { open() }
            Button("Open in browser") { openURL(link.url) }
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }
        }
    }
}
