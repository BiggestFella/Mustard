import Foundation

/// Concrete `MeetingVaultIO` over a real Obsidian vault on disk. Enumerates
/// meeting notes (`**/meetings/**/*.md`), reads/writes UTF-8, and snapshots to
/// `<root>/hub/.snapshots/<file>.<ts>.md` — a write-only safety copy, matching
/// the Sync pipeline's net (the vault blocks deletes). The IO boundary; the
/// decision logic that uses it is unit-tested via an injected fake.
public struct FileVaultIO: MeetingVaultIO {
    private let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public init(rootPath: String) {
        self.init(root: URL(fileURLWithPath: rootPath, isDirectory: true))
    }

    public func meetingNotePaths() -> [String] {
        // Subtrees never worth descending into — pruning keeps the 60s harvest cheap
        // even when a KB embeds a built site (node_modules can be tens of thousands of
        // files; `Codeheroes work` is ~92% node_modules). Results are unchanged — the
        // `meetings/` filter already excludes them — this just avoids walking them.
        let prune: Set<String> = ["node_modules", ".git", ".build", "_artifacts"]
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker {
            if prune.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard url.pathExtension == "md" else { continue }
            let rel = relativePath(of: url)
            let components = rel.split(separator: "/").map(String.init)
            // Only curated meeting notes; never our own snapshots / hub scratch.
            guard components.contains("meetings"),
                  !components.contains(".snapshots"),
                  components.first != "hub" else { continue }
            paths.append(rel)
        }
        return paths.sorted()
    }

    public func read(_ relativePath: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    public func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    public func snapshot(_ relativePath: String, _ contents: String) throws {
        let dir = root.appendingPathComponent("hub/.snapshots", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (relativePath as NSString).lastPathComponent
        let stamp = Self.stampFormatter.string(from: .now)
        try contents.write(
            to: dir.appendingPathComponent("\(name).\(stamp).md"),
            atomically: true, encoding: .utf8)
    }

    private func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// Filesystem-safe minute-precision stamp (no colons): `2026-06-18T0900`.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HHmm"
        return f
    }()
}

/// Whole-vault note access for the Notes surface (BAK-146). Same IO boundary as
/// `MeetingVaultIO`, but enumerates every `.md` file rather than `meetings/` only.
public protocol NoteVaultIO {
    func notePaths() -> [String]
    func read(_ relativePath: String) -> String?
    func write(_ relativePath: String, _ contents: String) throws
    func snapshot(_ relativePath: String, _ contents: String) throws
    func modificationDate(_ relativePath: String) -> Date?
    func move(from: String, to: String) throws
    func trash(_ relativePath: String) throws
}

extension FileVaultIO: NoteVaultIO {
    /// Structural prune (as meetingNotePaths) + Mustard/agent scratch. `_filed/`
    /// stays visible — Notes is a human-browsing surface (spec: Ignore rules).
    public func notePaths() -> [String] {
        let prune: Set<String> = ["node_modules", ".git", ".build", "_artifacts",
                                  ".obsidian", "_recs", "_agent", "hub", ".snapshots"]
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker {
            if prune.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard url.pathExtension == "md" else { continue }
            paths.append(relativePath(of: url))
        }
        return paths.sorted()
    }

    public func modificationDate(_ relativePath: String) -> Date? {
        let path = root.appendingPathComponent(relativePath).path
        return (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    public func move(from: String, to: String) throws {
        let src = root.appendingPathComponent(from)
        let dst = root.appendingPathComponent(to)
        try fileManager.createDirectory(at: dst.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.moveItem(at: src, to: dst)
    }

    /// System Trash (Finder-recoverable) — Mustard isn't git-backed yet, so this is
    /// the reversible delete (Notes polish pack: no hard delete in this slice).
    public func trash(_ relativePath: String) throws {
        try fileManager.trashItem(at: root.appendingPathComponent(relativePath),
                                  resultingItemURL: nil)
    }
}
