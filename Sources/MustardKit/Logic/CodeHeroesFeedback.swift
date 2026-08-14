import CryptoKit
import Foundation

/// Explicit feedback is evidence about the triage surface, not a silent policy edit.
public enum CodeHeroesFeedbackSignal: String, Codable, CaseIterable, Sendable {
    case useful
    case tooNoisy = "too-noisy"
    case wrongProject = "wrong-project"
    case alreadyHandled = "already-handled"
}

public struct CodeHeroesFeedbackEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: String
    public let signal: CodeHeroesFeedbackSignal
    public let actor: String
    public let recordedAt: String
    public let clusterID: String
    public let decisionIDs: [String]
    public let projectID: String
    public let sourceRoutine: String
    public let actionState: String
    public let reason: String?

    public init(
        eventID: String,
        signal: CodeHeroesFeedbackSignal,
        recordedAt: String,
        clusterID: String,
        decisionIDs: [String],
        projectID: String,
        sourceRoutine: String,
        actionState: String,
        reason: String?
    ) {
        self.schemaVersion = 1
        self.eventID = eventID
        self.signal = signal
        self.actor = "leon"
        self.recordedAt = recordedAt
        self.clusterID = clusterID
        self.decisionIDs = decisionIDs
        self.projectID = projectID
        self.sourceRoutine = sourceRoutine
        self.actionState = actionState
        self.reason = reason
    }
}

public struct CodeHeroesFeedbackCandidate: Equatable, Sendable {
    public let candidateID: String
    public let signal: CodeHeroesFeedbackSignal
    public let projectID: String
    public let sourceRoutine: String
    public let eventIDs: [String]
    public let clusterIDs: [String]
    public let windowStart: Date
    public let windowEnd: Date
    public let suggestion: String

    public var taskUID: String { "codeheroes:feedback:\(candidateID)" }

    public init(
        candidateID: String,
        signal: CodeHeroesFeedbackSignal,
        projectID: String,
        sourceRoutine: String,
        eventIDs: [String],
        clusterIDs: [String],
        windowStart: Date,
        windowEnd: Date,
        suggestion: String
    ) {
        self.candidateID = candidateID
        self.signal = signal
        self.projectID = projectID
        self.sourceRoutine = sourceRoutine
        self.eventIDs = eventIDs
        self.clusterIDs = clusterIDs
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.suggestion = suggestion
    }

    public var notes: String {
        """
        Proposed learning rule (not applied):
        \(suggestion)

        Evidence window: \(ISO8601DateFormatter().string(from: windowStart)) → \(ISO8601DateFormatter().string(from: windowEnd))
        Comparable signals: \(eventIDs.count) across \(clusterIDs.count) distinct records
        Source routine: \(sourceRoutine)
        Event IDs: \(eventIDs.joined(separator: ", "))

        Approval required: this candidate will not change routing, grouping, skills, routines, or canonical facts until explicitly approved.
        """
    }
}

public enum CodeHeroesFeedbackError: Error, Equatable, LocalizedError {
    case notProjection
    case unsafePath(String)
    case invalidReason
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notProjection: "Feedback is available only for Code Heroes decision projections."
        case .unsafePath(let path): "Code Heroes feedback path is unsafe: \(path)"
        case .invalidReason: "Feedback reason must be 1–1,000 characters."
        case .writeFailed(let message): "Could not save Code Heroes feedback: \(message)"
        }
    }
}

public struct CodeHeroesFeedbackRecordResult: Equatable, Sendable {
    public let event: CodeHeroesFeedbackEvent
    public let eventURL: URL
    public let candidates: [CodeHeroesFeedbackCandidate]
}

/// Writes bounded feedback events and proposes (but never applies) learning candidates.
public enum CodeHeroesFeedbackRecorder {
    public static let threshold = 3
    public static let windowDays: TimeInterval = 30 * 24 * 60 * 60

