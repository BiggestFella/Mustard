import Foundation

/// The pure decision behind every note save — explicit ⌘S, save-on-switch, and
/// autosave-on-disappear all route through it. Three decisions live here so they're
/// named and unit-tested rather than inlined in the view:
///
///  1. **Dirty gate** — write only when `content` differs from the load/last-save
///     `baseline`. Switching between clean notes must never rewrite disk.
///  2. **Content-ownership gate** — write only when `content` belongs to `savedRef`.
///     A ⌘S in the one-runloop gap between `onChange(of: ref)` and the `.task`
///     reload still has the OLD note's text in @State while `currentRef` /
///     `savedRef` are already the NEW note. Writing then would persist stale
///     content over the new file (snapshot-before-save would catch it, but it
///     is not silent-safe).
///  3. **Baseline-advance rule** — advance the editor's in-view `diskText` baseline
///     only when the saved note is still the one on screen. A save-on-switch targets
///     the OLD ref while @State already holds the new note, so advancing then would
///     stamp the new note's baseline with the old note's content.
///
/// Generic over the ref type so this stays free of any Views dependency.
public enum NoteSaveFlow {
    public struct Plan: Equatable {
        /// Snapshot + write + reindex should run.
        public let shouldWrite: Bool
        /// The editor's baseline should be set to the written content. Only ever true
        /// alongside `shouldWrite`.
        public let shouldAdvanceBaseline: Bool

        public init(shouldWrite: Bool, shouldAdvanceBaseline: Bool) {
            self.shouldWrite = shouldWrite
            self.shouldAdvanceBaseline = shouldAdvanceBaseline
        }
    }

    /// - Parameters:
    ///   - content: the editor's current text (what a write would persist).
    ///   - baseline: the dirty-check baseline (content at load / last save).
    ///   - savedRef: the note being saved.
    ///   - currentRef: the note currently on screen.
    ///   - contentRef: the note that `content` / `baseline` belong to. Nil
    ///     while a reload is in flight — treated as "unknown owner, do not write".
    public static func plan<Ref: Equatable>(content: String, baseline: String,
                                            savedRef: Ref, currentRef: Ref,
                                            contentRef: Ref?) -> Plan {
        guard content != baseline else {
            return Plan(shouldWrite: false, shouldAdvanceBaseline: false)
        }
        guard let contentRef, contentRef == savedRef else {
            return Plan(shouldWrite: false, shouldAdvanceBaseline: false)
        }
        return Plan(shouldWrite: true, shouldAdvanceBaseline: savedRef == currentRef)
    }
}
