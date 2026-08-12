import AppKit
import SwiftUI

/// One hotkey row's recorder field: click to arm, press the new chord.
/// Esc cancels, ⌫ resets to the default. All accept/reject decisions are
/// pure (`HotKeyRecorderLogic`, `HotKeyValidation`, `HotKeyConflicts` via the
/// store) — this view only arms/disarms the NSEvent monitor and renders.
struct HotKeyRecorderView: View {
    let action: HotKeyAction
    @Environment(HotKeyBindingsStore.self) private var hotKeys
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        HStack(spacing: 8) {
            if let rejection {
                Text(rejection)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.error)
            }
            Button {
                isRecording ? disarm() : arm()
            } label: {
                Text(isRecording ? "Press keys…" : hotKeys.chord(for: action).description)
                    .font(Theme.Fonts.meta.monospaced())
                    .foregroundStyle(isRecording ? Theme.Palette.accent : Theme.Palette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 96)
                    .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isRecording ? Theme.Palette.accent : Theme.Palette.hairline,
                                lineWidth: isRecording ? 1 : 0.5))
            }
            .buttonStyle(.plain)
            .help("Click, then press the new shortcut. Esc cancels, ⌫ resets to the default.")

            Button {
                rejection = nil
                hotKeys.reset(action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Reset to \(action.defaultChord.description)")
        }
        .onDisappear { disarm() }
    }

    private func arm() {
        rejection = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil  // swallow while armed — the pressed chord must not reach the app
        }
    }

    private func disarm() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        switch HotKeyRecorderLogic.outcome(
            keyCode: UInt32(event.keyCode), nsEventFlags: event.modifierFlags.rawValue)
        {
        case .cancel:
            disarm()
        case .reset:
            hotKeys.reset(action)
            disarm()
        case let .capture(keyCode, carbonModifiers):
            switch hotKeys.attemptSet(
                HotKeyChord(keyCode: keyCode, carbonModifiers: carbonModifiers), for: action)
            {
            case .saved:
                disarm()
            case .rejected(let why):
                rejection = why  // stay armed so the next attempt is one keypress away
            }
        }
    }
}
