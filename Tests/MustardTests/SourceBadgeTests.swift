import XCTest
@testable import MustardKit

final class SourceBadgeTests: XCTestCase {
    func test_gmail_isBadged() {
        let b = SourceBadge.badge(for: .gmail)
        XCTAssertFalse(b.isQuiet)
        XCTAssertEqual(b.label, "Gmail")
    }

    func test_vault_isQuiet() {
        XCTAssertTrue(SourceBadge.badge(for: .vault).isQuiet)
    }

    func test_unknownRaw_fallsBackToQuietVault() {
        XCTAssertTrue(SourceBadge.badge(forRaw: "carrier-pigeon").isQuiet)
    }

    func test_jira_badge() {
        let b = SourceBadge.badge(for: .jira)
        XCTAssertFalse(b.isQuiet)
        XCTAssertEqual(b.label, "Jira")
        XCTAssertEqual(b.symbol, "diamond.fill")
        XCTAssertEqual(b.fgHex, "#2E5CB8")
    }

    func test_shortcut_badge() {
        let b = SourceBadge.badge(for: .shortcut)
        XCTAssertFalse(b.isQuiet)
        XCTAssertEqual(b.label, "Shortcut")
        XCTAssertEqual(b.bgHex, "#ECE8F7")
    }

    func test_gmail_carriesItsColours() {
        let b = SourceBadge.badge(for: .gmail)
        XCTAssertEqual(b.fgHex, "#A32D2D")
        XCTAssertEqual(b.bgHex, "#FCEBEB")
    }

    func test_jira_fromRaw() {
        XCTAssertEqual(SourceBadge.badge(forRaw: "jira").label, "Jira")
    }

    func test_voice_badge_agentPurplePill() {
        let b = SourceBadge.badge(for: .voice)
        XCTAssertFalse(b.isQuiet)
        XCTAssertEqual(b.label, "Voice")
        XCTAssertEqual(b.symbol, "mic.fill")
        XCTAssertEqual(b.fgHex, "#7F77DD")
        XCTAssertEqual(SourceBadge.badge(forRaw: "voice").label, "Voice")
    }
}
