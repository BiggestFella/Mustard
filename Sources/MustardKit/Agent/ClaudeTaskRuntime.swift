import Foundation

public actor ClaudeTaskRuntime: AgentRuntime {
    public typealias CancelInvocation = @Sendable (ClaudeCancellationToken) -> Void

    private static let activeInvocationMessage = "Claude runtime already has an active invocation."

    private let invoke: ClaudeInvoke
    private let cancelInvocation: CancelInvocation
    private var currentInvocationToken: ClaudeCancellationToken?

    public init(
        invoke: @escaping ClaudeInvoke = ClaudeRunner.invoke,
        cancelInvocation: @escaping CancelInvocation = { ClaudeRunner.cancel($0) }
    ) {
        self.invoke = invoke
        self.cancelInvocation = cancelInvocation
    }

    public func start(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse {
        await run(request, sessionArgument: "--session-id")
    }

    public func resume(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse {
        await run(request, sessionArgument: "--resume")
    }

    public func cancel() async {
        guard let currentInvocationToken else { return }
        cancelInvocation(currentInvocationToken)
    }

    /// Health checks are independent probes and are intentionally not affected by
    /// `cancel()`, which targets only the active task turn.
    public func health() async -> AgentRuntimeHealth {
        let result = await invoke(.init(
            id: UUID(),
            arguments: ["auth", "status", "--json"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ))
        if Self.isLoggedOutAuthStatus(result.text) {
            return .authenticationRequired(result.text)
        }
        if result.ok { return .available }
        if let trustedText = Self.trustedFailureText(result),
           Self.isAuthenticationFailure(trustedText) {
            return .authenticationRequired(trustedText)
        }
        return .unavailable(result.text)
    }

    /// Task turns are single-flight. The coordinator normally guarantees this; the
    /// adapter also rejects overlap so actor reentrancy cannot replace the ID that
    /// `cancel()` must target.
    private func run(
        _ request: AgentRuntimeRequest,
        sessionArgument: String
    ) async -> AgentRuntimeResponse {
        guard currentInvocationToken == nil else {
            return .failure(.process(Self.activeInvocationMessage))
        }

        let invocation = ClaudeInvocation(
            id: UUID(),
            arguments: [
                "-p",
                sessionArgument, request.sessionID,
                "--output-format", "json",
                "--json-schema", AgentTurnContract.jsonSchema,
            ],
            workingDirectory: request.workingDirectory,
            stdinData: Data(request.prompt.utf8)
        )
        currentInvocationToken = invocation.cancellationToken
        let result = await invoke(invocation)
        let response = await response(from: result)
        if currentInvocationToken == invocation.cancellationToken {
            currentInvocationToken = nil
        }
        return response
    }

    private func response(from result: ClaudeResult) async -> AgentRuntimeResponse {
        if result.unparsed {
            return .failure(.malformedOutput(result.text))
        }
        if !result.ok {
            return .failure(await classifyFailure(result))
        }
        do {
            return .success(try AgentTurnContract.decode(result.text))
        } catch {
            return .failure(.malformedOutput(result.text))
        }
    }

    /// Authentication and rate limits describe provider-wide failures, so they take
    /// precedence over session text that may be a secondary symptom.
    private func classifyFailure(_ result: ClaudeResult) async -> AgentRuntimeFailure {
        let text = result.text
        if result.failureSource == .cancelled { return .cancelled(text) }
        if result.failureSource == .timedOut { return .timedOut(text) }
        guard let trustedText = Self.trustedFailureText(result) else { return .process(text) }
        if Self.isAuthenticationFailure(trustedText) {
            if case .authenticationRequired = await health() {
                return .authenticationRequired(text)
            }
            return .process(text)
        }
        if result.rateLimited || ClaudeRunner.isRateLimited(trustedText) { return .rateLimited(text) }
        if Self.isSessionMissing(trustedText) { return .sessionMissing(text) }
        return .process(text)
    }

    private static func trustedFailureText(_ result: ClaudeResult) -> String? {
        switch result.failureSource {
        case .outerError:
            return result.text
        case .exitStatus:
            return result.stderr
        default:
            return nil
        }
    }

    private static func isAuthenticationFailure(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("401")
            || text.localizedCaseInsensitiveContains("not logged in")
            || text.localizedCaseInsensitiveContains("authentication")
    }

    private static func isLoggedOutAuthStatus(_ text: String) -> Bool {
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        return text.range(of: #""loggedIn"\s*:\s*false"#, options: options) != nil
            || text.range(of: #""authMethod"\s*:\s*"none""#, options: options) != nil
    }

    private static func isSessionMissing(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("no conversation found")
            || text.localizedCaseInsensitiveContains("session not found")
            || text.localizedCaseInsensitiveContains("unknown session")
    }
}
