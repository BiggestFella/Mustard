#if os(macOS)
import SwiftUI

/// The ⌃⌥R review card: a pure function of `RewriteCoordinator.phase`. Nothing
/// in the target application changes until Return is pressed here.
///
/// Keyboard handling lives on the card because the panel is non-activating —
/// Mustard never comes forward, so these key presses are the only input path.
@available(macOS 26.0, iOS 26.0, *)
public struct RewriteCardView: View {
    private let coordinator: RewriteCoordinator
    /// Routes the accessibility refusal to the existing Voice Setup surface.
    private let openVoiceSetup: () -> Void

    public init(coordinator: RewriteCoordinator, openVoiceSetup: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.openVoiceSetup = openVoiceSetup
    }

    public var body: some View {
        Group {
            switch coordinator.phase {
            case .idle:
                EmptyView()
            case .reading:
                working(label: "Reading the selection…", intent: nil)
            case .generating(let intent):
                working(label: "Rewriting…", intent: intent)
            case .reviewing(let review):
                reviewing(review)
            case .refused(let refusal):
                refused(refusal)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 460, alignment: .leading)
        .elevation(.float, cornerRadius: 18)
        .padding(8)
        .animation(Theme.Motion.settle, value: coordinator.phase)
        .onKeyPress(.return) { accept(); return .handled }
        .onKeyPress(.escape) { coordinator.discard(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
            guard let digit = press.characters.first.flatMap({ Int(String($0)) }),
                  let intent = RewriteIntent(shortcutDigit: digit) else { return .ignored }
            Task { await coordinator.change(intent: intent) }
            return .handled
        }
    }

    // MARK: - States

    @ViewBuilder
    private func working(label: String, intent: RewriteIntent?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            intentChips(active: intent)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func reviewing(_ review: RewriteReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            intentChips(active: review.intent)

            Text(review.rewritten)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(review.original)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(wordDelta(review))
                    if !review.changeNote.isEmpty {
                        Text("·")
                        Text(review.changeNote)
                    }
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            }

            if let failure = review.writeFailure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Palette.warning)
                    Text("Couldn't write it back — \(failure). Your original is unchanged.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.warnText)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(review.rewritten, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(Theme.Fonts.caption)
                }
            }

            hints("return replace · esc discard · ⌃⌥R another take")
        }
    }

    @ViewBuilder
    private func refused(_ refusal: RewriteRefusal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: refusal == .secureField ? "lock.fill" : "exclamationmark.circle")
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(refusal.message)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if refusal == .accessibilityPermissionMissing {
                Button("Open Voice Setup", action: openVoiceSetup)
                    .buttonStyle(.link)
                    .font(Theme.Fonts.caption)
            }
            hints("esc dismiss")
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func intentChips(active: RewriteIntent?) -> some View {
        HStack(spacing: 6) {
            ForEach(RewriteIntent.allCases, id: \.self) { intent in
                let isActive = intent == active
                Text("\(intent.shortcutDigit)  \(intent.title)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(isActive ? Theme.Palette.accent : Theme.Palette.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isActive ? Theme.Palette.chipActive : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isActive ? Theme.Palette.chipActiveBorder : Theme.Palette.hairline,
                                    lineWidth: 0.5))
            }
        }
    }

    @ViewBuilder
    private func hints(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Palette.textFaint)
    }

    private func wordDelta(_ review: RewriteReview) -> String {
        let before = RewriteBudget.wordCount(review.original)
        let after = RewriteBudget.wordCount(review.rewritten)
        return "\(before) → \(after) words"
    }

    private func accept() {
        Task { await coordinator.accept() }
    }
}
#endif
