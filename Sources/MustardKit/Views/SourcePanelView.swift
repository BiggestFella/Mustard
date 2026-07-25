import SwiftUI

/// The trailing-inspector content: calm chrome over an embedded web view, with
/// empty / loading / error states. Reads the current link from the controller.
struct SourcePanelView: View {
    @Environment(SourcePanelController.self) private var panel
    @Environment(\.openURL) private var openURL
    @State private var web = WebViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if let link = panel.current {
                chrome(link)
                Divider().overlay(Theme.Palette.hairline)
                ZStack {
                    WebView(url: link.url, model: web)
                    if web.loadFailed { errorState(link) }
                }
            } else {
                emptyState
            }
        }
        .background(Theme.Palette.bg)
        .onChange(of: panel.current) { _, _ in
            web.loadFailed = false
            web.isLoading = true
        }
    }

    private func chrome(_ link: SourceLink) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SourceLogo(source: link.id, size: 15)
                Text(link.label)
                    .font(Theme.Fonts.title).foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                Button { openURL(link.url) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.textTertiary)
                    .help("Open in your browser")
                Button { panel.isPresented = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.textTertiary)
                    .help("Close panel")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            HStack(spacing: 10) {
                Button { web.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).disabled(!web.canGoBack)
                Button { web.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).disabled(!web.canGoForward)
                Button { web.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                Text(link.url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if web.isLoading { ProgressView().controlSize(.small) }
            }
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(Theme.Palette.textTertiary)
            Text("Select an item with a source to preview it here.")
                .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func errorState(_ link: SourceLink) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26))
                .foregroundStyle(Theme.Palette.warning)
            Text("This page needs sign-in or is offline.")
                .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button { openURL(link.url) } label: {
                Label("Open in browser", systemImage: "arrow.up.right")
            }
            .controlSize(.small).tint(Theme.Palette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24).background(Theme.Palette.bg)
    }
}
