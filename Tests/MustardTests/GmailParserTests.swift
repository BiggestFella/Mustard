import XCTest
@testable import MustardKit

final class GmailParserTests: XCTestCase {
    func testParseMessageListExtractsIDsInOrder() {
        let json = #"{"messages":[{"id":"m3","threadId":"t3"},{"id":"m2","threadId":"t2"}],"resultSizeEstimate":2}"#
        XCTAssertEqual(GmailParser.parseMessageList(Data(json.utf8)), ["m3", "m2"])
    }

    func testParseMessageListEmptyAndMalformed() {
        XCTAssertEqual(GmailParser.parseMessageList(Data("{}".utf8)), [])
        XCTAssertEqual(GmailParser.parseMessageList(Data("not json".utf8)), [])
    }

    func testParseLabels() {
        let json = #"{"labels":[{"id":"INBOX","name":"INBOX","type":"system"},{"id":"Label_7","name":"Clients/TMR"}]}"#
        XCTAssertEqual(GmailParser.parseLabels(Data(json.utf8)),
                       [GmailLabel(id: "INBOX", name: "INBOX"), GmailLabel(id: "Label_7", name: "Clients/TMR")])
    }

    func testDecodeBase64URLHandlesURLAlphabetAndMissingPadding() {
        // "hi?~" base64 is "aGk/fg==" → base64url "aGk_fg" (no padding).
        XCTAssertEqual(GmailParser.decodeBase64URL("aGk_fg").flatMap { String(data: $0, encoding: .utf8) }, "hi?~")
    }

    func testParseMessagePrefersNestedTextPlainPart() {
        // multipart/alternative with html first, plain nested one level down.
        let plainB64 = Data("plain wins".utf8).base64URLEncodedString()
        let htmlB64 = Data("<p>html</p>".utf8).base64URLEncodedString()
        let json = """
        {"id":"m1","threadId":"t1","labelIds":["INBOX","Label_7"],"internalDate":"1780000000000",
         "snippet":"snip",
         "payload":{"mimeType":"multipart/mixed","headers":[
            {"name":"From","value":"Ana <ana@tmr.qld.gov.au>"},
            {"name":"To","value":"leon@codeheroes.com.au"},
            {"name":"Subject","value":"DLA build"},
            {"name":"Message-ID","value":"<abc@mail.gmail.com>"},
            {"name":"References","value":"<root@x>"}],
          "parts":[
            {"mimeType":"text/html","body":{"data":"\(htmlB64)"}},
            {"mimeType":"multipart/alternative","parts":[
               {"mimeType":"text/plain","body":{"data":"\(plainB64)"}}]}]}}
        """
        let m = GmailParser.parseMessage(Data(json.utf8))
        XCTAssertEqual(m?.id, "m1")
        XCTAssertEqual(m?.threadId, "t1")
        XCTAssertEqual(m?.labelIds, ["INBOX", "Label_7"])
        XCTAssertEqual(m?.from, "Ana <ana@tmr.qld.gov.au>")
        XCTAssertEqual(m?.subject, "DLA build")
        XCTAssertEqual(m?.messageIdHeader, "<abc@mail.gmail.com>")
        XCTAssertEqual(m?.references, "<root@x>")
        XCTAssertEqual(m?.date, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(m?.body, "plain wins")
    }

    func testParseMessageFallsBackToStrippedHTML() {
        let htmlB64 = Data("<html><style>p{}</style><p>Hello&nbsp;&amp; welcome</p><br>bye</html>".utf8).base64URLEncodedString()
        let json = #"{"id":"m2","threadId":"t2","payload":{"mimeType":"text/html","body":{"data":"\#(htmlB64)"},"headers":[]}}"#
        let m = GmailParser.parseMessage(Data(json.utf8))
        XCTAssertEqual(m?.body, "Hello & welcome\nbye")
    }

    func testStrippedHTMLHandlesLargeInput() {
        let huge = "<p>" + String(repeating: "a", count: 100_000) + "</p>"
        let result = GmailParser.strippedHTML(huge)
        XCTAssertNotNil(result)
        XCTAssertFalse(result.isEmpty)
    }

    func testParseMessageRejectsMissingIdentity() {
        XCTAssertNil(GmailParser.parseMessage(Data(#"{"threadId":"t"}"#.utf8)))
        XCTAssertNil(GmailParser.parseMessage(Data("nope".utf8)))
    }

    func testPartWalkStopsAtDepthCap() {
        // A text/plain part buried 20 levels deep is past the cap → body falls back empty.
        let plainB64 = Data("too deep".utf8).base64URLEncodedString()
        var inner = #"{"mimeType":"text/plain","body":{"data":"\#(plainB64)"}}"#
        for _ in 0..<20 {
            inner = #"{"mimeType":"multipart/mixed","parts":[\#(inner)]}"#
        }
        let json = #"{"id":"m9","threadId":"t9","payload":\#(inner)}"#
        let m = GmailParser.parseMessage(Data(json.utf8))
        XCTAssertEqual(m?.id, "m9")
        XCTAssertEqual(m?.body, "")
    }

    func testHeaderLookupIsCaseInsensitive() {
        let json = #"{"id":"m3","threadId":"t3","payload":{"headers":[{"name":"message-id","value":"<x@y>"}]}}"#
        XCTAssertEqual(GmailParser.parseMessage(Data(json.utf8))?.messageIdHeader, "<x@y>")
    }
}
