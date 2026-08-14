import Foundation
import SwiftData

/// File-system boundary for the meeting-task sync, injected so the decision
/// logic can be unit-tested against an in-memory map (no disk).
public protocol MeetingVaultIO {
    /// Absolute path of the vault root the relative paths below hang off. Needed to
    /// hand the agent an absolute meeting-note path — its working directory is a
    /// single vault, not this root, so a root-relative path would not resolve.
    var rootPath: String { get }
    /// Meeting-note paths relative to the vault root.
    func meetingNotePaths() -> [String]
    func read(_ relativePath: String) -> String?
    func write(_ relativePath: String, _ contents: String) throws
    /// Write-only safety copy taken before any edit (the vault blocks deletes).
    func snapshot(_ relativePath: String, _ contents: String) throws
}

/// Result of an import pass — the not-silent record surfaced in the sweep digest.
public struct ImportDigest: Equatable {
    public var imported = 0
    public var completedFromVault = 0
    public var syncedToVault = 0
    /// Legacy tasks moved out of the fallback area into their real one.
    public var areasRepaired = 0
    /// Imported straight to an archived tombstone: past the freshness window, so
    /// never shown and never run (`MeetingTaskFreshness`).
    public var archivedAsStale = 0
    /// Rows re-keyed from the pre-2026-08-14 whole-line hash to the durable one.
    public var keysMigrated = 0
    public var clients: Set<String> = []

    public var summary: String {
        "imported \(imported) meeting task\(imported == 1 ? "" : "s") "
            + "(\(clients.count) client\(clients.count == 1 ? "" : "s"))"
    }
}

/// Bridges Leon's curated meeting-note checklists into Mustard's task store and
/// reflects completion back. Import is deterministic and idempotent (dedup by
/// `originKey`); write-back snapshots before editing and touches only the one line.
@MainActor
public final class MeetingTaskSync {
    /// vault-root folder → Mustard Area name. `nonisolated` so pure helpers
    /// (e.g. `AreaRouter`) can read this immutable map without main-actor isolation.
    /// Vault directory name → area. Both the real on-disk names and the short
    /// codes are listed: the vault root Leon points Mustard at is the parent
    /// `Codeheroes work`, whose children are the `*-Knowledge-Base` directories.
    /// Omitting those meant every meeting task fell through to `fallbackArea`
    /// and landed in Code Heroes regardless of vault (fixed 2026-07-28).
    public nonisolated static let defaultAreaMap: [String: String] = [
        "DL-Knowledge-Base": "Digital Licence",
        "SB-Knowledge-Base": "Sales Buddi",
        "Sandvik-Knowledge-Base": "Sandvik",
        "Code-Heroes-Knowledge-Base": "Code Heroes",
        "DL": "Digital Licence",
        "SB": "Sales Buddi",
        "Sandvik": "Sandvik",
        "Code Heroes": "Code Heroes",
    ]

    private let context: ModelContext
    private let io: MeetingVaultIO
    private let areaMap: [String: String]
    private let fallbackArea: String
    private var listCache: [String: TaskList] = [:]

    public init(
        context: ModelContext,
        io: MeetingVaultIO,
        areaMap: [String: String] = MeetingTaskSync.defaultAreaMap,
        fallbackArea: String = "Code Heroes"
    ) {
        self.context = context
        self.io = io
        self.areaMap = areaMap
        self.fallbackArea = fallbackArea
    }

    /// Apply the common gate rejection behavior used by desktop, mobile, and
    /// scheduled-board surfaces. Meeting tasks must first persist their ledger decision;
    /// ordinary tasks retain the existing local-delete behavior.
    @discardableResult
    public static func reject(
        _ task: MustardTask,
        context: ModelContext,
        vaultRoot: String,
        now: Date = .now
    ) -> Bool {
        guard task.source == "meeting" else {
            context.delete(task)
            return true
        }
        guard !vaultRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let sync = MeetingTaskSync(context: context, io: FileVaultIO(rootPath: vaultRoot))
        guard sync.ignoreInVault(task, now: now) else { return false }
        context.delete(task)
        return true
    }

    // MARK: Import (vault → Mustard)

