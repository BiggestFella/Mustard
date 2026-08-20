import Foundation

/// Prompt + parser for the vault-source triage sweep.
public enum VaultSweep {
    public static let prompt = """
    You are reviewing a personal Obsidian knowledge base to recommend actionable tasks.
    Look at the notes in this directory: recent changes, stale items, open loops, gaps.
    Ignore these app-internal folders entirely — never read or propose from them:
    `_filed/` (your own filed log), `_recs/` (the email scout's drop folder), `.obsidian/`.
    Recommend up to 5 concrete, actionable tasks that would move this knowledge base's
    owner forward.

    For each, include:
    - action_type: one of vault_note, create_task, draft_email, draft_slack, ticket_write, fyi, ignore
    - confidence: 0.0–1.0, how sure you are this is worth doing
    - reasoning: one sentence on why you propose it
    - draft: the proposed content (the note text, the email body, etc.) — what you'd actually produce

    Rules:
    - Channel: pick draft_slack ONLY for the internal CodeHeroes team; external partners (TMR,
      CDSB, Thales, clients) get draft_email, never Slack; if the right channel is unclear, use
      create_task (a reminder to chase) instead of guessing.
    - Multi-item actions: if one task covers several items (e.g. raising stories for several
      defects/Jiras), make the draft a scannable list — one line per item with its id + a short
      summary — not a paragraph.
    - Blocked on others: if an item is waiting on an external party (e.g. awaiting a client's
      design/Figma/approval), propose fyi ("still waiting on X — no action yet") or skip it; do
      NOT raise a confident ticket you can't act on yet.
    - Ticket vs task: ticket_write means DRAFTING A NEW ticket/story. If an item asks you to
      check, verify, confirm, review, or reply about an EXISTING ticket (e.g. a Jira/Shortcut
      mention carrying a ticket key), use create_task or a draft reply — not ticket_write.

    Respond with ONLY a JSON array, no prose, in this exact shape:
    [{"title": "short imperative title", "body": "1-3 sentences: what and why",
      "action_type": "vault_note", "confidence": 0.8, "reasoning": "why", "draft": "proposed content"}]
    """

    public struct Proposal: Equatable {
        public let title: String
        public let body: String
        public let actionType: String
        public let confidence: Double
        public let reasoning: String
        public let draft: String
    }

    /// Distinguishes "claude ran and genuinely proposed nothing" (`.proposals([])`,
    /// e.g. a well-formed empty JSON array) from "claude's output wasn't the expected
    /// JSON array shape at all" (`.unparseable`, e.g. prose, truncated/invalid JSON).
    /// Callers should surface the latter — a silently empty sweep looks identical to a
    /// broken one otherwise.
    public enum ParseOutcome: Equatable {
        case proposals([Proposal])
        case unparseable
    }

