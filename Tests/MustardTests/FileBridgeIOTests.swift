import XCTest
@testable import MustardKit

final class FileBridgeIOTests: XCTestCase {
    private var dir: String!
    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "bridge-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    func test_write_list_then_cancel() throws {
        let io = FileBridgeIO()
        let o = AgentWorkOrder(uid: "u1", mode: "execute", actionType: "ticket_write", title: "t",
            body: "b", area: "Digital Licence", project: "DL", sourceContext: "", links: [],
            createdAt: Date(timeIntervalSince1970: 1))
        try io.writeWorkOrder(o, workingDir: dir)
        XCTAssertEqual(io.liveOutboxUIDs(workingDir: dir), .listed(["u1"]))
        try io.cancelWorkOrder(uid: "u1", workingDir: dir)
        XCTAssertEqual(io.liveOutboxUIDs(workingDir: dir), .listed([]))
    }

    // BAK-94: a missing results/ dir is safe empty — first export may issue.
    func test_liveResultUIDs_absentDir_isListedEmpty() {
        XCTAssertEqual(FileBridgeIO().liveResultUIDs(workingDir: dir), .listed([]))
    }

    func test_liveOutboxUIDs_absentDir_isListedEmpty() {
        XCTAssertEqual(FileBridgeIO().liveOutboxUIDs(workingDir: dir), .listed([]))
    }

    func test_liveResultUIDs_listsTopLevelJson_excludesDone() throws {
        let io = FileBridgeIO()
        let resultsDir = dir + "/" + BridgeFolders.results
        let doneDir = dir + "/" + BridgeFolders.resultsDone
        try FileManager.default.createDirectory(atPath: doneDir, withIntermediateDirectories: true)
        try #"{"uid":"live","mode":"execute","status":"done"}"#
            .write(toFile: resultsDir + "/live.json", atomically: true, encoding: .utf8)
        try #"{"uid":"archived","mode":"execute","status":"done"}"#
            .write(toFile: doneDir + "/archived.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(io.liveResultUIDs(workingDir: dir), .listed(["live"]))
    }

    // BAK-94: listing error on an existing path (here: `results` is a file, not a
    // directory) must be `.unknown`, never an empty set that would re-issue.
    func test_liveResultUIDs_listingErrorOnExistingPath_isUnknown() throws {
        let agentDir = dir + "/_agent"
        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
        try "not-a-directory".write(toFile: dir + "/" + BridgeFolders.results, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileBridgeIO().liveResultUIDs(workingDir: dir), .unknown)
    }

    func test_liveOutboxUIDs_listingErrorOnExistingPath_isUnknown() throws {
        let agentDir = dir + "/_agent"
        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
        try "not-a-directory".write(toFile: dir + "/" + BridgeFolders.outbox, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileBridgeIO().liveOutboxUIDs(workingDir: dir), .unknown)
    }

    // BAK-84: a malformed result file is dropped by readResults but was re-scanned
    // every loop. Quarantine moves undecodable / empty-uid files aside so they aren't
    // re-read, while valid results stay put.
    func test_quarantine_movesUndecodable_keepsValid() throws {
        let io = FileBridgeIO()
        let resultsDir = dir + "/" + BridgeFolders.results
        try FileManager.default.createDirectory(atPath: resultsDir, withIntermediateDirectories: true)
        try #"{"uid":"u1","mode":"execute","status":"done"}"#
            .write(toFile: resultsDir + "/u1.json", atomically: true, encoding: .utf8)
        try "not json at all".write(toFile: resultsDir + "/bad.json", atomically: true, encoding: .utf8)
        try #"{"uid":"","mode":"execute","status":"done"}"#
            .write(toFile: resultsDir + "/empty-uid.json", atomically: true, encoding: .utf8)

        let moved = io.quarantineUndecodableResults(workingDir: dir)

        XCTAssertEqual(moved, 2)
        XCTAssertEqual(io.readResults(workingDir: dir).map(\.result.uid), ["u1"])   // valid kept
        let q = dir + "/" + BridgeFolders.resultsQuarantine
        XCTAssertTrue(FileManager.default.fileExists(atPath: q + "/bad.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q + "/empty-uid.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultsDir + "/bad.json"))
    }

    func test_quarantine_noResultsDir_returnsZero() {
        XCTAssertEqual(FileBridgeIO().quarantineUndecodableResults(workingDir: dir), 0)
    }

    func test_quarantine_allValid_movesNothing() throws {
        let io = FileBridgeIO()
        let resultsDir = dir + "/" + BridgeFolders.results
        try FileManager.default.createDirectory(atPath: resultsDir, withIntermediateDirectories: true)
        try #"{"uid":"u1","mode":"execute","status":"done"}"#
            .write(toFile: resultsDir + "/u1.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(io.quarantineUndecodableResults(workingDir: dir), 0)
        XCTAssertEqual(io.readResults(workingDir: dir).count, 1)
    }

    // Re-running quarantine when a same-named file already sits in quarantine/ must
    // clobber the stale one and still report an accurate moved count (idempotent).
    func test_quarantine_rerun_clobbersAndCountsAccurately() throws {
        let io = FileBridgeIO()
        let resultsDir = dir + "/" + BridgeFolders.results
        try FileManager.default.createDirectory(atPath: resultsDir, withIntermediateDirectories: true)
        try "garbage".write(toFile: resultsDir + "/bad.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(io.quarantineUndecodableResults(workingDir: dir), 1)
        try "garbage again".write(toFile: resultsDir + "/bad.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(io.quarantineUndecodableResults(workingDir: dir), 1)   // clobbers, count accurate
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultsDir + "/bad.json"))
    }

    func test_readResults_thenArchive() throws {
        let io = FileBridgeIO()
        let resultsDir = dir + "/" + BridgeFolders.results
        try FileManager.default.createDirectory(atPath: resultsDir, withIntermediateDirectories: true)
        let json = #"{"uid":"u1","mode":"execute","status":"done"}"#
        try json.write(toFile: resultsDir + "/u1.json", atomically: true, encoding: .utf8)

        let read = io.readResults(workingDir: dir)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].result.uid, "u1")

        try io.archiveResult(read[0].path, workingDir: dir)
        XCTAssertTrue(io.readResults(workingDir: dir).isEmpty)              // gone from results/
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/" + BridgeFolders.resultsDone + "/u1.json"))
    }
}