    public static func record(
        task: MustardTask,
        signal: CodeHeroesFeedbackSignal,
        reason: String? = nil,
        now: Date = .now,
        fileManager: FileManager = .default
    ) throws -> CodeHeroesFeedbackRecordResult {
        guard CodeHeroesDecisionPolicy.isProjection(task) else {
            throw CodeHeroesFeedbackError.notProjection
        }
        let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedReason == nil || (normalizedReason!.utf8.count <= 1_000) else {
            throw CodeHeroesFeedbackError.invalidReason
        }
        let root = try CodeHeroesDecisionActionRequestBuilder.repositoryRoot(for: task)
        guard isSafeRepositoryRoot(root) else {
            throw CodeHeroesFeedbackError.unsafePath(root.path)
        }

        let context = parseContext(task.sourceContext)
        let clusterID = context["cluster"] ?? task.uid
        let decisionIDs = context["source_ids"]?.split(separator: ",").map(String.init).filter { !$0.isEmpty } ?? []
        let projectID = task.tags.first(where: { $0.hasPrefix("project:") })?.dropFirst("project:".count).description ?? "unknown"
        let routine = context["routine"] ?? CodeHeroesDecisionPolicy.source
        let event = CodeHeroesFeedbackEvent(
            eventID: eventID(now: now),
            signal: signal,
            recordedAt: iso(now),
            clusterID: clusterID,
            decisionIDs: decisionIDs,
            projectID: projectID,
            sourceRoutine: routine,
            actionState: task.stage.rawValue,
            reason: normalizedReason?.isEmpty == true ? nil : normalizedReason
        )
        let eventsDirectory = root.appendingPathComponent("operations/feedback/events", isDirectory: true)
        let eventURL = eventsDirectory.appendingPathComponent("\(event.eventID).md")
        do {
            try fileManager.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
            try Data(render(event).utf8).write(to: eventURL, options: .atomic)
        } catch {
            throw CodeHeroesFeedbackError.writeFailed(error.localizedDescription)
        }

        let allEvents = loadEvents(from: eventsDirectory, fileManager: fileManager)
        let candidates = aggregate(allEvents, now: now)
        for candidate in candidates {
            let directory = root.appendingPathComponent("operations/feedback/candidates", isDirectory: true)
            let url = directory.appendingPathComponent("\(candidate.candidateID).md")
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(render(candidate).utf8).write(to: url, options: .atomic)
            } catch {
                throw CodeHeroesFeedbackError.writeFailed(error.localizedDescription)
            }
        }
        return .init(event: event, eventURL: eventURL, candidates: candidates)
    }

    public static func aggregate(
        _ events: [CodeHeroesFeedbackEvent],
        now: Date = .now,
        threshold: Int = threshold
    ) -> [CodeHeroesFeedbackCandidate] {
        let cutoff = now.addingTimeInterval(-windowDays)
        let grouped = Dictionary(grouping: events.filter {
            guard let date = date($0.recordedAt) else { return false }
            return date >= cutoff && date <= now
        }) { "\($0.signal.rawValue)|\($0.projectID)|\($0.sourceRoutine)" }
        return grouped.compactMap { key, values in
            let comparable = values.sorted { $0.recordedAt < $1.recordedAt }
            let clusters = Array(Set(comparable.map(\.clusterID))).sorted()
            guard comparable.count >= threshold, clusters.count >= threshold,
                  let start = comparable.compactMap({ date($0.recordedAt) }).min(),
                  let end = comparable.compactMap({ date($0.recordedAt) }).max(),
                  let first = comparable.first else { return nil }
            let candidateID = "CAND-\(digest(key).prefix(12))"
            return CodeHeroesFeedbackCandidate(
                candidateID: candidateID,
                signal: first.signal,
                projectID: first.projectID,
                sourceRoutine: first.sourceRoutine,
                eventIDs: comparable.map(\.eventID),
                clusterIDs: clusters,
                windowStart: start,
                windowEnd: end,
                suggestion: suggestion(for: first.signal, projectID: first.projectID)
            )
        }.sorted { $0.candidateID < $1.candidateID }
    }

    private static func suggestion(for signal: CodeHeroesFeedbackSignal, projectID: String) -> String {
        switch signal {
        case .useful: "Keep this source and grouping visible in the \(projectID) triage flow."
        case .tooNoisy: "Consider moving repeated low-value items from \(projectID) to a digest or background-maintenance view."
        case .wrongProject: "Review the \(projectID) routing rule for this source type before changing any project assignment."
        case .alreadyHandled: "Consider deduplication or handled-state checks for repeated \(projectID) items."
        }
    }

    private static func loadEvents(from directory: URL, fileManager: FileManager) -> [CodeHeroesFeedbackEvent] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return urls.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parseEvent(text)
        }
    }

    private static func parseEvent(_ text: String) -> CodeHeroesFeedbackEvent? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        let fields = lines[1..<end].reduce(into: [String: String]()) { result, line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let id = fields["event_id"], let signal = fields["signal"].flatMap(CodeHeroesFeedbackSignal.init(rawValue:)),
              let recorded = fields["recorded_at"], let cluster = fields["cluster_id"],
              let project = fields["project_id"], let routine = fields["source_routine"],
              let state = fields["action_state"] else { return nil }
        let decisions = fields["decision_ids"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let reason = lines[(end + 1)...].drop { $0 != "Reason:" }.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(eventID: id, signal: signal, recordedAt: recorded, clusterID: cluster, decisionIDs: decisions, projectID: project, sourceRoutine: routine, actionState: state, reason: reason.isEmpty ? nil : reason)
    }

    private static func render(_ event: CodeHeroesFeedbackEvent) -> String {
        """
        ---
        schema_version: 1
        event_id: \(event.eventID)
        signal: \(event.signal.rawValue)
        actor: \(event.actor)
        recorded_at: \(event.recordedAt)
        cluster_id: \(event.clusterID)
        decision_ids: \(event.decisionIDs.joined(separator: ","))
        project_id: \(event.projectID)
        source_routine: \(event.sourceRoutine)
        action_state: \(event.actionState)
        ---
        Reason:
        \(event.reason ?? "(none)")
        """
    }

    private static func render(_ candidate: CodeHeroesFeedbackCandidate) -> String {
        """
        ---
        schema_version: 1
        candidate_id: \(candidate.candidateID)
        status: proposed
        signal: \(candidate.signal.rawValue)
        project_id: \(candidate.projectID)
        source_routine: \(candidate.sourceRoutine)
        comparable_count: \(candidate.eventIDs.count)
        distinct_records: \(candidate.clusterIDs.count)
        window_start: \(iso(candidate.windowStart))
        window_end: \(iso(candidate.windowEnd))
        ---
        \(candidate.notes)
        """
    }

    private static func parseContext(_ value: String) -> [String: String] {
        value.split(separator: ";").reduce(into: [:]) { result, segment in
            let parts = segment.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            result[parts[0]] = parts[1]
        }
    }

    private static func isSafeRepositoryRoot(_ root: URL) -> Bool {
        root.path.hasPrefix("/") && !root.path.contains("/..")
    }

    private static func eventID(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "FEEDBACK-\(formatter.string(from: now))-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
