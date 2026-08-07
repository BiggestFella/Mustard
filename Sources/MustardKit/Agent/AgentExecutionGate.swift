import Foundation
import Observation

/// Serializes access to the single local Claude subscription across every agent
/// entry point. Tokens make release ownership explicit: a stale caller can never
/// clear a newer caller's lease.
@MainActor
@Observable
public final class AgentExecutionGate {
    public struct Token {
        fileprivate let id: UUID
    }

    public private(set) var owner: String?
    private var tokenID: UUID?

    public init() {}

    public func tryAcquire(owner: String) -> Token? {
        guard tokenID == nil else { return nil }
        let id = UUID()
        tokenID = id
        self.owner = owner
        return Token(id: id)
    }

    public func release(_ token: Token) {
        guard tokenID == token.id else { return }
        tokenID = nil
        owner = nil
    }
}
