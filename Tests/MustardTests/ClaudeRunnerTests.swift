import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import MustardKit

/// Exercises the real Process-spawn path against a stub binary
/// (MUSTARD_CLAUDE_BIN), covering env-scrub, closed stdin, JSON parsing.
final class ClaudeRunnerTests: XCTestCase {
    private var stubPath: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mustard-tests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stub = dir.appending(path: "fake-claude.sh")
        let script = """
        #!/bin/zsh
        echo '{"type":"result","is_error":false,"result":"stub says hi"}'
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        stubPath = stub.path
        setenv("MUSTARD_CLAUDE_BIN", stubPath, 1)
    }

    override func tearDown() {
        unsetenv("MUSTARD_CLAUDE_BIN")
    }

    func test_run_spawnsBinaryAndParsesResultJSON() async {
        let result = await ClaudeRunner.run("any prompt", "/tmp")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.text, "stub says hi")
    }

    func test_run_errorJSONIsFailure() async throws {
        let errStub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-err.sh")
        try """
        #!/bin/zsh
        echo '{"is_error":true,"result":"usage limit reached"}'
        """.write(to: errStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: errStub.path)
        setenv("MUSTARD_CLAUDE_BIN", errStub.path, 1)

        let result = await ClaudeRunner.run("any", "/tmp")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.rateLimited)
    }

    func test_cleanEnvironment_stripsSessionVars() {
        setenv("ANTHROPIC_BASE_URL", "http://proxy", 1)
        setenv("CLAUDECODE", "1", 1)
        defer { unsetenv("ANTHROPIC_BASE_URL"); unsetenv("CLAUDECODE") }
        let env = ClaudeRunner.cleanEnvironment()
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNotNil(env["PATH"])
    }

    // MARK: - zero-exit non-JSON stdout is flagged, not silently accepted

    func test_run_zeroExitNonJSONStdout_isFlaggedUnparsed() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-prose.sh")
        try """
        #!/bin/zsh
        echo 'I looked around but found nothing worth flagging.'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let result = await ClaudeRunner.run("any", "/tmp")
        XCTAssertTrue(result.ok, "a zero-exit run is still a success even if unparsed")
        XCTAssertTrue(result.unparsed, "fallback raw-stdout path must be flagged as unparsed")
    }

    func test_run_wellFormedJSONResult_isNotFlaggedUnparsed() async {
        // fake-claude.sh (setUp) emits the expected {result,is_error} shape.
        let result = await ClaudeRunner.run("any prompt", "/tmp")
        XCTAssertFalse(result.unparsed)
    }

    func test_invoke_structuredOutputTakesPrecedence_andIsSerializedDeterministically() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-structured-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        echo '{"type":"result","is_error":false,"result":"fallback","structured_output":{"z":2,"a":1}}'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let result = await ClaudeRunner.invoke(.init(
            id: UUID(),
            arguments: ["-p", "--output-format", "json", "--json-schema", "{}"],
            workingDirectory: "/tmp"
        ))

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.text, #"{"a":1,"z":2}"#)
    }

    func test_run_ordinarySweepRetainsResultWhenEnvelopeAlsoContainsStructuredOutput() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-sweep-structured-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        echo '{"type":"result","is_error":false,"result":"sweep result","structured_output":{"task":"only"}}'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let result = await ClaudeRunner.run("sweep", "/tmp")

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.text, "sweep result")
    }

    func test_run_zeroExitArbitraryJSON_isFlaggedUnparsed() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-auth-json-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        echo '{"loggedIn":true,"authMethod":"oauth"}'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let result = await ClaudeRunner.run("any", "/tmp")

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.unparsed, "arbitrary JSON is not a Claude prompt-result envelope")
        XCTAssertTrue(result.text.contains(#""loggedIn":true"#))
    }

    func test_run_nonzeroArbitraryJSON_isFailure_andPreservesStdoutAndStderr() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-auth-failure-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        echo '{"loggedIn":false,"authMethod":"none"}'
        echo 'auth status failed' 1>&2
        exit 1
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let result = await ClaudeRunner.run("any", "/tmp")

        XCTAssertFalse(result.ok, "a nonzero process exit can never be a successful run")
        XCTAssertTrue(result.text.contains(#""loggedIn":false"#))
        XCTAssertTrue(result.text.contains("auth status failed"))
    }

    func test_run_nonzeroPromptResultEnvelope_isFailure() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-result-failure-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        echo '{"type":"result","is_error":false,"result":"must not succeed"}'
        exit 9
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let result = await ClaudeRunner.run("any", "/tmp")

        XCTAssertFalse(result.ok, "outer result JSON cannot override a nonzero process exit")
        XCTAssertTrue(result.text.contains("must not succeed"))
    }

    // MARK: - concurrent pipe drain (large stderr must not deadlock stdout)

    func test_run_largeStderrDoesNotDeadlockStdoutDrain() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-noisy.sh")
        // >64KB of stderr before the stdout JSON — the old sequential
        // read-stdout-then-stderr implementation deadlocks on this.
        try """
        #!/bin/zsh
        for i in {1..4000}; do
          echo "noisy stderr line $i padded padded padded padded padded padded" 1>&2
        done
        echo '{"is_error":false,"result":"stub says hi after noise"}'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let result = await ClaudeRunner.run("any", "/tmp")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.text, "stub says hi after noise")
    }

    // MARK: - final drain after exit (no truncated tail write)

    func test_run_largeStdoutWrittenJustBeforeExit_isNotTruncated() async throws {
        // waitUntilExit doesn't guarantee the readability handlers consumed the
        // child's final write; without a post-exit drain the tail chunk is lost and
        // a successful run is misreported as unparsed with partial text. A large
        // payload flushed immediately before exit maximizes the chance a chunk is
        // still in the pipe when waitUntilExit returns; repeat to widen the window.
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-big.sh")
        // ~1MB result payload emitted right before exit.
        try """
        #!/bin/zsh
        payload=$(printf 'x%.0s' {1..1048576})
        echo "{\\"is_error\\":false,\\"result\\":\\"$payload\\"}"
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        for attempt in 1...5 {
            let result = await ClaudeRunner.run("any", "/tmp")
            XCTAssertTrue(result.ok, "attempt \(attempt): run should succeed")
            XCTAssertFalse(result.unparsed,
                           "attempt \(attempt): truncated stdout breaks the JSON decode and misreports the run as unparsed")
            XCTAssertEqual(result.text.count, 1_048_576, "attempt \(attempt): payload must arrive complete")
        }
    }

    // MARK: - timeout

    func test_run_timesOut_returnsTimeoutError_andKillsTheProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mustard-tests")
        let pidFile = dir.appending(path: "hung-pid-\(UUID().uuidString).txt")
        let stub = dir.appending(path: "fake-claude-hung.sh")
        // A busy-loop (not `sleep`, which forks a grandchild) so the pid we
        // capture is the one the timeout must actually terminate.
        try """
        #!/bin/zsh
        echo $$ > \(pidFile.path)
        while true; do :; done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let originalTimeout = ClaudeRunner.timeoutSeconds
        ClaudeRunner.timeoutSeconds = 1
        defer { ClaudeRunner.timeoutSeconds = originalTimeout }

        let run = Task { await ClaudeRunner.run("any", "/tmp") }
        _ = try await waitForPID(in: pidFile)
        ClaudeRunner.timeoutSeconds = 99
        let result = await run.value
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.text.contains("timed out after 1s"),
                      "timeout value and message must use the same invocation snapshot: \(result.text)")
        XCTAssertEqual(result.failureSource, .timedOut)

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = pid_t(pidText) ?? 0
        XCTAssertGreaterThan(pid, 0)
        XCTAssertNotEqual(kill(pid, 0), 0, "the hung process must be dead once run() returns")
    }

    // MARK: - targeted cancellation

    func test_cancel_terminatesOnlyTheInvocationWithTheMatchingID() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mustard-tests")
        let firstPIDFile = dir.appending(path: "first-pid-\(UUID().uuidString).txt")
        let secondPIDFile = dir.appending(path: "second-pid-\(UUID().uuidString).txt")
        let stub = dir.appending(path: "fake-claude-cancellable-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        echo $$ > "$1"
        while true; do :; done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let firstInvocation = ClaudeInvocation(
            id: UUID(), arguments: [firstPIDFile.path], workingDirectory: "/tmp")
        let secondInvocation = ClaudeInvocation(
            id: UUID(), arguments: [secondPIDFile.path], workingDirectory: "/tmp")
        defer {
            ClaudeRunner.cancel(firstInvocation.cancellationToken)
            ClaudeRunner.cancel(secondInvocation.cancellationToken)
        }
        let first = Task { await ClaudeRunner.invoke(firstInvocation) }
        let second = Task { await ClaudeRunner.invoke(secondInvocation) }

        let firstPID = try await waitForPID(in: firstPIDFile)
        let secondPID = try await waitForPID(in: secondPIDFile)
        ClaudeRunner.cancel(firstInvocation.cancellationToken)

        let firstResult = await first.value
        XCTAssertFalse(firstResult.ok)
        XCTAssertEqual(firstResult.failureSource, .cancelled)
        XCTAssertNotEqual(kill(firstPID, 0), 0)
        XCTAssertEqual(kill(secondPID, 0), 0, "cancelling one invocation must leave the other running")

        ClaudeRunner.cancel(secondInvocation.cancellationToken)
        let secondResult = await second.value
        XCTAssertEqual(secondResult.failureSource, .cancelled)
        XCTAssertNotEqual(kill(secondPID, 0), 0)
    }

    func test_registry_cancelBeforeRegister_recordsIntent() {
        let registry = ClaudeInvocationRegistry()
        let invocation = ClaudeInvocation(id: UUID(), arguments: [], workingDirectory: "/tmp")

        XCTAssertTrue(registry.begin(invocation.cancellationToken))
        XCTAssertNil(registry.cancel(invocation.cancellationToken))

        let process = Process()
        XCTAssertEqual(registry.register(process, for: invocation.cancellationToken), .cancelled)
        XCTAssertEqual(registry.finish(process, for: invocation.cancellationToken), .cancelled)
    }

    func test_invoke_duplicateActiveID_returnsClearFailureWithoutReplacingFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mustard-tests")
        let pidFile = dir.appending(path: "duplicate-pid-\(UUID().uuidString).txt")
        let stub = dir.appending(path: "fake-claude-duplicate-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        echo $$ > '\(pidFile.path)'
        while true; do :; done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)
        let id = UUID()
        let firstInvocation = ClaudeInvocation(id: id, arguments: [], workingDirectory: "/tmp")
        let duplicate = ClaudeInvocation(id: id, arguments: [], workingDirectory: "/tmp")
        let first = Task { await ClaudeRunner.invoke(firstInvocation) }
        _ = try await waitForPID(in: pidFile)

        let duplicateResult = await ClaudeRunner.invoke(duplicate)

        XCTAssertFalse(duplicateResult.ok)
        XCTAssertEqual(duplicateResult.failureSource, .duplicateInvocation)
        XCTAssertTrue(duplicateResult.text.contains(id.uuidString))
        ClaudeRunner.cancel(firstInvocation.cancellationToken)
        let firstResult = await first.value
        XCTAssertEqual(firstResult.failureSource, .cancelled)
    }

    func test_launchFailureReleasesIDForLaterGeneration() async throws {
        let id = UUID()
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/missing-\(UUID().uuidString)")
        setenv("MUSTARD_CLAUDE_BIN", missing.path, 1)
        let failed = await ClaudeRunner.invoke(.init(id: id, arguments: [], workingDirectory: "/tmp"))
        XCTAssertEqual(failed.failureSource, .launch)

        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-after-launch-failure-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        echo '{"is_error":false,"result":"recovered"}'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)

        let recovered = await ClaudeRunner.invoke(.init(id: id, arguments: [], workingDirectory: "/tmp"))

        XCTAssertTrue(recovered.ok)
        XCTAssertEqual(recovered.text, "recovered")
    }

    func test_lateCancelOldGeneration_doesNotKillReusedCompletedID() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mustard-tests")
        let modeFile = dir.appending(path: "reuse-mode-\(UUID().uuidString).txt")
        let pidFile = dir.appending(path: "reuse-pid-\(UUID().uuidString).txt")
        let stub = dir.appending(path: "fake-claude-reuse-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        if [[ -f '\(modeFile.path)' ]]; then
          echo $$ > '\(pidFile.path)'
          while true; do :; done
        fi
        touch '\(modeFile.path)'
        echo '{"is_error":false,"result":"first done"}'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)
        let id = UUID()
        let first = ClaudeInvocation(id: id, arguments: [], workingDirectory: "/tmp")
        let firstResult = await ClaudeRunner.invoke(first)
        XCTAssertTrue(firstResult.ok)
        ClaudeRunner.cancel(first.cancellationToken)

        let reused = ClaudeInvocation(id: id, arguments: [], workingDirectory: "/tmp")
        let run = Task { await ClaudeRunner.invoke(reused) }
        let pid = try await waitForPID(in: pidFile)
        ClaudeRunner.cancel(first.cancellationToken)
        XCTAssertEqual(kill(pid, 0), 0, "late cancel for an old generation must be ignored")

        ClaudeRunner.cancel(reused.cancellationToken)
        let reusedResult = await run.value
        XCTAssertEqual(reusedResult.failureSource, .cancelled)
    }

    func test_cancel_trappingSIGTERM_usesBoundedSIGKILLFallback_andStaysCancelled() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mustard-tests")
        let pidFile = dir.appending(path: "trapping-pid-\(UUID().uuidString).txt")
        let stub = dir.appending(path: "fake-claude-trapping-\(UUID().uuidString).sh")
        try """
        #!/bin/zsh
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        while true; do :; done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)
        let invocation = ClaudeInvocation(id: UUID(), arguments: [], workingDirectory: "/tmp")
        let originalTimeout = ClaudeRunner.timeoutSeconds
        ClaudeRunner.timeoutSeconds = 2
        defer { ClaudeRunner.timeoutSeconds = originalTimeout }
        let run = Task { await ClaudeRunner.invoke(invocation) }
        let pid = try await waitForPID(in: pidFile)

        ClaudeRunner.cancel(invocation.cancellationToken)
        let result = await run.value

        XCTAssertEqual(result.failureSource, .cancelled)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    private func waitForPID(in file: URL) async throws -> pid_t {
        for _ in 0..<200 {
            if let text = try? String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = pid_t(text), pid > 0 {
                return pid
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "ClaudeRunnerTests", code: 1)
    }
}