    @discardableResult
    public func importTasks(now: Date = .now) -> ImportDigest {
        var digest = ImportDigest()
        var byKey = existingMeetingTasksByKey()
        // Keys already matched or created in this pass. The legacy re-key below
        // must never steal a row another ledger line has already claimed: for a
        // plain line with no metadata the old whole-line hash and the new
        // title hash are identical, so the second of two duplicate lines would
        // otherwise "migrate" the first line's task onto itself and collapse two
        // real tasks into one.
        var claimed: Set<String> = []

        for path in io.meetingNotePaths() {
            guard let text = io.read(path) else { continue }
            let subtitle = meetingSubtitle(text: text, path: path)
            for parsed in MeetingTaskParser.parse(text, notePath: path) {
                // One-time re-key: rows imported before 2026-08-14 are stored under
                // the old whole-line hash. Adopt them in place, otherwise the whole
                // corpus would re-import once as duplicates. Self-limiting — after
                // the rewrite the durable key matches directly.
                if byKey[parsed.originKey] == nil {
                    let legacy = MeetingTaskParser.legacyOriginKey(
                        notePath: path, line: parsed.rawLine)
                    if legacy != parsed.originKey, !claimed.contains(legacy),
                       let existing = byKey[legacy] {
                        existing.originKey = parsed.originKey
                        byKey[parsed.originKey] = existing
                        byKey[legacy] = nil
                        digest.keysMigrated += 1
                    }
                }
                claimed.insert(parsed.originKey)
                if let task = byKey[parsed.originKey] {
                    // Heal legacy giant-title imports once: only when notes was never
                    // populated and the freshly-parsed concise title differs. Gated to
                    // live (non-archived) meeting tasks so manual edits and pruned rows
                    // are never clobbered.
                    if task.source == "meeting", task.notes.isEmpty, task.title != parsed.title {
                        task.title = parsed.title
                        task.notes = Self.composeNotes(parsed, subtitle: subtitle)
                        task.tags = parsed.tags
                        if task.dueAt == nil { task.dueAt = parsed.due }
                    }
                    // Repair areas assigned while the area map was broken: everything
                    // fell through to the fallback, which would now route an old DL/SB/
                    // Sandvik task into the Code Heroes vault. Only touch tasks still
                    // sitting in the fallback whose own path implies something else, so
                    // a deliberate re-filing is never clobbered. Self-limiting: once
                    // moved, the condition no longer holds.
                    let impliedArea = clientName(forNotePath: path)
                    if task.source.hasPrefix("meeting"),
                       task.list?.area?.name == fallbackArea,
                       impliedArea != fallbackArea {
                        task.list = defaultList(forClient: impliedArea)
                        digest.areasRepaired += 1
                    }
                    // One-time safety migration for tasks imported before the
                    // approval gate existed. An unapproved runnable meeting task
                    // cannot bypass the new human decision.
                    if task.source == "meeting",
                       task.owner == .agent,
                       !task.agentApprovalGranted,
                       task.stage == .forAgent || task.stage == .queued {
                        task.stage = .needsApproval
                    }
                    if parsed.isDone && task.stage.isOpen {
                        // Line ticked in the vault while the task was open → vault won.
                        task.markDone(now: now)
                        digest.completedFromVault += 1
                    } else if !parsed.isDone && task.stage == .done {
                        // Completed in Mustard but the note line is still open → write back.
                        if completeInVault(task, now: task.completedAt ?? now) {
                            digest.syncedToVault += 1
                        }
                    }
                    // otherwise already reconciled → dedup no-op.
                } else {
                    let task = makeTask(parsed, subtitle: subtitle, now: now)
                    context.insert(task)
                    byKey[parsed.originKey] = task
                    digest.imported += 1
                    if task.source == "meeting:archived" { digest.archivedAsStale += 1 }
                    digest.clients.insert(clientName(forNotePath: path))
                }
            }
        }
        return digest
    }

    private func makeTask(_ p: ParsedMeetingTask, subtitle: String, now: Date) -> MustardTask {
        // A fresh meeting task is held for Leon's quick Do/Don't decision:
        // `.needsApproval` is excluded from AgentTaskQueue, and approval moves the
        // agent-owned task to `.queued`, which is the runnable lane.
        //
        // A stale one gets neither. Past the freshness window the item is nearly
        // always already done, dead, or superseded, so asking for a decision on it
        // spends the scarcest thing in the system — Leon's attention — on
        // archaeology. It is born as an archived tombstone instead: invisible, not
        // runnable, and never written back to the vault, but still keyed so its
        // ledger line can never re-import as fresh work. Same `meeting:archived`
        // semantics `archiveStaleMeetingTasks` uses, applied at the door.
        let isFresh = MeetingTaskFreshness.isFresh(
            srcNote: p.srcNote, notePath: p.notePath, now: now)
        let task = MustardTask(title: p.title, owner: isFresh ? .agent : .me)
        let meeting = resolveMeetingNote(p)
        task.stage = isFresh ? .needsApproval : .done
        task.source = isFresh ? "meeting" : "meeting:archived"
        // Stays the harvested file (the ledger) — it is the write-back target and is
        // hashed into originKey. The meeting note travels in `notes` instead.
        task.sourceURL = p.notePath
        task.sourceContext = meeting.map { meetingSubtitle(text: $0.text, path: $0.path) } ?? subtitle
        task.originKey = p.originKey
        task.dueAt = p.due
        task.notes = Self.composeNotes(p, subtitle: subtitle, meetingNotePath: meeting?.path)
        task.tags = p.tags
        task.list = defaultList(forClient: clientName(forNotePath: p.notePath))
        // Already ticked in the vault → import as done, don't resurrect it open.
        // Also the completion stamp for a stale tombstone, which is born closed.
        if p.isDone || !isFresh { task.markDone(now: now) }
        return task
    }

