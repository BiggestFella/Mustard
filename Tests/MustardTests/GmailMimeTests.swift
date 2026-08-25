import XCTest
@testable import MustardKit

final class GmailMimeTests: XCTestCase {
    func testReplySubjectAddsRePrefixOnce() {
        XCTAssertEqual(GmailMime.replySubject("DLA build"), "Re: DLA build")
        XCTAssertEqual(GmailMime.replySubject("Re: DLA build"), "Re: DLA build")
        XCTAssertEqual(GmailMime.replySubject("RE: DLA build"), "RE: DLA build")
    }

    func testReplyReferencesAppendsParentMessageID() {
        XCTAssertEqual(GmailMime.replyReferences(parentReferences: "<a@x> <b@x>", parentMessageID: "<c@x>"),
                       "<a@x> <b@x> <c@x>")
        XCTAssertEqual(GmailMime.replyReferences(parentReferences: "", parentMessageID: "<c@x>"), "<c@x>")
        XCTAssertEqual(GmailMime.replyReferences(parentReferences: "", parentMessageID: ""), "")
    }

    func testMessageHasThreadingHeadersAndBase64Body() {
        let mime = GmailMime.message(
            to: "ana@tmr.qld.gov.au", subject: "Re: DLA build", body: "On it — fix lands today.",
            inReplyTo: "<abc@x>", references: "<root@x> <abc@x>")
        let lines = mime.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains("To: ana@tmr.qld.gov.au"))
        XCTAssertTrue(lines.contains("Subject: Re: DLA build"))
        XCTAssertTrue(lines.contains("In-Reply-To: <abc@x>"))
        XCTAssertTrue(lines.contains("References: <root@x> <abc@x>"))
        XCTAssertTrue(lines.contains("MIME-Version: 1.0"))
        XCTAssertTrue(lines.contains("Content-Type: text/plain; charset=\"UTF-8\""))
        XCTAssertTrue(lines.contains("Content-Transfer-Encoding: base64"))
        // Blank line separates headers from body; body decodes back to the input.
        let split = mime.range(of: "\r\n\r\n")
        XCTAssertNotNil(split)
        let bodyPart = String(mime[split!.upperBound...]).replacingOccurrences(of: "\r\n", with: "")
        XCTAssertEqual(Data(base64Encoded: bodyPart).flatMap { String(data: $0, encoding: .utf8) },
                       "On it — fix lands today.")
    }

    func testNonASCIISubjectIsRFC2047Encoded() {
        let mime = GmailMime.message(to: "a@b.c", subject: "Résumé ✅", body: "x")
        XCTAssertTrue(mime.contains("Subject: =?UTF-8?B?"))
    }

    func testHeaderInjectionIsNeutralized() {
        let mime = GmailMime.message(to: "a@b.c\r\nBcc: evil@x.y", subject: "hi\nX-Evil: 1", body: "x")
        XCTAssertFalse(mime.contains("Bcc: evil@x.y"))
        XCTAssertFalse(mime.contains("X-Evil: 1"))
    }

    func testOmitsEmptyThreadingHeaders() {
        let mime = GmailMime.message(to: "a@b.c", subject: "s", body: "x")
        XCTAssertFalse(mime.contains("In-Reply-To:"))
        XCTAssertFalse(mime.contains("References:"))
    }
}
