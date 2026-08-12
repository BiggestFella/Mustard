// Mirrors the coordinator's own platform gate — the types it logs
// (`SelectionRestorer.Outcome`, `TextInsertionOutcome`) are macOS-side.
#if os(macOS)
import Foundation
import os

/// Boundary instrumentation for the rewrite path. Same subsystem as the voice
/// suite so one predicate follows a whole interaction:
///
///     log stream --predicate 'subsystem == "com.cavehole.mustard"'
///
/// Selection text is NEVER logged — only its length. The whole point of an
/// on-device rewrite is that the user's words stay private, and a system log is
/// readable by anything on the machine.
public enum RewriteLog {
    public static let logger = Logger(subsystem: "com.cavehole.mustard", category: "rewrite")

    public static func snapshot(role: String?, subrole: String?, range: NSRange?, secure: Bool) {
        logger.info("""
            snapshot role=\(role ?? "nil", privacy: .public) \
            subrole=\(subrole ?? "nil", privacy: .public) \
            range=\(range.map { "\($0.location)+\($0.length)" } ?? "nil", privacy: .public) \
            secure=\(secure, privacy: .public)
            """)
    }

    public static func gate(_ refusal: RewriteRefusal?) {
        logger.info("gate=\(refusal.map { String(describing: $0) } ?? "admitted", privacy: .public)")
    }

    public static func read(rung: SelectionRung?, outcome: SelectionRead, characters: Int) {
        let described: String
        switch outcome {
        case .text: described = "text"
        case .empty: described = "empty"
        case .unreadable: described = "unreadable"
        }
        logger.info("""
            read rung=\(rung?.rawValue ?? "none", privacy: .public) \
            outcome=\(described, privacy: .public) chars=\(characters, privacy: .public)
            """)
    }

    public static func generated(intent: RewriteIntent, characters: Int, band: String) {
        logger.info("""
            generated intent=\(intent.rawValue, privacy: .public) \
            chars=\(characters, privacy: .public) band=\(band, privacy: .public)
            """)
    }

    public static func reassert(_ outcome: SelectionRestorer.Outcome) {
        logger.info("reassert=\(String(describing: outcome), privacy: .public)")
    }

    public static func wrote(_ outcome: TextInsertionOutcome) {
        logger.info("write=\(String(describing: outcome), privacy: .public)")
    }
}
#endif
