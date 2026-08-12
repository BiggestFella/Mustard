import XCTest
import SwiftData
import AppKit
@testable import MustardKit

@MainActor
final class ClipStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ClipItem.self, ClipCollection.self, configurations: config)
        return ModelContext(container)
    }

    private func candidate(_ text: String, bundle: String = "com.apple.Safari") -> ClipCandidate {
        ClipCandidate(
            text: text, imageData: nil, fileURLs: [], sourceBundleID: bundle,
            sourceAppName: "Safari", isConcealed: false, isTransient: false)
    }

    /// A tiny valid PNG — well under the 5 MB cap.
    private func makeSmallPNG() throws -> Data {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// A valid PNG whose pixel data is random noise, so it can't compress
    /// down — this reliably exceeds the 5 MB cap.
    private func makeOversizePNG() throws -> Data {
        let width = 1500
        let height = 1500
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmapData = try XCTUnwrap(rep.bitmapData)
        let byteCount = rep.bytesPerRow * height
        arc4random_buf(bitmapData, byteCount)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testIngestInsertsClassifiedClip() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.ingest(candidate("https://supaste.com"))
        let clips = try context.fetch(FetchDescriptor<ClipItem>())
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].kind, .link)
        XCTAssertEqual(clips[0].payload, "https://supaste.com")
        XCTAssertEqual(clips[0].sourceAppName, "Safari")
    }

    func testIngestSkipsConsecutiveDuplicate() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.ingest(candidate("same"))
        store.ingest(candidate("same"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<ClipItem>()).count, 1)
    }

    func testIngestPrunesOldestBeyondLimit() throws {
        let context = try makeContext()
        let store = ClipStore(context: context, historyLimit: 3)
        for i in 0..<5 { store.ingest(candidate("item \(i)")) }
        let clips = try context.fetch(FetchDescriptor<ClipItem>())
            .sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(clips.map(\.payload), ["item 2", "item 3", "item 4"])
    }

    func testPinnedSurvivesPrune() throws {
        let context = try makeContext()
        let store = ClipStore(context: context, historyLimit: 2)
        store.ingest(candidate("keep me"))
        let first = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        first.pinnedToShelf = true
        for i in 0..<4 { store.ingest(candidate("item \(i)")) }
        let payloads = try context.fetch(FetchDescriptor<ClipItem>()).map(\.payload)
        XCTAssertTrue(payloads.contains("keep me"))
        XCTAssertEqual(payloads.count, 3)  // pinned + 2 history
    }

    func testAddDictation() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.addDictation(transcript: "note to self")
        let clip = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        XCTAssertEqual(clip.kind, .dictation)
        XCTAssertEqual(clip.payload, "note to self")
        XCTAssertEqual(clip.sourceAppName, "Dictation")
    }

    func testAddShelfDropString() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.addShelfDrop(text: "dropped words")
        let clip = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        XCTAssertTrue(clip.pinnedToShelf)
        XCTAssertEqual(clip.kind, .text)
    }

    func testAddShelfDropFile() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        store.addShelfDrop(fileURL: URL(fileURLWithPath: "/tmp/report.pdf"))
        let clip = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        XCTAssertTrue(clip.pinnedToShelf)
        XCTAssertEqual(clip.kind, .file)
        XCTAssertEqual(clip.payload, "/tmp/report.pdf")
    }

    func testSmallImageKeepsOriginalAndThumbnail() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        let png = try makeSmallPNG()
        store.addShelfDrop(imageData: png)
        let clip = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        XCTAssertEqual(clip.kind, .image)
        XCTAssertNotNil(clip.imageData)
        XCTAssertNotNil(clip.thumbnailData)
        XCTAssertTrue(clip.pinnedToShelf)
    }

    func testOversizeImageKeepsOnlyThumbnail() throws {
        let context = try makeContext()
        let store = ClipStore(context: context)
        let png = try makeOversizePNG()
        XCTAssertGreaterThan(
            png.count, 5 * 1024 * 1024, "test PNG must exceed the 5 MB cap to be meaningful")
        store.addShelfDrop(imageData: png)
        let clip = try XCTUnwrap(context.fetch(FetchDescriptor<ClipItem>()).first)
        XCTAssertNil(clip.imageData)
        XCTAssertNotNil(clip.thumbnailData)
    }
}
