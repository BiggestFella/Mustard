import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ClaudeFailureSource: Equatable, Sendable {
    case launch
    case outerError
    case exitStatus
    case timedOut
    case cancelled
    case duplicateInvocation
}

public struct ClaudeResult: Sendable {
    public let ok: Bool
    /// Result text on success, error description on failure.
    public let text: String
    /// True when the failure looks like a usage/rate limit.
    public let rateLimited: Bool
    /// True when a zero-exit run's stdout wasn't the expected `{result,is_error}` JSON
    /// shape, so `text` is raw fallback stdout rather than a parsed `result` field. Lets
    /// callers detect "claude ran but we couldn't parse its output" instead of silently
    /// treating unparsed prose as a fully-understood success.
    public let unparsed: Bool
    /// Machine-readable origin used to distinguish provider/process failures from
    /// task-authored text that happens to mention an error phrase.
    public let failureSource: ClaudeFailureSource?
    public let stderr: String
    public let exitStatus: Int32?

    public init(
        ok: Bool,
        text: String,
        rateLimited: Bool = false,
        unparsed: Bool = false,
        failureSource: ClaudeFailureSource? = nil,
        stderr: String = "",
        exitStatus: Int32? = nil
    ) {
        self.ok = ok
        self.text = text
        self.rateLimited = rateLimited
        self.unparsed = unparsed
        self.failureSource = failureSource
        self.stderr = stderr
        self.exitStatus = exitStatus
    }
}

/// (prompt, workingDirectory) → result. Injected so tests use a stub.
public typealias ClaudeRun = @Sendable (String, String) async -> ClaudeResult

public struct ClaudeCancellationToken: Hashable, Sendable {
    public let id: UUID
    public let generation: UUID

    public init(id: UUID, generation: UUID = UUID()) {
        self.id = id
        self.generation = generation
    }
}

public struct ClaudeInvocation: Sendable {
    public let id: UUID
    public let arguments: [String]
    public let workingDirectory: String
    public let stdinData: Data?
    public let cancellationToken: ClaudeCancellationToken

    public init(
        id: UUID,
        arguments: [String],
        workingDirectory: String,
        stdinData: Data? = nil,
        generation: UUID = UUID()
    ) {
        self.id = id
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.stdinData = stdinData
        self.cancellationToken = ClaudeCancellationToken(id: id, generation: generation)
    }
}

public typealias ClaudeInvoke = @Sendable (ClaudeInvocation) async -> ClaudeResult

#if os(macOS)
enum ClaudeTerminationReason: Equatable, Sendable {
    case cancelled
    case timedOut
}

/// Generation tokens make late cancellation harmless even when a completed UUID is
/// reused. Only active/pending IDs are retained, so registry memory is bounded by
/// concurrent invocations rather than process lifetime.
/// `Process` is macOS-only (ADR-0003), so this registry is compiled only there.
final class ClaudeInvocationRegistry: @unchecked Sendable {
    private struct Entry {
        let token: ClaudeCancellationToken
        var process: Process?
        var termination: ClaudeTerminationReason?
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func begin(_ token: ClaudeCancellationToken) -> Bool {
        lock.withLock {
            guard entries[token.id] == nil else { return false }
            entries[token.id] = Entry(token: token, process: nil, termination: nil)
            return true
        }
    }

    func register(_ process: Process, for token: ClaudeCancellationToken) -> ClaudeTerminationReason? {
        lock.withLock {
            guard var entry = entries[token.id], entry.token == token else { return nil }
            entry.process = process
            entries[token.id] = entry
            return entry.termination
        }
    }

    @discardableResult
    func cancel(_ token: ClaudeCancellationToken) -> Process? {
        lock.withLock {
            guard var entry = entries[token.id], entry.token == token,
                  entry.termination == nil else { return nil }
            if let process = entry.process, !process.isRunning { return nil }
            entry.termination = .cancelled
            entries[token.id] = entry
            return entry.process
        }
    }

    func timeOut(_ token: ClaudeCancellationToken) -> Process? {
        lock.withLock {
            guard var entry = entries[token.id], entry.token == token,
                  entry.termination == nil else { return nil }
            if let process = entry.process, !process.isRunning { return nil }
            entry.termination = .timedOut
            entries[token.id] = entry
            return entry.process
        }
    }

