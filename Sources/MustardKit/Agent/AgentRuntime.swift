import Foundation

public struct AgentRuntimeRequest: Sendable {
    public let sessionID: String
    public let prompt: String
    public let workingDirectory: String

    public init(sessionID: String, prompt: String, workingDirectory: String) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.workingDirectory = workingDirectory
    }
}

public enum AgentRuntimeFailure: Equatable, Sendable {
    case authenticationRequired(String)
    case rateLimited(String)
    case timedOut(String)
    case sessionMissing(String)
    case malformedOutput(String)
    case process(String)
    case cancelled(String)
}

public enum AgentRuntimeHealth: Equatable, Sendable {
    case available
    case authenticationRequired(String)
    case unavailable(String)
}

public struct AgentRuntimeResponse: Equatable, Sendable {
    private enum Storage: Equatable, Sendable {
        case success(AgentTurnResult)
        case failure(AgentRuntimeFailure)
    }

    private let storage: Storage

    public var result: AgentTurnResult? {
        guard case .success(let result) = storage else { return nil }
        return result
    }

    public var failure: AgentRuntimeFailure? {
        guard case .failure(let failure) = storage else { return nil }
        return failure
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    public static func success(_ result: AgentTurnResult) -> Self {
        .init(storage: .success(result))
    }

    public static func failure(_ failure: AgentRuntimeFailure) -> Self {
        .init(storage: .failure(failure))
    }
}

public protocol AgentRuntime: Sendable {
    func start(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse
    func resume(_ request: AgentRuntimeRequest) async -> AgentRuntimeResponse
    func cancel() async
    func health() async -> AgentRuntimeHealth
}
