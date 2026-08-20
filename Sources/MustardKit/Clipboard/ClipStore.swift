import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftData
import UniformTypeIdentifiers

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

/// Environment bundle for the clipboard layer (store + monitor + paster),
/// injected into the notch content the way `AgentService` is. The notch tabs
/// read it optionally, so a surface that predates the injection still renders.
@MainActor
@Observable
public final class ClipboardServices {
    public let store: ClipStore
    public let monitor: ClipboardMonitor
    public let paster: ClipPaster

    public init(store: ClipStore, monitor: ClipboardMonitor, paster: ClipPaster) {
        self.store = store
        self.monitor = monitor
        self.paster = paster
    }
}

/// Downscaled JPEG preview for a stored image clip.
///
/// ImageIO, not AppKit: `NSImage` is macOS-only, and `ClipStore` compiles for
/// the iOS companion too (project.yml) — the AppKit version was invisible there
/// and broke `./build-ios.sh`. `CGImageSource` thumbnailing caps the long edge
/// and never upscales, which is what the old `min(1, maxEdge / longEdge)` did.
enum ClipThumbnail {
    static func jpegThumbnail(from data: Data, maxEdge: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxEdge),
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
