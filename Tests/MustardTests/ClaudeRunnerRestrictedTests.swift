import XCTest
@testable import MustardKit

final class ClaudeRunnerRestrictedTests: XCTestCase {
    func testRestrictedArgsDenyDangerousToolsAndMCP() {
        let args = ClaudeRunner.restrictedArguments(prompt: "hi")
        // The prompt is present under -p.
        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args.contains("hi"))
        XCTAssertTrue(args.contains("--output-format"))
        // Non-bypass permission mode is forced.
        XCTAssertEqual(args[safe: args.firstIndex(of: "--permission-mode").map { $0 + 1 } ?? -1], "default")
        // MCP servers are strictly none.
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        // A bare "{}" is rejected by the CLI at startup (verified on-host 2026-08-25),
        // which would break every triage run — the value must be a full config object.
        XCTAssertEqual(args[safe: args.firstIndex(of: "--mcp-config").map { $0 + 1 } ?? -1],
                       #"{"mcpServers":{}}"#)
        // Dangerous tools are denied; read-only tools allowed.
        let denied = args[safe: args.firstIndex(of: "--disallowedTools").map { $0 + 1 } ?? -1] ?? ""
        for tool in ["Bash", "Edit", "Write", "WebFetch", "WebSearch", "Task"] {
            XCTAssertTrue(denied.contains(tool), "\(tool) must be denied")
        }
        let allowed = args[safe: args.firstIndex(of: "--allowedTools").map { $0 + 1 } ?? -1] ?? ""
        XCTAssertEqual(allowed, "Read,Grep,Glob")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
