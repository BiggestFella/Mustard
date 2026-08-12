import Foundation
import SwiftData

/// One captured clipboard item (notch shelf spec §3–4). Clips are automatic
/// history; `pinnedToShelf` flips one into a deliberate keep. Filed items
/// (non-nil `collection`) and pinned items are exempt from pruning.
@Model
public final class ClipItem {
    public var uid: String = UUID().uuidString
    public var kindRaw: String = ClipKind.text.rawValue
    /// Text payload: the string itself, URL absoluteString, color literal,
    /// file path, or dictation transcript. Empty for image clips.
    public var payload: String = ""
    /// Downsampled preview for image clips (≤ 480 px long edge, JPEG).
    @Attribute(.externalStorage) public var thumbnailData: Data?
    /// Original image, only when ≤ 5 MB (spec §8); larger images keep just
    /// the thumbnail.
    @Attribute(.externalStorage) public var imageData: Data?
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var pinnedToShelf: Bool = false
    public var createdAt: Date = Date.now
    public var collection: ClipCollection?

    public init(kind: ClipKind = .text, payload: String = "") {
        self.kindRaw = kind.rawValue
        self.payload = payload
    }

    public var kind: ClipKind {
        get { ClipKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }
}
