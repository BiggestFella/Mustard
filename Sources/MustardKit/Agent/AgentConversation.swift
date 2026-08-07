import Foundation
import SwiftData

/// Shared append rule for a task's durable conversation so the coordinator (live Claude
/// turns) and `AgentService` (connected-bridge result normalization) allocate message
/// sequence numbers and bump `lastActivityAt` identically — one source of truth for
/// ordering, no duplicated persistence code.
enum AgentConversation {
    @discardableResult
    static func append(
        to run: AgentRun,
        role: AgentMessageRole,
        kind: AgentMessageKind,
        content: String,
        links: [TaskLink] = [],
        now: Date,
        in context: ModelContext
    ) -> AgentMessage {
        let sequence = (run.messages?.map(\.sequence).max() ?? -1) + 1
        let message = AgentMessage(
            run: run,
            sequence: sequence,
            role: role,
            kind: kind,
            content: content,
            links: links
        )
        message.createdAt = now
        context.insert(message)
        run.lastActivityAt = now
        return message
    }

    /// Record draft references on the run. Keyed by `relativePath`: a retried or
    /// resumed turn that re-returns a file the run already references updates that
    /// draft's title/kind in place rather than duplicating the card. Returns only
    /// the NEWLY created records — the coordinator's save-failure rollback deletes
    /// exactly those (an in-place title touch is not worth a snapshot).
    @discardableResult
    static func materializeDrafts(
        _ payloads: [AgentDraftPayload],
        into run: AgentRun,
        in context: ModelContext
    ) -> [AgentDraft] {
        var created: [AgentDraft] = []
        for payload in payloads where AgentDrafts.isSafeRelativePath(payload.path) {
            if let existing = (run.drafts ?? []).first(where: { $0.relativePath == payload.path }) {
                existing.kind = AgentDraftKind(rawValue: payload.kind) ?? .other
                if !payload.title.isEmpty { existing.title = payload.title }
                continue
            }
            let draft = AgentDraft(
                run: run,
                kind: AgentDraftKind(rawValue: payload.kind) ?? .other,
                title: payload.title.isEmpty ? payload.path : payload.title,
                relativePath: payload.path
            )
            context.insert(draft)
            created.append(draft)
        }
        return created
    }
}
