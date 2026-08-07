import Foundation
import XCTest
@testable import MustardKit

final class ClaudeTaskRuntimeTests: XCTestCase {
    private let sessionID = "11111111-1111-1111-1111-111111111111"
    private let completedJSON = #"{"outcome":"completed","message":"Done","questions":[],"summary":"Done","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}"#

    func test_runtimeResponseFactoriesEnforceExactlyOnePayload() {
        let result = try! AgentTurnContract.decode(completedJSON)
        let success = AgentRuntimeResponse.success(result)
        XCTAssertEqual(success.result, result)
        XCTAssertNil(success.failure)

        let failure = AgentRuntimeResponse.failure(.process("boom"))
        XCTAssertNil(failure.result)
        XCTAssertEqual(failure.failure, .process("boom"))
    }

    func test_start_usesChosenSessionAndSchema_andDecodesCompletedResult() async throws {
        let recorder = InvocationRecorder(result: .init(ok: true, text: completedJSON))
        let runtime = ClaudeTaskRuntime(invoke: recorder.invoke)

        let response = await runtime.start(.init(
            sessionID: sessionID,
            prompt: "do it",
            workingDirectory: "/tmp"
        ))

        XCTAssertEqual(response.result?.outcome, .completed)
        XCTAssertNil(response.failure)
        let invocation = try XCTUnwrap(recorder.invocations.first)
        XCTAssertEqual(invocation.workingDirectory, "/tmp")
        XCTAssertEqual(invocation.arguments, [
            "-p",
            "--session-id", sessionID,
            "--output-format", "json",
            "--json-schema", AgentTurnContract.jsonSchema,
        ])
        XCTAssertEqual(invocation.stdinData, Data("do it".utf8))
    }

    func test_resume_usesResumeFlagAndSameSession() async throws {
        let recorder = InvocationRecorder(result: .init(ok: true, text: completedJSON))
        let runtime = ClaudeTaskRuntime(invoke: recorder.invoke)

        _ = await runtime.resume(.init(
            sessionID: sessionID,
            prompt: "version 2.21",
            workingDirectory: "/tmp"
        ))

        let invocation = try XCTUnwrap(recorder.invocations.first)
        XCTAssertEqual(invocation.arguments, [
            "-p",
            "--resume", sessionID,
            "--output-format", "json",
            "--json-schema", AgentTurnContract.jsonSchema,
        ])
        XCTAssertEqual(invocation.stdinData, Data("version 2.21".utf8))
    }

