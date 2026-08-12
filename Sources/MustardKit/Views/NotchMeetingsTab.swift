#if os(macOS)
import SwiftUI

/// Meetings tab: the live recorder plus recent recordings. Stub until the
/// Meetings-tab task moves `MeetingRecordingNotchView` and the recent list
/// in here. Notch surfaces use explicit dark hex, never `Theme`.
struct NotchMeetingsTab: View {
    var body: some View {
        Text("Meetings")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.4))
    }
}
#endif