    /// Extracts the first JSON array from model output (code-fence tolerant).
    public static func parseOutcome(_ text: String) -> ParseOutcome {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"), start < end else { return .unparseable }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .unparseable
        }
        let proposals = raw.prefix(5).compactMap { item -> Proposal? in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let confidence = (item["confidence"] as? NSNumber)?.doubleValue ?? 0.5
            return Proposal(
                title: title,
                body: item["body"] as? String ?? "",
                actionType: item["action_type"] as? String ?? "vault_note",
                confidence: min(max(confidence, 0), 1),
                reasoning: item["reasoning"] as? String ?? "",
                draft: item["draft"] as? String ?? ""
            )
        }
        return .proposals(proposals)
    }

    /// Convenience wrapper for callers that don't need to distinguish "empty" from
    /// "unparseable" — both surface as `[]`. Prefer `parseOutcome` for anything
    /// user-facing (see `AgentService.sweep`).
    public static func parse(_ text: String) -> [Proposal] {
        if case .proposals(let proposals) = parseOutcome(text) { return proposals }
        return []
    }

    /// Grounded, action-aware execution prompt. Unlike a generic "do this task",
    /// it tells Claude what kind of deliverable to produce, hands back the draft it
    /// already proposed as the starting point, and — when feedback or a prior output
    /// are present — instructs it to revise rather than start over. Pure: takes the
    /// `RecommendationAction` enum plus primitives so it stays unit-testable.
    public static func executePrompt(
        title: String, body: String, action: RecommendationAction,
        draft: String = "", sourceContext: String = "",
        feedback: String = "", priorOutput: String = ""
    ) -> String {
        var parts: [String] = []
        parts.append("""
        Execute this task against the knowledge base in the current directory.
        \(directive(for: action))

        Task: \(title)

        \(body)
        """)

        let starting = draft.isEmpty ? body : draft
        if !starting.isEmpty {
            parts.append("""
            Starting point (your proposed draft — finalize and improve it, don't restart):
            \(starting)
            """)
        }

        if !sourceContext.isEmpty {
            parts.append("Context: \(sourceContext)")
        }

        if !priorOutput.isEmpty || !feedback.isEmpty {
            var revision = "This is a revision."
            if !priorOutput.isEmpty {
                revision += "\nYou previously produced:\n\(priorOutput)"
            }
            if !feedback.isEmpty {
                revision += "\nRevise per this feedback: \(feedback)"
            } else {
                revision += "\nImprove on the previous attempt."
            }
            revision += "\nReturn the full revised deliverable, not a diff."
            parts.append(revision)
        }

        parts.append("End your response with a concise summary of what you did and any output produced.")
        return parts.joined(separator: "\n\n")
    }

    /// Classify prompt for delegation ("Ask agent to do this"): read the task + the
    /// KB in the current directory and propose ONE way to action it — or decline. The
    /// agent never invents work; if the task needs you, it returns action_type "ignore"
    /// with a one-line reason. Output shape matches `parse` (a 1-element JSON array).
    public static func classifyPrompt(title: String, notes: String, areaName: String) -> String {
        """
        You are being asked to take on a task for the knowledge base in the current directory (project: \(areaName)).
        Read the relevant notes, then decide how YOU would action this task.

        Task: \(title)

        \(notes.isEmpty ? "(no extra detail)" : notes)

        Choose ONE action_type: vault_note, draft_email, draft_slack, ticket_write, or ignore.
        Use "ignore" to DECLINE — if this genuinely needs the human (a judgement call, missing
        access, or not something you can do well). Declining honestly is better than faking output.

        Respond with ONLY a JSON array containing exactly ONE object, no prose, in this exact shape:
        [{"title": "short imperative title", "body": "1-2 sentences: what you'll do and why",
          "action_type": "vault_note", "confidence": 0.0-1.0, "reasoning": "one sentence",
          "draft": "your proposed deliverable (or, if ignoring, why this needs the human)"}]
        """
    }

    /// Re-propose ONE recommendation using the user's comment as guidance.
    /// Does not execute the action — output shape matches `parse` (a 1-element
    /// JSON array) so the revision can be applied onto the same card.
    public static func reviseProposalPrompt(
        title: String, body: String, action: RecommendationAction,
        draft: String = "", reasoning: String = "",
        sourceContext: String = "", comment: String
    ) -> String {
        let starting = draft.isEmpty ? body : draft
        var parts: [String] = []
        parts.append("""
        You previously proposed this recommendation for the knowledge base in the current directory.
        Revise it using the user's comment as guidance. Do not execute the action — propose an updated recommendation only.

        Current title: \(title)
        Current action_type: \(action.rawValue)
        Current body: \(body.isEmpty ? "(none)" : body)
        Current reasoning: \(reasoning.isEmpty ? "(none)" : reasoning)
        Current draft:
        \(starting.isEmpty ? "(none)" : starting)
        """)
        if !sourceContext.isEmpty {
            parts.append("Context: \(sourceContext)")
        }
        parts.append("""
        User comment (guidance — follow this):
        \(comment)

        Choose ONE action_type: vault_note, create_task, draft_email, draft_slack, ticket_write, fyi, or ignore.
        Keep the same underlying item unless the comment asks you to change course.

        Respond with ONLY a JSON array containing exactly ONE object, no prose, in this exact shape:
        [{"title": "short imperative title", "body": "1-2 sentences: what and why",
          "action_type": "vault_note", "confidence": 0.0-1.0, "reasoning": "one sentence",
          "draft": "your revised proposed deliverable"}]
        """)
        return parts.joined(separator: "\n\n")
    }

    /// Per-action instruction. Gated actions (email/Slack/ticket) stay draft-only —
    /// execution produces text for review, it never sends or files anything.
    private static func directive(for action: RecommendationAction) -> String {
        switch action {
        case .draftEmail:
            return "Finalize a ready-to-send email (subject line + body) from the draft below. Produce the text only — do not send it."
        case .draftSlack:
            return "Finalize a concise, well-toned Slack message from the draft below. Produce the text only — do not send it."
        case .ticket:
            return "Produce the finalized ticket text (title + description) from the draft below. Produce the text only — do not file it."
        case .createTask:
            return "Produce the finalized task (title + description) from the draft below; do not invent fields."
        case .vaultNote:
            return "Apply this change to the knowledge base, starting from the proposed note text below."
        case .fyi:
            return "Produce the finalized briefing/FYI text from the draft below."
        case .ignore:
            return "No action is needed; briefly note why this was surfaced."
        }
    }
}
