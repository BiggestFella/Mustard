import Foundation
import SwiftData

/// Applies `ClipStoreRules` to candidates and writes results into SwiftData.
/// No decisions live here beyond fetch/insert/delete plumbing.
@MainActor
public final class ClipStore {
    private let context: ModelContext
    private let historyLimit: Int

    public init(context: ModelContext, historyLimit: Int = ClipStoreRules.historyLimit) {
        self.context = context
        self.historyLimit = historyLimit
    }

    private var latest: ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [.init(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Pasteboard observation → maybe a stored clip + prune.
    ///
    /// Precedence when a candidate carries more than one representation: a
    /// file URL always wins. Otherwise, image bytes win only when the
    /// accompanying text is empty or is itself just a link — that's the
    /// shape of a browser "Copy Image" (image bytes + the image's own URL
    /// as text). When the accompanying text is substantive prose (e.g. an
    /// Excel/Numbers cell copy that also renders a bitmap fallback), the
    /// text is the real intent and wins instead.
    public func ingest(_ candidate: ClipCandidate) {
        guard ClipStoreRules.shouldCapture(candidate, latestPayload: latest?.payload) else {
            return
        }
        let trimmed = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clip: ClipItem
        if let fileURL = candidate.fileURLs.first {
            clip = ClipItem(kind: .file, payload: fileURL.path)
        } else if let image = candidate.imageData,
            trimmed.isEmpty || ClipClassifier.classify(text: trimmed) == .link {
            clip = ClipItem(kind: .image, payload: "")
            store(imageData: image, on: clip)
        } else {
            clip = ClipItem(kind: ClipClassifier.classify(text: trimmed), payload: trimmed)
        }
        clip.sourceBundleID = candidate.sourceBundleID
        clip.sourceAppName = candidate.sourceAppName
        context.insert(clip)
        prune()
        try? context.save()
    }

    public func addDictation(transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clip = ClipItem(kind: .dictation, payload: trimmed)
        clip.sourceAppName = "Dictation"
        context.insert(clip)
        prune()
        try? context.save()
    }

    public func addShelfDrop(text: String) {
        let clip = ClipItem(kind: ClipClassifier.classify(text: text), payload: text)
        clip.pinnedToShelf = true
        context.insert(clip)
        try? context.save()
    }

    public func addShelfDrop(fileURL: URL) {
        let clip = ClipItem(kind: .file, payload: fileURL.path)
        clip.pinnedToShelf = true
        context.insert(clip)
        try? context.save()
    }

    public func addShelfDrop(imageData: Data) {
        let clip = ClipItem(kind: .image, payload: "")
        store(imageData: imageData, on: clip)
        clip.pinnedToShelf = true
        context.insert(clip)
        try? context.save()
    }

    /// Spec §8: originals only up to 5 MB; always a ≤480 px JPEG thumbnail.
    private func store(imageData: Data, on clip: ClipItem) {
        if imageData.count <= 5 * 1024 * 1024 { clip.imageData = imageData }
        clip.thumbnailData = ClipThumbnail.jpegThumbnail(from: imageData, maxEdge: 480)
    }

    private func prune() {
        let all = (try? context.fetch(FetchDescriptor<ClipItem>())) ?? []
        let doomed = Set(ClipStoreRules.pruneUIDs(all, limit: historyLimit))
        guard !doomed.isEmpty else { return }
        for clip in all where doomed.contains(clip.uid) {
            context.delete(clip)
        }
    }
}

#if os(macOS)
import AppKit

enum ClipThumbnail {
    static func jpegThumbnail(from data: Data, maxEdge: CGFloat) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
#endif
