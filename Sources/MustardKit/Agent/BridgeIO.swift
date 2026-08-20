import Foundation

/// File operations the bridge needs; injected so the service is testable with a stub.
public protocol BridgeIO {
    /// Live (non-archived) outbox uids. `.unknown` means the dir existed but listing
    /// failed — callers must skip export this tick (BAK-94), not treat it as empty.
    func liveOutboxUIDs(workingDir: String) -> BridgeLiveUIDs
    /// uids with a live (non-archived) result file under `results/` — i.e. the worker
    /// has finished but Mustard hasn't ingested yet. Used to suppress duplicate orders.
    /// `.unknown` on a listing error (dir present, IO/permission failed); never fail-open
    /// to empty — that re-issues and double-execs (BAK-92 / BAK-94).
    func liveResultUIDs(workingDir: String) -> BridgeLiveUIDs
    func writeWorkOrder(_ order: AgentWorkOrder, workingDir: String) throws
    func cancelWorkOrder(uid: String, workingDir: String) throws
    func readResults(workingDir: String) -> [(result: AgentResult, path: String)]
    func archiveResult(_ path: String, workingDir: String) throws
    /// Move undecodable / empty-uid `results/*.json` into `results/quarantine/` so they
    /// aren't silently re-scanned every loop (BAK-84). Returns how many were moved.
    @discardableResult
    func quarantineUndecodableResults(workingDir: String) -> Int
}

public struct FileBridgeIO: BridgeIO {
    public init() {}
    private var fm: FileManager { .default }

    public func liveOutboxUIDs(workingDir: String) -> BridgeLiveUIDs {
        liveJSONUIDs(in: BridgeFolders.outbox, workingDir: workingDir)
    }

    public func liveResultUIDs(workingDir: String) -> BridgeLiveUIDs {
        // Non-recursive: lists `results/` top-level only, so archived `results/done/`
        // files (and the `done` subdirectory itself) are excluded by the .json filter.
        liveJSONUIDs(in: BridgeFolders.results, workingDir: workingDir)
    }

    /// Absent path → `.listed([])`. Listing error on an existing path → `.unknown` (BAK-94).
    private func liveJSONUIDs(in relativeFolder: String, workingDir: String) -> BridgeLiveUIDs {
        let path = workingDir + "/" + relativeFolder
        do {
            let names = try fm.contentsOfDirectory(atPath: path)
            return BridgeListing.liveJSONUIDs(from: .success(names), pathExists: true)
        } catch {
            return BridgeListing.liveJSONUIDs(from: .failure(error), pathExists: fm.fileExists(atPath: path))
        }
    }

    public func writeWorkOrder(_ order: AgentWorkOrder, workingDir: String) throws {
        let dir = workingDir + "/" + BridgeFolders.outbox
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try BridgeCoding.encoder.encode(order).write(to: URL(fileURLWithPath: dir + "/\(order.uid).json"))
    }

    public func cancelWorkOrder(uid: String, workingDir: String) throws {
        let path = workingDir + "/" + BridgeFolders.outbox + "/\(uid).json"
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
    }

    public func readResults(workingDir: String) -> [(result: AgentResult, path: String)] {
        let p = workingDir + "/" + BridgeFolders.results
        // Empty-on-error here is fail-closed for ingest (skip this tick; files stay).
        // Unlike liveResultUIDs, it cannot re-issue a work order (BAK-94).
        guard let files = try? fm.contentsOfDirectory(atPath: p) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let path = p + "/" + name
            guard let data = fm.contents(atPath: path),
                  let r = try? BridgeCoding.decoder.decode(AgentResult.self, from: data),
                  !r.uid.isEmpty else { return nil }
            return (r, path)
        }
    }

    public func archiveResult(_ path: String, workingDir: String) throws {
        let doneDir = workingDir + "/" + BridgeFolders.resultsDone
        try fm.createDirectory(atPath: doneDir, withIntermediateDirectories: true)
        let dest = doneDir + "/" + (path as NSString).lastPathComponent
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.moveItem(atPath: path, toPath: dest)
    }

    @discardableResult
    public func quarantineUndecodableResults(workingDir: String) -> Int {
        let p = workingDir + "/" + BridgeFolders.results
        guard let files = try? fm.contentsOfDirectory(atPath: p) else { return 0 }
        var moved = 0
        for name in files.filter({ $0.hasSuffix(".json") }).sorted() {
            let path = p + "/" + name
            // "Decodable + non-empty uid" mirrors readResults' keep criterion exactly,
            // so anything readResults would silently drop is what we move aside.
            let usable = fm.contents(atPath: path)
                .flatMap { try? BridgeCoding.decoder.decode(AgentResult.self, from: $0) }
                .map { !$0.uid.isEmpty } ?? false
            if usable { continue }
            let qdir = workingDir + "/" + BridgeFolders.resultsQuarantine
            guard (try? fm.createDirectory(atPath: qdir, withIntermediateDirectories: true)) != nil
            else { continue }
            let dest = qdir + "/" + name
            if fm.fileExists(atPath: dest) { try? fm.removeItem(atPath: dest) }
            if (try? fm.moveItem(atPath: path, toPath: dest)) != nil { moved += 1 }
        }
        return moved
    }
}
