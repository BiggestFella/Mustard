import SwiftUI
import SwiftData

public struct QuickCaptureField: View {
    @Environment(\.modelContext) private var context
    /// When set, captured tasks are scheduled onto this day at 9:00.
    var scheduleOnto: Date?
    /// When set, captured tasks are filed into this list.
    var fileInto: TaskList?
    /// Placeholder text — shortened in narrow contexts (e.g. Week day columns).
    var placeholder: String = "Add a task…"
    @State private var text = ""
    @FocusState private var focused: Bool

    public init(scheduleOnto: Date? = nil, fileInto: TaskList? = nil, placeholder: String = "Add a task…") {
        self.scheduleOnto = scheduleOnto
        self.fileInto = fileInto
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button(action: capture) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($focused)
                .onSubmit(capture)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }

    private func capture() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { focused = true; return }
        let task = MustardTask(title: trimmed)
        if let day = scheduleOnto {
            task.scheduledAt = Calendar.current.date(
                bySettingHour: 9, minute: 0, second: 0, of: day)
            PersonalBoard.normalizePlacement(task)
        }
        if let list = fileInto { task.list = list }
        context.insert(task)
        text = ""
        focused = true
    }
}