    func test_start_realRunner_usesStdinForLargePrompt_andDecodesStructuredOutput() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/structured-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let argsFile = dir.appending(path: "args.txt")
        let stdinFile = dir.appending(path: "stdin.txt")
        let stub = dir.appending(path: "fake-claude.sh")
        try """
        #!/bin/zsh
        printf '%s\0' "$@" > '\(argsFile.path)'
        cat > '\(stdinFile.path)'
        echo '{"type":"result","is_error":false,"result":"fallback prose","structured_output":{"outcome":"completed","message":"Structured","questions":[],"summary":"From schema","artifacts":[],"retryDisposition":"none","errorCategory":null,"connectedCapability":null}}'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let previousBinary = ProcessInfo.processInfo.environment["MUSTARD_CLAUDE_BIN"]
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)
        defer {
            if let previousBinary { setenv("MUSTARD_CLAUDE_BIN", previousBinary, 1) }
            else { unsetenv("MUSTARD_CLAUDE_BIN") }
        }
        let prompt = String(repeating: "large prompt 🚀 ", count: 20_000)

        let response = await ClaudeTaskRuntime().start(.init(
            sessionID: sessionID,
            prompt: prompt,
            workingDirectory: "/tmp"
        ))

        XCTAssertEqual(response.result?.outcome, .completed)
        XCTAssertEqual(response.result?.message, "Structured")
        let argsData = try Data(contentsOf: argsFile)
        let args = argsData.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(args, [
            "-p", "--session-id", sessionID, "--output-format", "json",
            "--json-schema", AgentTurnContract.jsonSchema,
        ])
        XCTAssertFalse(args.contains(prompt))
        XCTAssertEqual(try String(contentsOf: stdinFile, encoding: .utf8), prompt)
    }

    func test_authenticationFailures_mapRepresentativeTextCaseInsensitively() async {
        for text in ["HTTP 401", "You are NOT LOGGED IN", "Authentication required"] {
            let runtime = runtime(returning: .init(
                ok: false, text: text, failureSource: .outerError
            ))
            let response = await runtime.start(request())
            XCTAssertEqual(response.failure, .authenticationRequired(text))
        }
    }

    func test_rateLimitFailure_usesRunnerClassification() async {
        let text = "usage limit reached"
        let runtime = runtime(returning: .init(
            ok: false, text: text, rateLimited: true, failureSource: .outerError
        ))

        let response = await runtime.start(request())

        XCTAssertEqual(response.failure, .rateLimited(text))
    }

    func test_sessionMissingFailures_mapRepresentativeTextCaseInsensitively() async {
        for text in ["No conversation found", "SESSION NOT FOUND", "unknown session"] {
            let runtime = runtime(returning: .init(
                ok: false, text: text, failureSource: .outerError
            ))
            let response = await runtime.resume(request())
            XCTAssertEqual(response.failure, .sessionMissing(text))
        }
    }

    func test_errorPrecedence_prefersAuthenticationThenRateLimitThenSessionMissing() async {
        let authAndSession = "401: no conversation found"
        let authResponse = await runtime(returning: .init(
            ok: false, text: authAndSession, rateLimited: true, failureSource: .outerError
        )).resume(request())
        XCTAssertEqual(authResponse.failure, .authenticationRequired(authAndSession))

        let rateAndSession = "rate limit: unknown session"
        let rateResponse = await runtime(returning: .init(
            ok: false, text: rateAndSession, rateLimited: true, failureSource: .outerError
        )).resume(request())
        XCTAssertEqual(rateResponse.failure, .rateLimited(rateAndSession))
    }

    func test_timeout_mapsTimedOut() async {
        let text = "claude timed out after 1s"
        let response = await runtime(returning: .init(
            ok: false, text: text, failureSource: .timedOut
        )).start(request())
        XCTAssertEqual(response.failure, .timedOut(text))
    }

    func test_intentionalCancellation_mapsCancelled() async {
        let text = "claude invocation cancelled"
        let response = await runtime(returning: .init(
            ok: false, text: text, failureSource: .cancelled
        )).start(request())
        XCTAssertEqual(response.failure, .cancelled(text))
    }

    func test_cancel_realRunner_mapsIntentionalCancellationEndToEnd() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/runtime-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appending(path: "pid.txt")
        let stub = dir.appending(path: "fake-claude.sh")
        try """
        #!/bin/zsh
        echo $$ > '\(pidFile.path)'
        while true; do :; done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let previousBinary = ProcessInfo.processInfo.environment["MUSTARD_CLAUDE_BIN"]
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)
        defer {
            if let previousBinary { setenv("MUSTARD_CLAUDE_BIN", previousBinary, 1) }
            else { unsetenv("MUSTARD_CLAUDE_BIN") }
        }
        let runtime = ClaudeTaskRuntime()
        let run = Task { await runtime.start(self.request()) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))

        await runtime.cancel()
        let response = await run.value

        XCTAssertEqual(response.failure, .cancelled("claude invocation cancelled"))
    }

    func test_unparsedOuterOutput_mapsMalformedOutput() async {
        let text = "plain prose"
        let response = await runtime(returning: .init(
            ok: true, text: text, unparsed: true
        )).start(request())
        XCTAssertEqual(response.failure, .malformedOutput(text))
    }

    func test_malformedInnerContract_mapsMalformedOutput() async {
        let text = #"{"outcome":"completed"}"#
        let response = await runtime(returning: .init(ok: true, text: text)).start(request())
        XCTAssertEqual(response.failure, .malformedOutput(text))
    }

    func test_genericCLIFailure_mapsProcess() async {
        let text = "claude exited 7"
        let response = await runtime(returning: .init(ok: false, text: text)).start(request())
        XCTAssertEqual(response.failure, .process(text))
    }

    func test_taskOutputErrorPhrases_doNotTriggerGlobalFailureClassification() async {
        for text in [
            "Task notes mention 401 authentication",
            "User asked about a rate limit",
            "Document says unknown session and session not found",
        ] {
            let response = await runtime(returning: .init(
                ok: false,
                text: text,
                failureSource: .exitStatus,
                stderr: "worker exited unexpectedly",
                exitStatus: 1
            )).start(request())
            XCTAssertEqual(response.failure, .process(text), text)
        }
    }

    func test_suspectedAuthentication_requiresHealthConfirmation() async {
        let taskText = "HTTP 401 authentication required"
        let script = InvocationScript(results: [
            .init(ok: false, text: taskText, failureSource: .outerError),
            .init(ok: true, text: #"{"loggedIn":true}"#, unparsed: true),
        ])
        let runtime = ClaudeTaskRuntime(invoke: script.invoke)

        let response = await runtime.start(request())

        XCTAssertEqual(response.failure, .process(taskText))
        XCTAssertEqual(script.invocations.count, 2)
        XCTAssertEqual(script.invocations.last?.arguments, ["auth", "status", "--json"])
    }

    func test_suspectedAuthentication_withLoggedOutHealth_isAuthenticationRequired() async {
        let taskText = "authentication required"
        let script = InvocationScript(results: [
            .init(ok: false, text: taskText, failureSource: .outerError),
            .init(
                ok: false,
                text: "claude exited 1",
                failureSource: .exitStatus,
                stderr: "not logged in",
                exitStatus: 1
            ),
        ])
        let runtime = ClaudeTaskRuntime(invoke: script.invoke)

        let response = await runtime.start(request())

        XCTAssertEqual(response.failure, .authenticationRequired(taskText))
        XCTAssertEqual(script.invocations.count, 2)
    }

    func test_health_invokesAuthStatusWithFreshID_andMapsAvailable() async throws {
        let recorder = InvocationRecorder(result: .init(ok: true, text: #"{"loggedIn":true}"#))
        let runtime = ClaudeTaskRuntime(invoke: recorder.invoke)

        let health = await runtime.health()
        XCTAssertEqual(health, .available)

        let invocation = try XCTUnwrap(recorder.invocations.first)
        XCTAssertEqual(invocation.arguments, ["auth", "status", "--json"])
        XCTAssertEqual(
            invocation.workingDirectory,
            FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    func test_health_mapsAuthenticationAndUnavailable() async {
        let authText = "not logged in"
        let authHealth = await runtime(
            returning: .init(ok: false, text: authText, failureSource: .outerError)
        ).health()
        XCTAssertEqual(authHealth, .authenticationRequired(authText))

        let unavailableText = "binary failed"
        let unavailableHealth = await runtime(
            returning: .init(ok: false, text: unavailableText)
        ).health()
        XCTAssertEqual(unavailableHealth, .unavailable(unavailableText))
    }

    func test_health_loggedOutJSONFieldsEachMapAuthenticationRequired() async {
        for text in [#"{"loggedIn":false}"#, #"{"authMethod":"none"}"#] {
            let health = await runtime(
                returning: .init(ok: true, text: text, unparsed: true)
            ).health()
            XCTAssertEqual(health, .authenticationRequired(text))
        }
    }

    func test_health_realRunner_exitOneLoggedOutJSON_mapsAuthenticationRequired() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-logged-out-\(UUID().uuidString).sh")
        try FileManager.default.createDirectory(
            at: stub.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/zsh
        echo '{"loggedIn":false,"authMethod":"none"}'
        exit 1
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let previousBinary = ProcessInfo.processInfo.environment["MUSTARD_CLAUDE_BIN"]
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)
        defer {
            if let previousBinary {
                setenv("MUSTARD_CLAUDE_BIN", previousBinary, 1)
            } else {
                unsetenv("MUSTARD_CLAUDE_BIN")
            }
        }

        let health = await ClaudeTaskRuntime().health()

        guard case .authenticationRequired(let text) = health else {
            return XCTFail("expected logged-out auth JSON to require authentication, got \(health)")
        }
        XCTAssertTrue(text.contains(#""loggedIn":false"#))
        XCTAssertTrue(text.contains(#""authMethod":"none""#))
    }

    func test_health_realRunner_exitOneUnrelatedJSON_mapsUnavailable() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appending(path: "mustard-tests/fake-claude-unavailable-\(UUID().uuidString).sh")
        try FileManager.default.createDirectory(
            at: stub.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/zsh
        echo '{"unexpected":true}'
        exit 1
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let previousBinary = ProcessInfo.processInfo.environment["MUSTARD_CLAUDE_BIN"]
        setenv("MUSTARD_CLAUDE_BIN", stub.path, 1)
        defer {
            if let previousBinary {
                setenv("MUSTARD_CLAUDE_BIN", previousBinary, 1)
            } else {
                unsetenv("MUSTARD_CLAUDE_BIN")
            }
        }

        let health = await ClaudeTaskRuntime().health()

        guard case .unavailable(let text) = health else {
            return XCTFail("expected unrelated nonzero JSON to be unavailable, got \(health)")
        }
        XCTAssertTrue(text.contains(#""unexpected":true"#))
    }

    func test_cancelTargetsOnlyCurrentInvocation_andCompletionClearsIt() async throws {
        let controlled = ControlledInvoke()
        let cancelled = LockedValues<ClaudeCancellationToken>()
        let runtime = ClaudeTaskRuntime(
            invoke: controlled.invoke,
            cancelInvocation: { cancelled.append($0) }
        )
        let run = Task { await runtime.start(self.request()) }
        let invocation = try await controlled.waitForInvocation()

        await runtime.cancel()
        XCTAssertEqual(cancelled.values, [invocation.cancellationToken])

        controlled.complete(invocation.id, with: .init(ok: true, text: completedJSON))
        _ = await run.value
        await runtime.cancel()
        XCTAssertEqual(cancelled.values, [invocation.cancellationToken], "late cancel must not target completed work")
    }

    func test_overlappingTurnIsRejected_withoutReplacingCurrentInvocation() async throws {
        let controlled = ControlledInvoke()
        let cancelled = LockedValues<ClaudeCancellationToken>()
        let runtime = ClaudeTaskRuntime(
            invoke: controlled.invoke,
            cancelInvocation: { cancelled.append($0) }
        )
        let first = Task { await runtime.start(self.request(prompt: "first")) }
        let firstInvocation = try await controlled.waitForInvocation()

        let second = await runtime.start(request(prompt: "second"))
        XCTAssertEqual(second.failure, .process("Claude runtime already has an active invocation."))
        XCTAssertEqual(controlled.invocations.count, 1)

        await runtime.cancel()
        XCTAssertEqual(cancelled.values, [firstInvocation.cancellationToken])
        controlled.complete(firstInvocation.id, with: .init(ok: true, text: completedJSON))
        _ = await first.value
    }

    func test_cancelDoesNotTargetHealthInvocation() async throws {
        let controlled = ControlledInvoke()
        let cancelled = LockedValues<ClaudeCancellationToken>()
        let runtime = ClaudeTaskRuntime(
            invoke: controlled.invoke,
            cancelInvocation: { cancelled.append($0) }
        )
        let health = Task { await runtime.health() }
        let invocation = try await controlled.waitForInvocation()
        XCTAssertEqual(invocation.arguments, ["auth", "status", "--json"])

        await runtime.cancel()
        XCTAssertTrue(cancelled.values.isEmpty)
        controlled.complete(invocation.id, with: .init(ok: true, text: "{}"))
        let healthResult = await health.value
        XCTAssertEqual(healthResult, .available)
    }

    private func request(prompt: String = "do it") -> AgentRuntimeRequest {
        .init(sessionID: sessionID, prompt: prompt, workingDirectory: "/tmp")
    }

    private func runtime(returning result: ClaudeResult) -> ClaudeTaskRuntime {
        ClaudeTaskRuntime(invoke: { _ in result })
    }
}

private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedInvocations: [ClaudeInvocation] = []
    private let result: ClaudeResult

    init(result: ClaudeResult) {
        self.result = result
    }

    var invocations: [ClaudeInvocation] {
        lock.withLock { storedInvocations }
    }

    lazy var invoke: ClaudeInvoke = { [weak self] invocation in
        guard let self else { return ClaudeResult(ok: false, text: "recorder released") }
        self.lock.withLock { self.storedInvocations.append(invocation) }
        return self.result
    }
}

private final class InvocationScript: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ClaudeResult]
    private var storedInvocations: [ClaudeInvocation] = []

    init(results: [ClaudeResult]) {
        self.results = results
    }

    var invocations: [ClaudeInvocation] { lock.withLock { storedInvocations } }

    lazy var invoke: ClaudeInvoke = { [weak self] invocation in
        guard let self else { return ClaudeResult(ok: false, text: "script released") }
        return self.lock.withLock {
            self.storedInvocations.append(invocation)
            guard !self.results.isEmpty else {
                return ClaudeResult(ok: false, text: "script exhausted")
            }
            return self.results.removeFirst()
        }
    }
}

private final class ControlledInvoke: @unchecked Sendable {
    private let lock = NSLock()
    private var storedInvocations: [ClaudeInvocation] = []
    private var continuations: [UUID: CheckedContinuation<ClaudeResult, Never>] = [:]

    var invocations: [ClaudeInvocation] {
        lock.withLock { storedInvocations }
    }

    lazy var invoke: ClaudeInvoke = { [weak self] invocation in
        guard let self else { return ClaudeResult(ok: false, text: "controller released") }
        return await withCheckedContinuation { continuation in
            self.lock.withLock {
                self.storedInvocations.append(invocation)
                self.continuations[invocation.id] = continuation
            }
        }
    }

    func waitForInvocation() async throws -> ClaudeInvocation {
        for _ in 0..<200 {
            if let invocation = invocations.first { return invocation }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "ClaudeTaskRuntimeTests", code: 1)
    }

    func complete(_ id: UUID, with result: ClaudeResult) {
        let continuation = lock.withLock { continuations.removeValue(forKey: id) }
        continuation?.resume(returning: result)
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}