    func finish(_ process: Process, for token: ClaudeCancellationToken) -> ClaudeTerminationReason? {
        lock.withLock {
            guard let entry = entries[token.id], entry.token == token,
                  entry.process === process else { return nil }
            entries.removeValue(forKey: token.id)
            return entry.termination
        }
    }

    func abandon(_ token: ClaudeCancellationToken) {
        lock.withLock {
            guard let entry = entries[token.id], entry.token == token else { return }
            entries.removeValue(forKey: token.id)
        }
    }

    func shouldForceKill(
        _ process: Process,
        token: ClaudeCancellationToken,
        reason: ClaudeTerminationReason
    ) -> Bool {
        lock.withLock {
            guard let entry = entries[token.id], entry.token == token,
                  entry.process === process else { return false }
            return entry.termination == reason
        }
    }
}
#endif

public enum ClaudeRunner {
#if os(macOS)
    /// Wall-clock budget for a single `claude -p` invocation before it's killed and
    /// treated as a failure. Real headless runs can take minutes, so the default is
    /// generous; `ClaudeRunnerTests` dials this down to exercise the timeout path
    /// quickly, which is why this is a settable `static var` rather than a constant.
    private static let timeoutStorage = Locked<TimeInterval>(600)
    public static var timeoutSeconds: TimeInterval {
        get { timeoutStorage.withLock { $0 } }
        set { timeoutStorage.withLock { $0 = newValue } }
    }

