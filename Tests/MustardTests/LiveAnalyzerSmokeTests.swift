import XCTest
import AVFoundation
@testable import MustardKit

/// End-to-end check of the **real** analyzer stack — `AppleSpeechSession` over
/// the live `AppleSpeechAnalyzerDriver`, real Speech assets, real
/// `SpeechTranscriber` — fed a file of known words instead of a microphone.
///
/// **Why this exists.** Everything else about the live path is either pure logic
/// (covered by `AnalyzerInputResamplerTests`, `AppleSpeechSessionTests`) or
/// unverifiable without hardware, and the gap between the two is exactly where
/// the `AnalyzerInputConverter` removal landed: the code compiled, the unit tests
/// passed, and only a real `SpeechAnalyzer` could say whether the buffers we hand
/// it are acceptable. It is not a fixture-based test — it downloads assets if
/// they are missing and shells out to `say` — so it is **opt-in**, in the same
/// shape as `SnapshotRenderTests`:
///
/// ```bash
/// MUSTARD_LIVE_ANALYZER=1 swift test --filter LiveAnalyzerSmokeTests
/// ```
///
/// A failure here means real dictation and real meeting transcription are broken,
/// whatever the rest of the suite says.
final class LiveAnalyzerSmokeTests: XCTestCase {

    private static let phrase = "testing one two three four five"

    func test_liveAnalyzer_transcribesAFileOfKnownWords() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MUSTARD_LIVE_ANALYZER"] == "1",
            "set MUSTARD_LIVE_ANALYZER=1 to run the live analyzer smoke test")
        guard #available(macOS 27.0, *) else {
            throw XCTSkip("The live analyzer driver requires macOS 27")
        }

        let audio = try Self.spokenAudioFile(Self.phrase)
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }

        let readiness = VoiceAssetReadiness.live()
        guard let locale = await readiness.resolveLocale(Locale(identifier: "en_US")) else {
            throw XCTSkip("no supported transcription locale equivalent to en_US")
        }

        let session = AppleSpeechSession(
            driver: AppleSpeechAnalyzerDriver(locale: locale),
            readiness: { await readiness.prepare(locale: locale) },
            prepare: { await readiness.prepare(locale: locale) })

        // Installs assets when absent; throws `.notReady` when the machine
        // genuinely cannot transcribe, which is a skip rather than a failure.
        do {
            try await session.prepare()
        } catch {
            throw XCTSkip("speech assets unavailable on this machine: \(error)")
        }

        _ = try await session.start(source: .meeting)
        let file = try AVAudioFile(forReading: audio)
        let chunk: AVAudioFrameCount = 4_096
        var fed = 0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try await session.append(buffer, at: nil)
            fed += 1
        }
        XCTAssertGreaterThan(fed, 0, "the fixture file must yield audio")

        let finals = try await session.finish()
        let transcript = finals.map(\.text).joined(separator: " ").lowercased()

        XCTAssertFalse(
            finals.isEmpty,
            "the live analyzer produced no final segments for \(fed) fed buffers — "
                + "the buffers we hand `AnalyzerInput` are being rejected")
        XCTAssertTrue(
            transcript.contains("testing"),
            "expected the spoken phrase back, got '\(transcript)'")
        // Digits come back numeric ("one, 2, 3"), so only the leading word is
        // asserted verbatim; this guards the timeline, not the formatter.
        XCTAssertTrue(
            finals.allSatisfy { $0.startSeconds >= 0 },
            "segment times must be capture-relative, not host time: \(finals.map(\.startSeconds))")
    }

    // MARK: - Fixture

    /// Renders the phrase to an audio file with `say`. Returns the file URL; its
    /// parent directory is the caller's to clean up.
    private static func spokenAudioFile(_ text: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mustard-live-analyzer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("phrase.aiff")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", output.path, text]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output.path) else {
            throw XCTSkip("`say` could not render the fixture (status \(process.terminationStatus))")
        }
        return output
    }
}