    /// Notes body = description (or transcript-quote fallback), then a provenance
    /// footer referencing the meeting, the quote, and owner/due.
    static func composeNotes(
        _ p: ParsedMeetingTask, subtitle: String, meetingNotePath: String? = nil
    ) -> String {
        let body = (p.desc?.isEmpty == false ? p.desc! : (p.transcriptQuote ?? ""))
            .trimmingCharacters(in: .whitespaces)
        var footer: [String] = []
        // A Task Ledger line names its originating meeting in `src:`. Prefer it —
        // the ledger's own title and path are the same for every task it holds, so
        // subtitle/noteDate would render a useless "From: Task Ledger" on every card.
        var from: String
        if let src = p.srcNote, !src.isEmpty {
            from = src
        } else {
            from = subtitle
            if let d = noteDate(p.notePath) { from += from.isEmpty ? d : " (\(d))" }
        }
        if !from.isEmpty { footer.append("From: \(from)") }
        // The agent's route to real context: the curated note carries the decisions,
        // discussion and waiting-on list, and its `.transcript.md` sibling the rest.
        if let meetingNotePath, !meetingNotePath.isEmpty {
            footer.append("Meeting note: \(meetingNotePath)")
        }
        if let q = p.transcriptQuote, !q.isEmpty, q != body { footer.append("Context: \"\(q)\"") }
        var meta: [String] = []
        if let o = p.owner, !o.isEmpty { meta.append("Owner: \(o)") }
        if let d = p.dueText, !d.isEmpty { meta.append("Due: \(d)") }
        if !meta.isEmpty { footer.append(meta.joined(separator: " · ")) }
        var out: [String] = []
        if !body.isEmpty { out.append(body) }
        if !footer.isEmpty { if !out.isEmpty { out.append("") }; out.append(contentsOf: footer) }
        return out.joined(separator: "\n")
    }

    /// Best-effort `YYYY-MM-DD` lifted from the meeting note path.
    static func noteDate(_ path: String) -> String? {
        guard let r = path.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        return String(path[r])
    }

    /// Resolve a ledger line's `src:` slug to the curated meeting note beside it —
    /// `<vault>/meetings/<YYYY>/<MM>/<slug>.md`. The agent gets this path in its
    /// prompt so it can read the decisions, discussion and transcript sibling; a
    /// ledger line's own one-sentence `desc:` is not enough context to act on.
    ///
    /// Deliberately NOT written to `task.sourceURL` — that field is the write-back
    /// target and its value is baked into `originKey`, so repointing it would stop
    /// completions ticking the ledger line.
    /// Returns nil unless the file actually exists, so callers fall back cleanly.
    /// Hands back the contents too, so the caller can lift the real meeting title
    /// without a second read.
    func resolveMeetingNote(_ p: ParsedMeetingTask) -> (path: String, text: String)? {
        guard let slug = p.srcNote, !slug.isEmpty,
              let date = Self.noteDate(slug), date.count == 10 else { return nil }
        let year = String(date.prefix(4))
        let month = String(date.dropFirst(5).prefix(2))

        // Rebuild the prefix up to and including the `meetings` component, so this
        // works whether the vault root is a KB directory or its parent.
        let parts = p.notePath.split(separator: "/").map(String.init)
        guard let meetingsIdx = parts.firstIndex(of: "meetings") else { return nil }
        let prefix = parts[...meetingsIdx].joined(separator: "/")

        let candidate = "\(prefix)/\(year)/\(month)/\(slug).md"
        guard let text = io.read(candidate) else { return nil }
        // Absolute, so it resolves from whatever working directory the agent runs in.
        return ((io.rootPath as NSString).appendingPathComponent(candidate), text)
    }

    // MARK: Write-back (Mustard → vault)