    /// Env for the spawned CLI: drop ANTHROPIC_ and CLAUDE vars so a run
    /// started from inside a Claude Code session (which injects a proxy
    /// base URL the child can't authenticate against) still uses the CLI's
    /// own subscription login.
    static func cleanEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("ANTHROPIC_") && !key.hasPrefix("CLAUDE")
        }
    }

    static func binaryPath() -> String {
        if let override = ProcessInfo.processInfo.environment["MUSTARD_CLAUDE_BIN"] {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in ["\(home)/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "claude"
    }

    /// Lock-protected box for state shared by dedicated reader queues and the
    /// process-completion queue.
    private final class Locked<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()
        init(_ value: Value) { self.value = value }
        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private static let invocationRegistry = ClaudeInvocationRegistry()

    static func isRateLimited(_ text: String) -> Bool {
        text.range(
            of: "rate.?limit|usage limit",
            options: [.regularExpression, .caseInsensitive],
            range: nil,
            locale: nil
        ) != nil
    }

    /// Runs a specific Claude CLI invocation against the logged-in subscription.
    /// stdin is /dev/null unless the invocation explicitly supplies task input.
    public static let invoke: ClaudeInvoke = { invocation in
        let token = invocation.cancellationToken
        guard invocationRegistry.begin(token) else {
            return ClaudeResult(
                ok: false,
                text: "Claude invocation ID \(invocation.id.uuidString) is already active.",
                failureSource: .duplicateInvocation
            )
        }
        let timeout = timeoutStorage.withLock { $0 }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath())
                process.arguments = invocation.arguments
                process.currentDirectoryURL = URL(fileURLWithPath: invocation.workingDirectory)
                process.environment = cleanEnvironment()
                let input = invocation.stdinData.map { _ in Pipe() }
                process.standardInput = input ?? FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err

                // Exactly one blocking reader owns each pipe. They start before the
                // process wait and are joined after exit, avoiding handler/final-read races.
                let readGroup = DispatchGroup()
                let stdoutBuffer = Locked(Data())
                let stderrBuffer = Locked(Data())
                readGroup.enter()
                DispatchQueue.global().async {
                    stdoutBuffer.withLock { $0 = out.fileHandleForReading.readDataToEndOfFile() }
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global().async {
                    stderrBuffer.withLock { $0 = err.fileHandleForReading.readDataToEndOfFile() }
                    readGroup.leave()
                }

                do {
                    try process.run()
                } catch {
                    try? out.fileHandleForWriting.close()
                    try? err.fileHandleForWriting.close()
                    readGroup.wait()
                    invocationRegistry.abandon(token)
                    continuation.resume(returning: ClaudeResult(
                        ok: false, text: String(describing: error), failureSource: .launch))
                    return
                }

                if let reason = invocationRegistry.register(process, for: token) {
                    terminate(process, token: token, reason: reason)
                }

                let writeGroup = DispatchGroup()
                if let input, let data = invocation.stdinData {
                    writeGroup.enter()
                    DispatchQueue.global().async {
                        try? input.fileHandleForWriting.write(contentsOf: data)
                        try? input.fileHandleForWriting.close()
                        writeGroup.leave()
                    }
                }
                let timeoutItem = DispatchWorkItem {
                    if let timedOutProcess = invocationRegistry.timeOut(token) {
                        terminate(timedOutProcess, token: token, reason: .timedOut)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                process.waitUntilExit()
                timeoutItem.cancel()
                writeGroup.wait()
                readGroup.wait()

                let stdout = String(data: stdoutBuffer.withLock { $0 }, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBuffer.withLock { $0 }, encoding: .utf8) ?? ""
                let termination = invocationRegistry.finish(process, for: token)

                if termination == .cancelled {
                    continuation.resume(returning: ClaudeResult(
                        ok: false,
                        text: "claude invocation cancelled",
                        failureSource: .cancelled,
                        stderr: stderr,
                        exitStatus: process.terminationStatus
                    ))
                    return
                }
                if termination == .timedOut {
                    continuation.resume(returning: ClaudeResult(
                        ok: false,
                        text: "claude timed out after \(Int(timeout))s",
                        failureSource: .timedOut,
                        stderr: stderr,
                        exitStatus: process.terminationStatus
                    ))
                    return
                }

                if process.terminationStatus != 0 {
                    let text = """
                    claude exited \(process.terminationStatus)
                    stdout:
                    \(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                    stderr:
                    \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                    """
                    continuation.resume(returning: ClaudeResult(
                        ok: false,
                        text: text,
                        rateLimited: isRateLimited(stderr),
                        failureSource: .exitStatus,
                        stderr: stderr,
                        exitStatus: process.terminationStatus
                    ))
                    return
                }

                struct CLIOutput: Decodable {
                    let result: String?
                    let is_error: Bool
                }
                if let data = stdout.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object.keys.contains("result"),
                   object.keys.contains("is_error"),
                   let parsed = try? JSONDecoder().decode(CLIOutput.self, from: data) {
                    if parsed.is_error {
                        let text = parsed.result ?? "claude reported an error"
                        continuation.resume(returning: ClaudeResult(
                            ok: false,
                            text: text,
                            rateLimited: isRateLimited(text),
                            failureSource: .outerError,
                            stderr: stderr,
                            exitStatus: process.terminationStatus
                        ))
                    } else {
                        let structuredText: String? = invocation.arguments.contains("--json-schema")
                            ? object["structured_output"].flatMap { value in
                            guard JSONSerialization.isValidJSONObject(value)
                                    || value is String || value is NSNumber || value is NSNull else {
                                return nil
                            }
                            let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
                            guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else {
                                return nil
                            }
                            return String(data: data, encoding: .utf8)
                        } : nil
                        continuation.resume(returning: ClaudeResult(
                            ok: true, text: structuredText ?? parsed.result ?? ""))
                    }
                } else {
                    continuation.resume(returning: ClaudeResult(
                        ok: true, text: stdout.trimmingCharacters(in: .whitespacesAndNewlines), unparsed: true))
                }
            }
        }
    }

    public static let run: ClaudeRun = { prompt, cwd in
        await invoke(.init(
            id: UUID(),
            arguments: ["-p", prompt, "--output-format", "json"],
            workingDirectory: cwd
        ))
    }

    private static func terminate(
        _ process: Process,
        token: ClaudeCancellationToken,
        reason: ClaudeTerminationReason
    ) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            guard process.isRunning,
                  invocationRegistry.shouldForceKill(process, token: token, reason: reason) else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    public static func cancel(_ token: ClaudeCancellationToken) {
        if let process = invocationRegistry.cancel(token) {
            terminate(process, token: token, reason: .cancelled)
        }
    }
#else
    /// The agent shells out to the `claude` CLI, which runs on the Mac only (ADR-0003).
    /// The iOS companion never executes agent work — it reads/writes shared data. This
    /// stub keeps `ClaudeRunner.run` available so `AgentService` compiles for iOS.
    public static let run: ClaudeRun = { _, _ in
        ClaudeResult(ok: false, text: "The agent runs on the Mac only.")
    }

    public static let invoke: ClaudeInvoke = { _ in
        ClaudeResult(ok: false, text: "The agent runs on the Mac only.")
    }

    public static func cancel(_: ClaudeCancellationToken) {}

    static func isRateLimited(_ text: String) -> Bool {
        text.range(
            of: "rate.?limit|usage limit",
            options: [.regularExpression, .caseInsensitive],
            range: nil,
            locale: nil
        ) != nil
    }
#endif
}
