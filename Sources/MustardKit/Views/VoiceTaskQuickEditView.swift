#if os(macOS)
import SwiftUI

/// The notch-adjacent quick-edit card (Capture Task 4, BAK-284): a thin,
/// themed form over `VoiceTaskQuickEditState` — title, notes, links, area,
/// schedule, and Save / Close / Open Fully. Every decision (what a key does,
/// what commit applies, revision gating) lives in the state; this view only
/// renders, focuses, and dispatches.
public struct VoiceTaskQuickEditView: View {
    @Bindable private var state: VoiceTaskQuickEditState
    @FocusState private var focus: VoiceTaskField?
    @State private var newLink = ""

    public init(state: VoiceTaskQuickEditState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("VOICE TASK")
                .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)

            TextField("Task title", text: Binding(
                get: { state.draft.title },
                set: { state.draft.title = $0; state.userChanged(.title) }
            ))
            .textFieldStyle(.plain)
            .font(Theme.Fonts.header)
            .foregroundStyle(Theme.Palette.textPrimary)
            .focused($focus, equals: .title)
            .onSubmit { state.handle(.plainReturn(in: .title)) }

            notesField

            linksField

            HStack(spacing: 16) {
                areaPicker
                schedulePicker
                Spacer()
            }

            Divider().overlay(Theme.Palette.hairline)

            HStack(spacing: 10) {
                Button("Open Fully") { state.openFully() }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.accent)
                Spacer()
                Button("Close") { state.handle(.escape) }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button("Save") { state.handle(.commandReturn) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 440, alignment: .leading)
        .elevation(.float, cornerRadius: 14)
        .padding(8)
        .onExitCommand { state.handle(.escape) }
        .onAppear { focus = .title }
    }

    private var notesField: some View {
        TextEditor(text: Binding(
            get: { state.draft.notes ?? "" },
            set: { state.draft.notes = $0.isEmpty ? nil : $0; state.userChanged(.notes) }
        ))
        .font(Theme.Fonts.body)
        .foregroundStyle(Theme.Palette.textPrimary)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 54, maxHeight: 110)
        .padding(6)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .focused($focus, equals: .notes)
        .overlay(alignment: .topLeading) {
            if (state.draft.notes ?? "").isEmpty {
                Text("Notes")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, 11).padding(.leading, 11)
                    .allowsHitTesting(false)
            }
        }
    }

    private var linksField: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.draft.urls, id: \.absoluteString) { url in
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(url.absoluteString)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.accent)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        state.draft.urls.removeAll { $0 == url }
                        state.userChanged(.urls)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("Add link…", text: $newLink)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .focused($focus, equals: .urls)
                .onSubmit {
                    // Deterministic URL validation — same rule as the generator.
                    let accepted = VoiceTaskDrafting.validatedURLs([newLink])
                    guard let url = accepted.first else { return }
                    if !state.draft.urls.contains(url) {
                        state.draft.urls.append(url)
                        state.userChanged(.urls)
                    }
                    newLink = ""
                }
        }
    }

    private var areaPicker: some View {
        Picker("Area", selection: Binding(
            get: { state.draft.areaName ?? "" },
            set: {
                state.draft.areaName = $0.isEmpty ? nil : $0
                state.userChanged(.area)
            }
        )) {
            Text("No area").tag("")
            ForEach(state.areaNames, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .font(Theme.Fonts.meta)
        .fixedSize()
    }

    @ViewBuilder private var schedulePicker: some View {
        if let date = state.draft.scheduledDate {
            HStack(spacing: 4) {
                DatePicker("", selection: Binding(
                    get: { date },
                    set: { state.draft.scheduledDate = $0; state.userChanged(.schedule) }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                Button {
                    state.draft.scheduledDate = nil
                    state.userChanged(.schedule)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                // Day-level default: tomorrow 9:00 (quick-capture convention).
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
                state.draft.scheduledDate = Calendar.current.date(
                    bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
                state.userChanged(.schedule)
            } label: {
                Label("Schedule", systemImage: "calendar")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}
#endif
