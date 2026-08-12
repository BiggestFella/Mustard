#if os(macOS)
import SwiftUI

/// Agent tab: what's waiting on Leon, as read-only rows — the notch
/// surfaces, the Agent console acts (locked decision, 2026-07-02 redesign).
/// Stub until the Agent-tab task fills it in; the shell already routes here.
/// Notch surfaces use explicit dark hex, never `Theme`.
struct NotchAgentTab: View {
    var body: some View {
        Text("Agent")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.4))
    }
}
#endif