    /// On completing a meeting task, snapshot the source note and rewrite its
    /// `- [ ]` line to `- [x] ✅ <today>`. Returns `false` (and writes nothing)
    /// if the line can't be located — note moved/edited — so callers can flag it.
    @discardableResult
    public func completeInVault(_ task: MustardTask, now: Date = .now) -> Bool {
        guard task.source == "meeting",
              let key = task.originKey,
              let path = task.sourceURL,
              let contents = io.read(path) else { return false }

        var lines = contents.components(separatedBy: "\n")
        // Shared locator: it walks occurrence ordinals, so the nth of two identical
        // ledger lines ticks the right one.
        guard let idx = MeetingTaskParser.lineIndex(ofKey: key, in: lines, notePath: path)
        else { return false }

        do { try io.snapshot(path, contents) } catch { return false }
        lines[idx] = Self.tick(lines[idx], doneISO: Self.isoDay(now))
        do { try io.write(path, lines.joined(separator: "\n")) } catch { return false }
        return true
    }

    /// Record Leon's explicit decision not to do a meeting task in the source
    /// ledger. The snapshot is taken before the edit, and the local task is moved
    /// to a non-runnable sentinel state before the caller removes it. This keeps a
    /// crash between the vault write and SwiftData deletion from re-executing work.
    /// Returns `false` without mutating either side when the source line cannot be
    /// located or the snapshot/write fails.
    @discardableResult
    public func ignoreInVault(_ task: MustardTask, now: Date = .now) -> Bool {
        guard task.source == "meeting",
              let key = task.originKey,
              let path = task.sourceURL,
              let contents = io.read(path) else { return false }

        var lines = contents.components(separatedBy: "\n")
        guard let idx = MeetingTaskParser.lineIndex(ofKey: key, in: lines, notePath: path)
        else { return false }

        if !MeetingTaskParser.isIgnored(lines[idx]) {
            do { try io.snapshot(path, contents) } catch { return false }
            lines[idx] = MeetingTaskParser.markIgnored(lines[idx])
            do { try io.write(path, lines.joined(separator: "\n")) } catch { return false }
        }

        task.source = "meeting:ignored"
        task.markDone(now: now)
        return true
    }

    /// Flip `[ ]`→`[x]` and add `✅ <date>`, inserting before a trailing block id
    /// if present. No-op on the date if the line is already completed.
    static func tick(_ line: String, doneISO: String) -> String {
        var l = line
        if let r = l.range(of: #"\[ \]"#, options: .regularExpression) {
            l.replaceSubrange(r, with: "[x]")
        }
        if l.range(of: #"✅\s*\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return l }
        let marker = "✅ \(doneISO)"
        if let m = l.range(of: #"\s*\^[\w-]+\s*$"#, options: .regularExpression) {
            let blockId = l[m].trimmingCharacters(in: .whitespaces)
            l.replaceSubrange(m, with: " \(marker) \(blockId)")
        } else {
            l = l.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + " \(marker)"
        }
        return l
    }

    // MARK: Helpers

    private func existingMeetingTasksByKey() -> [String: MustardTask] {
        let all = (try? context.fetch(FetchDescriptor<MustardTask>())) ?? []
        var byKey: [String: MustardTask] = [:]
        // `hasPrefix` so backlog-pruned tasks (source `meeting:archived`) keep
        // suppressing re-import of their now-stale lines — without them the old
        // lines would re-flood as fresh tasks. Write-back stays gated on the exact
        // `"meeting"` source below, so archived tasks never tick the vault.
        for t in all where t.source.hasPrefix("meeting") {
            if let k = t.originKey { byKey[k] = t }
        }
        return byKey
    }

    /// The vault directory is normally the first path component, but scan them all
    /// so a re-rooted or nested vault still maps to the right area instead of
    /// silently falling back.
    private func clientName(forNotePath path: String) -> String {
        for component in path.split(separator: "/").map(String.init) {
            if let area = areaMap[component] { return area }
        }
        return fallbackArea
    }

    /// The note's first `# ` heading, falling back to the file name — the row subtitle.
    private func meetingSubtitle(text: String, path: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    /// The default list for a client Area, creating the Area + list on first use.
    private func defaultList(forClient name: String) -> TaskList {
        if let cached = listCache[name] { return cached }
        if let area = ((try? context.fetch(FetchDescriptor<Area>())) ?? []).first(where: { $0.name == name }) {
            let list = (area.lists ?? []).first ?? {
                let l = TaskList(name: name, area: area); context.insert(l); return l
            }()
            listCache[name] = list
            return list
        }
        let area = Area(name: name)
        context.insert(area)
        let list = TaskList(name: name, area: area)
        context.insert(list)
        listCache[name] = list
        return list
    }

    private static func isoDay(_ date: Date) -> String { isoFormatter.string(from: date) }
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
