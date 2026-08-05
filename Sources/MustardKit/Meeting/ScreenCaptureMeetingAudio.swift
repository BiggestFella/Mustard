#if os(macOS)
import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

public enum MeetingCaptureError: Error, Equatable {
    case noDisplay
    case notStarted
}

/// The live `MeetingAudioCapturing` over ScreenCaptureKit (meeting recorder
/// Task 4 Step 3, BAK-296): ONE `SCStream` carrying both audio outputs —
/// `.audio` (system audio: the other side playing through this Mac) and
/// `.microphone` (you) — at 48 kHz mono, sharing the host clock. No `.screen`
/// output is ever added and no video frame is captured or stored.
///
/// Scope note (surfaced for the matrix): the display-level `SCContentFilter`
/// used here captures ALL system audio — a Chrome app-scoped filter would
/// still include every Chrome tab's audio, not just the meeting tab. Mustard
/// records the whole system mix by design and relies on the persistent
/// recording indicator + consent reminder.
public final class ScreenCaptureMeetingAudio: NSObject, MeetingAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var paused = false
    private var continuations: [MeetingAudioSource: AsyncThrowingStream<MeetingAudioSample, Error>.Continuation] = [:]
    private let sampleQueue = DispatchQueue(label: "com.cavehole.mustard.meeting-audio")

    /// Passive checks only — nothing here prompts (Voice Setup owns prompts).
    public func availableSources() async throws -> [MeetingAudioSource] {
        var sources: [MeetingAudioSource] = []
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            sources.append(.microphone)
        }
        if CGPreflightScreenCaptureAccess() {
            sources.append(.systemAudio)
        }
        return sources
    }

    /// Register interest in one source's samples. The single underlying
    /// stream (with BOTH outputs) is built and started on the first call;
    /// later calls only attach their continuation.
    public func start(source: MeetingAudioSource) async throws -> AsyncThrowingStream<MeetingAudioSample, Error> {
        try await ensureStream()
        let (stream, continuation) = AsyncThrowingStream<MeetingAudioSample, Error>.makeStream()
        lock.lock()
        continuations[source] = continuation
        lock.unlock()
        return stream
    }

    /// Keep the stream alive but drop samples — resume picks up instantly
    /// without renegotiating capture.
    public func pause() async throws {
        lock.lock(); paused = true; lock.unlock()
    }

    public func resume() async throws {
        lock.lock(); paused = false; lock.unlock()
    }

    public func stop() async throws {
        let current: SCStream?
        lock.lock()
        current = stream
        stream = nil
        let open = continuations
        continuations = [:]
        lock.unlock()
        for continuation in open.values { continuation.finish() }
        try await current?.stopCapture()
    }

    // MARK: - Stream construction

    private func ensureStream() async throws {
        lock.lock()
        let existing = stream
        lock.unlock()
        guard existing == nil else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw MeetingCaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // Mustard's own sounds never belong in the meeting record.
        configuration.excludesCurrentProcessAudio = true

        let built = SCStream(filter: filter, configuration: configuration, delegate: self)
        try built.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try built.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        try await built.startCapture()
        lock.lock()
        stream = built
        lock.unlock()
    }

    // MARK: - Sample conversion

    /// CMSampleBuffer → PCM + host-clock seconds. Nil for anything that
    /// cannot be represented (dropped, never crashed on).
    static func pcm(from sampleBuffer: CMSampleBuffer) -> (AVAudioPCMBuffer, Double)? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return (pcm, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
}

extension ScreenCaptureMeetingAudio: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        let source: MeetingAudioSource
        switch type {
        case .audio: source = .systemAudio
        case .microphone: source = .microphone
        default: return   // .screen is never added; ignore defensively
        }
        lock.lock()
        let continuation = paused ? nil : continuations[source]
        lock.unlock()
        guard let continuation,
              let (buffer, seconds) = Self.pcm(from: sampleBuffer) else { return }
        continuation.yield(MeetingAudioSample(
            source: source, buffer: buffer, hostSeconds: seconds))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let open = continuations
        continuations = [:]
        self.stream = nil
        lock.unlock()
        // Both feeds fail together (one stream); upstream pauses them visibly.
        for continuation in open.values { continuation.finish(throwing: error) }
    }
}
#endif
