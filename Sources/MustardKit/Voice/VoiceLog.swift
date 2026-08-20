import os

/// Voice-suite diagnostics, shared by the capture, dictation and meeting
/// coordinators. `.notice` so it persists without enabling debug logging:
/// stream it with `log stream --predicate 'subsystem == "com.cavehole.mustard"'`.
/// The live speech path can only be observed on real hardware, so a capture
/// leaves a trail rather than requiring a rebuild to investigate.
///
/// Lives here, outside any `#if os(macOS)`, because the iOS companion compiles
/// the same coordinators (project.yml) and a logger has no platform plumbing.
let voiceLog = Logger(subsystem: "com.cavehole.mustard", category: "voice")
