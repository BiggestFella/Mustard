import CoreGraphics

/// Reading-measure setting for the note editor column (Notes polish pack). Persisted
/// globally via @AppStorage("noteEditorWidth"); `NoteEditorView` applies `maxWidth`.
public enum NoteEditorWidth: String, CaseIterable, Identifiable, Equatable {
    case comfortable, wide, full

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .wide: return "Wide"
        case .full: return "Full"
        }
    }

    /// nil = no constraint (full-bleed). Points, matching the prior fixed 720 measure.
    public var maxWidth: CGFloat? {
        switch self {
        case .comfortable: return 720
        case .wide: return 960
        case .full: return nil
        }
    }
}
