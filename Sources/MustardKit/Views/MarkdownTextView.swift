import SwiftUI
import AppKit
import os

/// UI state for the caret-anchored slash menu (2b Task 7), published by the
/// coordinator through a binding so NoteEditorView can render the overlay.
/// `anchor` is in the editor overlay's coordinate space (top-left origin).
struct SlashMenuState: Equatable {
    var query: String
    /// The "/" + query text in the document — replaced wholesale on commit.
    /// Zero-length for the gutter's "+" path (pure insert at a block start).
    var triggerRange: NSRange
    var anchor: CGRect
    var selectedIndex: Int = 0
}

/// UI state for the floating inline-format toolbar (Phase 4 / BAK-253),
/// published by the coordinator exactly like `SlashMenuState`: `anchor` is in
/// the editor overlay's coordinate space (top-left origin), computed from the
/// SAME `overlayRect(forCharacterAt:)` geometry helper the slash menu anchors
/// with. No selection/format state is carried here — a button tap reads the
/// LIVE selection straight off the text view when it fires (`toggleInlineFormat`),
/// so this struct only needs to know WHERE to draw.
struct InlineFormatBarState: Equatable {
    var anchor: CGRect
}

/// UI state for the wikilink hover preview (Notes polish pack C), published by
/// the coordinator like `SlashMenuState`. `resolved` is nil for a dangling link
/// (the overlay shows a "Create note?" hint instead of an excerpt); `anchor` is
/// the hovered link's rect in the editor overlay's coordinate space.
struct WikilinkHoverState: Equatable {
    var target: String
    var resolved: NoteRef?
    var anchor: CGRect
}

/// UI state for the `[[` wikilink autocomplete popup (Notes polish pack D),
/// published by the coordinator exactly like `SlashMenuState`. `triggerRange`
/// covers "[[" + the typed query — replaced wholesale when a title is picked.
struct WikilinkAutocompleteState: Equatable {
    var query: String
    var triggerRange: NSRange
    var anchor: CGRect
    var selectedIndex: Int = 0
}

/// One moveable block's on-screen geometry (2b Task 9), in the editor overlay's
/// coordinate space. `index` matches `BlockReorder.move`'s moveable indexing
/// (frontmatter excluded), so the gutter can hand hit-test results straight through.
///
/// `kind` (Phase 3 / BAK-252 review fix) is the block's `BlockKind` at
/// publish time — data plumbing only, computed once here via
/// `NoteDecoration.blockKind` rather than re-derived by the view layer, so
/// `BlockGutterOverlay` can gate menu rows (e.g. hide "Turn into" for a
/// `.divider`) without owning any classification logic itself. Non-optional:
/// every `MarkdownBlockRect` is built from the FRONTMATTER-FILTERED moveable
/// list (`publishBlockRects`), and `blockKind` only ever returns `nil` for a
/// frontmatter block, so there's no real case here — `.paragraph` is a
/// defensive fallback, never an expected value.
struct MarkdownBlockRect: Equatable {
    let index: Int
    let rect: CGRect
    let kind: BlockKind
}

/// Imperative bridge from NoteEditorView's SwiftUI overlays (slash menu rows,
/// block gutter) into the text-view coordinator. SwiftUI can't hold the NSView;
/// this weak handle routes picks and drags into the ONE undo-safe splice path
/// without any overlay owning AppKit state. Main-thread by convention (every
/// caller is a SwiftUI action) — not @MainActor-annotated so `@State` in a
/// nonisolated view init can construct it.
final class MarkdownEditorProxy {
    weak var coordinator: MarkdownTextView.Coordinator?

    func pick(_ command: SlashCommand) { coordinator?.performSlashCommand(command) }
    func moveBlock(from: Int, to: Int) { coordinator?.moveBlock(from: from, to: to) }
    func openSlashMenu(atBlock index: Int) { coordinator?.openSlashMenu(atBlock: index) }

    // MARK: Wikilink autocomplete (Notes polish pack D)

    func pickWikilink(_ candidate: WikilinkAutocomplete.LinkCandidate) {
        coordinator?.performWikilinkPick(candidate)
    }
    func createWikilinkNote(_ query: String) { coordinator?.performWikilinkCreate(query) }

    // MARK: Block actions (Phase 3 / BAK-252 — gutter context menu)

    func turnIntoBlock(_ index: Int, target: BlockKind) { coordinator?.turnIntoBlock(at: index, target: target) }
    func duplicateBlock(_ index: Int) { coordinator?.duplicateBlock(at: index) }
    func deleteBlock(_ index: Int) { coordinator?.deleteBlock(at: index) }
    func moveBlockUp(_ index: Int) { coordinator?.moveBlockUp(at: index) }
    func moveBlockDown(_ index: Int) { coordinator?.moveBlockDown(at: index) }

    // MARK: Inline format toolbar (Phase 4 / BAK-253)

    func toggleInlineFormat(_ format: InlineFormat.Kind) { coordinator?.toggleInlineFormat(format) }
}

/// Custom attribute grounding the subpage-card drawing (2b Task 10). The card is
/// a `drawBackground` effect keyed off this attribute — deliberately NOT an
/// NSTextAttachment, which would replace characters and break the text == source
/// invariant. The value is the wikilink target (unused by drawing, useful in debug).
extension NSAttributedString.Key {
    static let mustardSubpageCard = NSAttributedString.Key("mustard.subpageCard")
    /// Grounds block-glyph drawing (checkbox / bullet / divider). Value is an
    /// `NSNumber` code (see `BlockGlyphCode`). Like `.mustardSubpageCard` this is
    /// draw-only: the raw `- [ ] `/`- `/`---` characters stay in the string
    /// (text == source) but are painted `.clear`, and `CardLayoutManager` draws
    /// the real glyph over their rect.
    static let mustardBlockGlyph = NSAttributedString.Key("mustard.blockGlyph")
}

/// The `.mustardBlockGlyph` attribute's integer codes (NSNumber-boxed — attribute
/// values must be objc objects, and `NoteDecoration.BlockGlyph` is a Swift enum).
enum BlockGlyphCode: Int {
    case checkboxUnchecked = 0
    case checkboxChecked = 1
    case bullet = 2
    case divider = 3
}

/// The live Craft-style editing surface for Notes (spec 2026-07-06, Phase 2a): one
/// always-editable NSTextView whose STRING is byte-identical to the note on disk.
/// Styling is applied purely as NSTextStorage ATTRIBUTES over `NoteDecoration`'s
/// spans — this view never rewrites text, so markdown-as-truth holds structurally.
/// The only text mutations 2b adds — slash-menu insertions and block reorders —
/// splice `SlashMenu.insertion` / `BlockReorder.move` output through
/// `insertText(_:replacementRange:)`, the canonical undoable channel.
///
/// `resolveWikilink` colours links (accent when the target resolves, tertiary when
/// it dangles); a click routes the raw target through `onWikilinkTap` — NotesView
/// keeps owning resolution and the create-from-dangling flow, exactly as it did for
/// the old preview.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var resolveWikilink: (String) -> NoteRef? = { _ in nil }
    var onWikilinkTap: (String) -> Void = { _ in }
    /// Slash menu presentation state, owned by NoteEditorView (which renders the
    /// overlay); the coordinator writes trigger detection into it and reads the
    /// selection for key handling. Defaults to an inert constant so callers that
    /// don't mount the menu never see it.
    var slashMenu: Binding<SlashMenuState?> = Binding<SlashMenuState?>.constant(nil)
    /// Floating inline-format toolbar presentation state (Phase 4 / BAK-253),
    /// owned by NoteEditorView the same way `slashMenu` is — the coordinator
    /// writes it on every selection change, NoteEditorView renders the overlay.
    var formatBar: Binding<InlineFormatBarState?> = Binding<InlineFormatBarState?>.constant(nil)
    /// Wikilink hover-preview state (polish pack C) — same ownership pattern.
    var hoverLink: Binding<WikilinkHoverState?> = Binding<WikilinkHoverState?>.constant(nil)
    /// `[[` autocomplete popup state (polish pack D) — same ownership pattern.
    var autocomplete: Binding<WikilinkAutocompleteState?> = Binding<WikilinkAutocompleteState?>.constant(nil)
    /// Same-project autocomplete candidates: display title + the filename stem
    /// links actually resolve by (passed by NoteEditorView from its entries; the
    /// coordinator ranks them via `WikilinkAutocomplete.rank`).
    var noteCandidates: [WikilinkAutocomplete.LinkCandidate] = []
    /// Creates a note titled by the autocomplete query WITHOUT navigating (the
    /// caret must stay put mid-typing) — NotesView's writeNote, threaded through.
    /// Returns the created relativePath so the splice can target ITS stem (a
    /// sanitized or collision-suffixed filename diverges from the typed title).
    var onCreateNote: (String) -> String? = { _ in nil }
    /// Moveable-block geometry publication for the hover gutter (2b Task 9).
    var onBlockRectsChange: ([MarkdownBlockRect]) -> Void = { _ in }
    var proxy: MarkdownEditorProxy? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, constructed EXPLICITLY (plan Decision 1). `NSTextView(frame:)`
        // vends a TextKit-2 view on macOS 13+, and any later access to
        // `.layoutManager` silently downgrades TK2 → TK1 mid-session — an entire
        // class of heisenbugs we opt out of by building the classic
        // storage → layout manager → container stack by hand. TK1's stable
        // glyph-range geometry is also what the 2b block gutter reads
        // (`boundingRect(forGlyphRange:in:)`).
        let textStorage = NSTextStorage()
        // CardLayoutManager only ADDS background drawing for subpage-card ranges;
        // all layout behaviour is inherited.
        let layoutManager = CardLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        let textView = FocusReportingTextView(frame: .zero, textContainer: textContainer)
        textView.focusCoordinator = context.coordinator

        // Attributes come from us, not the pasteboard — and every automatic
        // substitution is off because it would REWRITE markdown syntax under the
        // user's hands (smart quotes corrupt `"` in code and YAML).
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.font = Theme.NSFonts.reading
        textView.textColor = Theme.NSPalette.textPrimary
        textView.backgroundColor = Theme.NSPalette.bg
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 20, height: 14)
        // Our wikilink spans carry their own colour/underline; empty this so
        // AppKit's default link styling (system blue) doesn't paint over them.
        textView.linkTextAttributes = [NSAttributedString.Key.cursor: NSCursor.pointingHand]
        textView.typingAttributes = context.coordinator.baseAttributes

        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]

        textView.delegate = context.coordinator
        // Layout completion is the gutter's geometry heartbeat (Task 9): block
        // rects are only published once TK1 has settled the glyphs they map.
        layoutManager.delegate = context.coordinator
        context.coordinator.textView = textView
        proxy?.coordinator = context.coordinator

        context.coordinator.isProgrammaticUpdate = true
        textView.string = text
        context.coordinator.isProgrammaticUpdate = false
        context.coordinator.applyDecorations(scopedTo: nil)
        context.coordinator.refreshMarkerVisibility()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        // Scrolling moves every block rect in overlay space without triggering
        // layout — observe the clip view so the gutter tracks the scroll.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // First responder is claimed on the next runloop tick — never synchronously
        // during a SwiftUI view update (AppKit reentrancy warnings). ⌘S stays with
        // the SwiftUI Save button's window-level key equivalent, which fires before
        // the field editor.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        proxy?.coordinator = context.coordinator
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Write the binding into AppKit ONLY when it genuinely differs (external
        // replace: note switch, disk reload). Unconditional writes would round-trip
        // every keystroke SwiftUI → AppKit and teleport the caret.
        if textView.string != text {
            context.coordinator.isProgrammaticUpdate = true
            let selected = textView.selectedRange()
            textView.string = text
            // A programmatic replace means THIS view now shows a different
            // document (note switch / disk reload). The window's undo manager
            // still holds the previous document's operations — replaying one
            // against the new text passes shouldChangeText's length-only check
            // and splices old-note bytes into the new note, which save-on-switch
            // would then persist (deep-review panel finding). Drop the stack:
            // undo history is per-document, and this view just changed documents.
            textView.undoManager?.removeAllActions()
            // Preserve (clamp) the selection across the replace.
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
            context.coordinator.isProgrammaticUpdate = false
            // A new document invalidates every cached block range from the OLD
            // string — drop the partition snapshot, then recompute.
            context.coordinator.invalidateBlockCache()
            context.coordinator.applyDecorations(scopedTo: nil)
            context.coordinator.refreshMarkerVisibility()
            // A programmatic replace means the OLD selection's toolbar (if any)
            // is now anchored to a document that no longer exists here — and so
            // are any hover preview / autocomplete states.
            if formatBar.wrappedValue != nil { formatBar.wrappedValue = nil }
            context.coordinator.clearHover()
            if autocomplete.wrappedValue != nil { autocomplete.wrappedValue = nil }
        }

        // Backup focus grab for the rare case the window wasn't attached yet in
        // makeNSView's async hop.
        if !context.coordinator.didFocus, let window = textView.window {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.fullPassTask?.cancel()
        coordinator.clearHover()
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?
        /// Guards the binding echo: true while WE are mutating the text view, so
        /// `textDidChange` never round-trips a programmatic write into the binding.
        var isProgrammaticUpdate = false
        var didFocus = false
        var fullPassTask: Task<Void, Never>?
        /// True while a slash command or block move is splicing text — trigger
        /// detection and selection-change refresh stand down so the menu doesn't
        /// flicker open mid-splice.
        private var isPerformingEdit = false
        private var rectPublishScheduled = false
        private var lastPublishedRects: [MarkdownBlockRect] = []

        /// Phase 1 (BAK-250) focus tracking: true while THIS text view is the
        /// first responder. Driven by `setFocus(_:)`, called from
        /// `FocusReportingTextView`'s `become`/`resignFirstResponder` overrides —
        /// the ACTUAL focus signal, not `textDidBegin/EndEditing` (which fire on
        /// first/last keystroke, so a plain click-in or click-away would be
        /// missed). Distinct from `isProgrammaticUpdate`/`isPerformingEdit`, which
        /// guard OUR OWN writes, not the user's focus state. `nil` `focusedRange`
        /// (editor has no focus at all) hides every marker in the document.
        private var hasFocus = false

        /// BAK-254: the block partition is invariant across pure selection
        /// moves. Invalidate only when the source text changes so arrow-key
        /// / shift-select navigation never re-scans the document.
        private let blockCache = NoteDecoration.BlockCache()

        /// Large-note fallback (spec "never block typing"): above this many UTF-16
        /// units decoration is skipped entirely — plain editable text. 200k units
        /// ≈ a 200 KB ASCII note, far past anything hand-written; per-keystroke
        /// block scans and attribute passes stop being provably cheap there.
        static let plainTextFallbackLimit = 200_000

        private static let log = Logger(subsystem: "au.com.codeheroes.mustard", category: "notes")
        private var loggedFallback = false

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: Theme.NSFonts.reading, .foregroundColor: Theme.NSPalette.textPrimary]
        }

        // MARK: Text changes → binding + invalidation

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // Source changed — the cached partition is stale. Recompute once
            // below (caretBlock) and reuse for decorations + marker visibility.
            invalidateBlockCache()
            // Invalidation strategy (plan Task 4): a synchronous pass over ONLY the
            // block under the caret keeps keystroke latency flat; the debounced
            // full pass below catches edits that change block TOPOLOGY (typing a
            // ``` fence, deleting the blank line that separated two blocks, editing
            // frontmatter fences) which the scoped pass can't see.
            let block = caretBlock(in: textView)
            applyDecorations(scopedTo: block)
            // Recompute which markers are hidden (BAK-250): the block under the
            // caret is focused, so its markers reveal as you type ("**", "# ",
            // "> ") while every other block stays hidden. Cheap — it only
            // re-nulls glyphs whose hidden-state actually changed since the last
            // call (see `refreshMarkerVisibility`).
            refreshMarkerVisibility()
            scheduleFullPass()
            refreshSlashMenu()
            refreshAutocomplete()
            // Any edit collapses the selection (typing replaces it) — hide the
            // format toolbar the instant that happens, same "hides on typing"
            // requirement `refreshFormatBar`'s guard already encodes.
            refreshFormatBar()
            // An edit can delete/reflow the hovered link — the popover's anchor
            // and target are both stale.
            clearHover()
        }

        /// The partition block containing the caret in the NEW string.
        private func caretBlock(in textView: NSTextView) -> NoteDecoration.Block? {
            let blocks = currentBlocks(textView.string)
            let caret = textView.selectedRange().location
            return blocks.first { NSLocationInRange(caret, $0.range) } ?? blocks.last
        }

        func invalidateBlockCache() {
            blockCache.invalidate()
        }

        /// Cached `NoteDecoration.blocks` snapshot. First call after
        /// `invalidateBlockCache()` (or first load) scans; every later call
        /// with the same snapshot — caret moves, format-bar refresh, layout
        /// publish — is O(1).
        private func currentBlocks(_ source: String) -> [NoteDecoration.Block] {
            blockCache.blocks(for: source)
        }

        private func scheduleFullPass() {
            fullPassTask?.cancel()
            fullPassTask = Task { @MainActor [weak self] in
                // ~150 ms: settles between keystrokes, cancelled by the next edit.
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                self?.applyDecorations(scopedTo: nil)
                // Topology may have shifted every block's range since the last
                // full pass — force a fresh recompute rather than diffing.
                self?.refreshMarkerVisibility()
            }
        }

        // MARK: Decoration application (attributes ONLY — undo-safe)

        /// Applies `NoteDecoration` spans as text attributes — for one block (the
        /// per-keystroke fast path) or the whole document (nil).
        ///
        /// Undo safety: these are attribute-only edits written straight to
        /// `textStorage`, bypassing `shouldChangeText`/`didChangeText` — so they
        /// never enter NSTextView's undo stack and never dirty the SwiftUI binding.
        /// The `isProgrammaticUpdate` guard is belt-and-braces on top: if anything
        /// ever does re-fire `textDidChange` from here, it must not echo into the
        /// binding as a phantom user edit.
        func applyDecorations(scopedTo block: NoteDecoration.Block?) {
            guard let textView, let storage = textView.textStorage else { return }
            let source = textView.string
            let ns = source as NSString

            guard ns.length <= Self.plainTextFallbackLimit else {
                if !loggedFallback {
                    loggedFallback = true
                    Self.log.info("Note exceeds \(Self.plainTextFallbackLimit) UTF-16 units — decoration off, plain text editing")
                }
                return
            }
            loggedFallback = false

            let targets = block.map { [$0] } ?? currentBlocks(source)
            isProgrammaticUpdate = true
            storage.beginEditing()
            for target in targets {
                // Stale-range guard: a scoped block was computed from this same
                // string, but never trust a range against a storage we don't own.
                guard target.range.upperBound <= storage.length else { continue }
                storage.setAttributes(baseAttributes, range: target.range)
                // Layering order: line-level kinds ground the range, inline content
                // styles on top, markers de-emphasize last.
                for span in NoteDecoration.spans(source, in: target)
                    .sorted(by: { Self.priority($0.kind) < Self.priority($1.kind) }) {
                    apply(span, to: storage)
                }
                applyBlockGlyph(source, block: target, to: storage)
            }
            storage.endEditing()
            isProgrammaticUpdate = false
        }

        private static func priority(_ kind: NoteDecoration.Kind) -> Int {
            switch kind {
            case .frontmatter, .codeBlock, .heading, .listMarker, .subpageCard: return 0
            case .bold, .italic, .inlineCode, .wikilink, .strikethrough, .highlight: return 1
            case .marker: return 2
            }
        }

        private func apply(_ span: NoteDecoration.Span, to storage: NSTextStorage) {
            let range = span.range
            switch span.kind {
            case .frontmatter:
                storage.addAttributes([.font: Theme.NSFonts.frontmatter,
                                       .foregroundColor: Theme.NSPalette.textTertiary], range: range)
            case .heading(let level):
                storage.addAttributes([.font: Self.headingFont(level),
                                       .foregroundColor: Theme.NSPalette.textPrimary], range: range)
            case .marker:
                storage.addAttributes([.font: Theme.NSFonts.marker,
                                       .foregroundColor: Theme.NSPalette.textTertiary], range: range)
            case .bold:
                storage.addAttribute(.font, value: Theme.NSFonts.readingBold, range: range)
            case .italic:
                storage.addAttribute(.font, value: Theme.NSFonts.readingItalic, range: range)
            case .inlineCode:
                storage.addAttributes([.font: Theme.NSFonts.code,
                                       .backgroundColor: Theme.NSPalette.surface], range: range)
            case .strikethrough:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .strikethroughColor: Theme.NSPalette.strikethrough], range: range)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: Theme.NSPalette.highlightBg, range: range)
            case .codeBlock:
                storage.addAttributes([.font: Theme.NSFonts.code,
                                       .backgroundColor: Theme.NSPalette.surface], range: range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: Theme.NSPalette.textTertiary, range: range)
            case .wikilink(let target, _):
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: parent.resolveWikilink(target) != nil
                        ? Theme.NSPalette.accent : Theme.NSPalette.textTertiary,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .cursor: NSCursor.pointingHand,
                ]
                if let url = WikilinkURL.url(for: target) { attributes[.link] = url }
                storage.addAttributes(attributes, range: range)
            case .subpageCard(let target):
                // Attribute-only ground for CardLayoutManager.drawBackground —
                // no character is added or replaced (no NSTextAttachment).
                storage.addAttribute(NSAttributedString.Key.mustardSubpageCard,
                                     value: target, range: range)
            }
        }

        private static func headingFont(_ level: Int) -> NSFont {
            switch level {
            case 1: return Theme.NSFonts.docH1
            case 2: return Theme.NSFonts.docH2
            default: return Theme.NSFonts.docH3
            }
        }

        /// Block-glyph prefixes (checkbox / bullet / divider): stamp the drawing
        /// attribute and paint the raw `- [ ] `/`- `/`---` characters `.clear` so
        /// they hold their column (keeping the caret hit-testable — unlike the
        /// nulled text markers) while `CardLayoutManager` draws the real glyph over
        /// them. Quote is intentionally skipped here: its `> ` is already a hidden
        /// text marker (nulled by `markerVisibility`), so a quote renders as
        /// flush-left text today; a dedicated quote treatment is a later touch.
        private func applyBlockGlyph(_ source: String, block: NoteDecoration.Block,
                                     to storage: NSTextStorage) {
            guard let (markerRange, glyph) = NoteDecoration.blockGlyph(source, of: block),
                  markerRange.upperBound <= storage.length else { return }
            let code: BlockGlyphCode
            switch glyph {
            case .checkbox(let checked): code = checked ? .checkboxChecked : .checkboxUnchecked
            case .bullet: code = .bullet
            case .divider: code = .divider
            case .quote: return
            }
            storage.addAttribute(NSAttributedString.Key.mustardBlockGlyph,
                                 value: NSNumber(value: code.rawValue), range: markerRange)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: markerRange)
        }

        // MARK: Marker visibility (Phase 1 / BAK-250 — Craft-style focus reveal)

        /// The character ranges whose markers are currently hidden. Read by the
        /// `shouldGenerateGlyphs` delegate below, which gives every glyph in these
        /// ranges the `.null` glyph property — a null glyph both draws NOTHING and
        /// takes ZERO width, so hidden syntax truly disappears and the surrounding
        /// text reflows into its place (a heading's title slides left to where the
        /// "# " was), which is exactly the Craft behaviour.
        ///
        /// This replaces the original `setNotShownAttribute` approach (2026-07-12
        /// fix, Leon's eye-check): that API (a) left the hidden glyph's advance
        /// width in place, so markers would only stop *drawing* while still holding
        /// their column — never a real reflow — and (b) is a property of
        /// already-generated glyphs, so it was silently wiped every time
        /// `applyDecorations` set a font attribute and the glyphs regenerated. Net
        /// effect in the running app: markers never hid at all. Deciding
        /// visibility at glyph-GENERATION time (here) is regeneration-safe by
        /// construction — regeneration just re-consults this set.
        ///
        /// The underlying text storage and its attributes are never touched, so
        /// copy/paste and Save still see the full markdown; only which glyphs get
        /// laid out changes.
        private var hiddenMarkerRanges: [NSRange] = []
        /// `hiddenMarkerRanges` flattened for the delegate hook: O(log n) membership
        /// instead of an O(ranges) scan per character during glyph generation.
        private var hiddenMarkerCharacters = IndexSet()
        /// Document length the hidden set was computed against. Glyph generation can
        /// run for the edited range BEFORE `textDidChange` refreshes the set; a
        /// length mismatch means the indexes are stale for THIS pass, so the hook
        /// stands down (markers briefly visible beats nulling the wrong characters).
        private var hiddenMarkerDocLength = 0

        /// Recompute which markers are hidden, then, if the set changed, force the
        /// affected glyphs to regenerate so the `shouldGenerateGlyphs` delegate
        /// re-applies (or lifts) their `.null` property. Recomputes the whole set
        /// from the pure `markerVisibility` decision each time — cheap for
        /// hand-written notes, and there is no cross-call glyph-flag state to keep
        /// in sync. Driven by text change / load / doc-replace, never by caret
        /// movement (hiding is focus-independent — see below).
        func refreshMarkerVisibility() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let source = textView.string
            let ns = source as NSString

            // Large-note fallback: no hiding, plain editable text (matches the
            // decoration + block-rect fallbacks).
            guard ns.length <= Self.plainTextFallbackLimit else {
                if !hiddenMarkerRanges.isEmpty {
                    let stale = hiddenMarkerRanges
                    hiddenMarkerRanges = []
                    hiddenMarkerCharacters = IndexSet()
                    hiddenMarkerDocLength = ns.length
                    invalidateGlyphs(for: stale, ns: ns, layoutManager: layoutManager)
                }
                return
            }

            // "Always hidden" (Leon, 2026-07-12): markers never reveal, not even on
            // the line being edited — the Craft/Typora model, not Bear's
            // reveal-on-active-line. `focusedRange: nil` hides EVERY block's
            // markers; the raw `# `/`**`/`` ` `` still live in the file
            // (markdown-as-truth) and the caret can traverse them to edit, they
            // just never draw. Hiding therefore depends only on the text, so this
            // runs on text change / load, never on caret movement.
            let newHidden = NoteDecoration.markerVisibility(source, blocks: currentBlocks(source),
                                                            focusedRange: nil)
                .hidden
                .filter { $0.length > 0 && $0.upperBound <= ns.length }

            guard newHidden != hiddenMarkerRanges else {
                // Same ranges, but the doc length may have changed around them (an
                // edit that didn't touch any marker) — keep the staleness stamp
                // current so the delegate hook doesn't stand down forever.
                hiddenMarkerDocLength = ns.length
                return
            }
            // Regenerate glyphs for everything whose hidden-state may have flipped:
            // the union of what WAS hidden and what is NOW hidden. The set/stamp are
            // assigned BEFORE invalidation so a synchronous re-entry into the
            // delegate hook sees consistent state.
            let affected = hiddenMarkerRanges + newHidden
            hiddenMarkerRanges = newHidden
            var flattened = IndexSet()
            for range in newHidden {
                flattened.insert(integersIn: range.location..<range.upperBound)
            }
            hiddenMarkerCharacters = flattened
            hiddenMarkerDocLength = ns.length
            invalidateGlyphs(for: affected, ns: ns, layoutManager: layoutManager)
        }

        /// Force glyph regeneration + relayout over the given ranges so the
        /// `shouldGenerateGlyphs` delegate re-runs against the updated
        /// `hiddenMarkerRanges`. Ranges past the current length are clamped out
        /// defensively (they can only be stale pre-edit ranges).
        private func invalidateGlyphs(for ranges: [NSRange], ns: NSString,
                                      layoutManager: NSLayoutManager) {
            for range in ranges {
                guard range.length > 0, range.upperBound <= ns.length else { continue }
                layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0,
                                               actualCharacterRange: nil)
                layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            }
        }

        /// Glyph-generation hook: any character in a `hiddenMarkerRanges` range
        /// gets the `.null` glyph property (no draw, no width → reflow). Returning
        /// 0 when nothing is hidden lets the layout manager use its own defaults —
        /// the zero-cost common path.
        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes charIndexes: UnsafePointer<Int>,
                           font: NSFont,
                           forGlyphRange glyphRange: NSRange) -> Int {
            guard !hiddenMarkerCharacters.isEmpty,
                  hiddenMarkerDocLength == (layoutManager.textStorage?.length ?? 0),
                  glyphRange.length > 0
            else { return 0 }

            // Cheap no-op pre-check: character indexes are monotonic within a
            // generation chunk, so a chunk whose span misses the hidden set (the
            // common case) skips the buffer copy entirely.
            let count = glyphRange.length
            let spanStart = charIndexes[0]
            let spanEnd = charIndexes[count - 1]
            guard spanEnd >= spanStart,
                  hiddenMarkerCharacters.intersects(integersIn: spanStart...spanEnd)
            else { return 0 }

            var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
            var touched = false
            for i in 0..<count {
                if hiddenMarkerCharacters.contains(charIndexes[i]) {
                    newProps[i] = .null
                    touched = true
                } else {
                    newProps[i] = props[i]
                }
            }
            guard touched else { return 0 }
            layoutManager.setGlyphs(glyphs, properties: &newProps, characterIndexes: charIndexes,
                                    font: font, forGlyphRange: glyphRange)
            return count
        }

        /// The real first-responder signal (from `FocusReportingTextView`). Markers
        /// are always hidden regardless of focus (see `refreshMarkerVisibility`), so
        /// this only governs the format toolbar — which should never hover while the
        /// editor isn't the first responder.
        func setFocus(_ focused: Bool) {
            guard hasFocus != focused else { return }
            hasFocus = focused
            refreshFormatBar()
        }

        /// A click inside a checkbox's marker region toggles `[ ]` ⇄ `[x]` in the
        /// source (via the undo-safe splice) instead of placing a caret. Returns
        /// true when it handled the click so the text view skips its default
        /// mouse handling. `viewPoint` is in the text view's coordinate space.
        func handleCheckboxClick(at viewPoint: CGPoint, layoutManager: NSLayoutManager,
                                 textContainer: NSTextContainer, containerOrigin: CGPoint) -> Bool {
            guard let textView else { return false }
            let source = textView.string
            guard (source as NSString).length <= Self.plainTextFallbackLimit else { return false }
            let containerPoint = CGPoint(x: viewPoint.x - containerOrigin.x,
                                         y: viewPoint.y - containerOrigin.y)
            guard layoutManager.numberOfGlyphs > 0 else { return false }
            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
            guard glyphIndex < layoutManager.numberOfGlyphs else { return false }
            // `glyphIndex(for:)` snaps to the NEAREST glyph, so a click in the
            // blank area below the last line resolves to that line's last glyph.
            // Reject clicks outside the actual line box so clicking below a
            // final checkbox line can't silently toggle it.
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            guard NSPointInRect(containerPoint, fragment) else { return false }
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            let blocks = currentBlocks(source)
            guard let block = blocks.first(where: { NSLocationInRange(charIndex, $0.range) }),
                  let (markerRange, glyph) = NoteDecoration.blockGlyph(source, of: block),
                  case .checkbox = glyph,
                  NSLocationInRange(charIndex, markerRange),
                  let result = CheckboxToggle.toggled(source, at: charIndex)
            else { return false }

            textView.window?.makeFirstResponder(textView)
            applyWholeDocumentSplice(newSource: result.source, selection: result.selection)
            return true
        }

        // MARK: Link clicks

        /// Wikilink clicks route to the host's existing navigate / create-from-
        /// dangling flow (save-on-switch still fires because navigation goes
        /// through NotesView's `selected`). Foreign URLs fall through to AppKit.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, let target = WikilinkURL.target(from: url) else { return false }
            parent.onWikilinkTap(target)
            return true
        }

        // MARK: Wikilink hover preview (Notes polish pack C)

        /// Debounce before the popover shows — long enough that sweeping the mouse
        /// across a note never flashes previews, short enough to feel intentional.
        private static let hoverDelayNanos: UInt64 = 350_000_000
        private var hoverTask: Task<Void, Never>?
        /// The link target currently under the mouse (pre-debounce) — dedupes
        /// mouseMoved streams so we only re-arm the debounce on target CHANGE.
        private var hoverCandidate: (target: String, location: Int)?

        /// Called from the text view's mouseMoved tracking. Hit-tests the `.link`
        /// attribute under the pointer (the decoration pass owns which characters
        /// are links, so this never re-parses markdown) and arms the debounced
        /// publish. Anything that isn't a wikilink clears the state.
        func handleHoverMove(at viewPoint: CGPoint) {
            guard let textView, let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let storage = textView.textStorage,
                  (textView.string as NSString).length <= Self.plainTextFallbackLimit
            else { clearHover(); return }

            let origin = textView.textContainerOrigin
            let containerPoint = CGPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
            guard layoutManager.numberOfGlyphs > 0 else { clearHover(); return }
            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
            guard glyphIndex < layoutManager.numberOfGlyphs else { clearHover(); return }
            // Same nearest-glyph guard as checkbox clicks: only count the pointer
            // as "on" the link when it's inside the line fragment's box.
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            guard NSPointInRect(containerPoint, fragment) else { clearHover(); return }
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard charIndex < storage.length else { clearHover(); return }

            var linkRange = NSRange(location: 0, length: 0)
            guard let url = storage.attribute(.link, at: charIndex,
                                              longestEffectiveRange: &linkRange,
                                              in: NSRange(location: 0, length: storage.length)) as? URL,
                  let target = WikilinkURL.target(from: url)
            else { clearHover(); return }

            // Same link as the armed candidate (or the shown popover) — nothing to do.
            if hoverCandidate?.target == target, hoverCandidate?.location == linkRange.location { return }
            hoverCandidate = (target, linkRange.location)
            hoverTask?.cancel()
            let anchorLocation = linkRange.location
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Coordinator.hoverDelayNanos)
                guard !Task.isCancelled, let self, self.hoverCandidate?.target == target else { return }
                self.parent.hoverLink.wrappedValue = WikilinkHoverState(
                    target: target,
                    resolved: self.parent.resolveWikilink(target),
                    anchor: self.overlayRect(forCharacterAt: anchorLocation) ?? CGRect.zero
                )
            }
        }

        /// Cancels any pending publish and hides the popover. Called on mouse-exit,
        /// scroll, text change, and whenever the pointer leaves link glyphs.
        func clearHover() {
            hoverTask?.cancel()
            hoverTask = nil
            hoverCandidate = nil
            if parent.hoverLink.wrappedValue != nil { parent.hoverLink.wrappedValue = nil }
        }

        // MARK: Slash menu — trigger detection (2b Task 7)

        /// Recomputes the slash-menu state from the caret's line prefix. Runs on
        /// every text change; also on selection change WHILE OPEN (so arrowing or
        /// clicking out of the trigger closes it) — but a pure selection change
        /// never OPENS the menu, so clicking into old "/query" text is calm.
        private func refreshSlashMenu(allowOpen: Bool = true) {
            guard !isPerformingEdit else { return }
            guard let textView else { return }
            let wasOpen = parent.slashMenu.wrappedValue != nil
            guard allowOpen || wasOpen else { return }
            // IME: never open or keep the menu while marked text is live —
            // a splice would steal the composition. Close if it was open.
            guard SlashMenu.allowsInteraction(hasMarkedText: textView.hasMarkedText()) else {
                if wasOpen { parent.slashMenu.wrappedValue = nil }
                return
            }

            let selection = textView.selectedRange()
            let ns = textView.string as NSString
            guard selection.length == 0, selection.location <= ns.length,
                  let query = triggerQuery(ns, caret: selection.location),
                  !SlashMenu.items(query: query.text).isEmpty
            else {
                if wasOpen { parent.slashMenu.wrappedValue = nil }
                return
            }

            let previous = parent.slashMenu.wrappedValue
            let keptIndex = (previous?.query == query.text) ? (previous?.selectedIndex ?? 0) : 0
            let itemCount = SlashMenu.items(query: query.text).count
            parent.slashMenu.wrappedValue = SlashMenuState(
                query: query.text,
                triggerRange: query.range,
                anchor: overlayRect(forCharacterAt: query.range.location) ?? CGRect.zero,
                selectedIndex: min(keptIndex, itemCount - 1)
            )
        }

        /// The active trigger at the caret: `SlashMenu.activeQuery` over the line
        /// prefix, plus the trigger's document range ("/"+query, from line start).
        private func triggerQuery(_ ns: NSString, caret: Int) -> (text: String, range: NSRange)? {
            let start = lineStart(ns, before: caret)
            let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
            guard let query = SlashMenu.activeQuery(linePrefix: prefix) else { return nil }
            return (text: query, range: NSRange(location: start, length: caret - start))
        }

        /// Manual backward scan for the line start — sidesteps `getLineStart`'s
        /// undocumented caret-at-end edge (caret == length is routine here).
        private func lineStart(_ ns: NSString, before location: Int) -> Int {
            var index = min(location, ns.length)
            while index > 0 {
                let unit = ns.character(at: index - 1)
                if unit == 10 || unit == 13 { break }   // \n or \r
                index -= 1
            }
            return index
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isPerformingEdit, !isProgrammaticUpdate else { return }
            // Marker visibility is NOT refreshed here: under the "always hidden"
            // policy (Leon, 2026-07-12) hiding no longer depends on where the
            // caret is, only on the text, so a pure selection move can't change
            // it — refreshing happens on text change / load / doc-replace instead.
            // The format bar still tracks the selection, but reads the cached
            // partition (BAK-254) rather than re-scanning `blocks(source)`.
            refreshFormatBar()

            // Close-only paths: never open on a pure selection move (allowOpen false).
            if parent.slashMenu.wrappedValue != nil { refreshSlashMenu(allowOpen: false) }
            if parent.autocomplete.wrappedValue != nil { refreshAutocomplete(allowOpen: false) }
        }

        /// ↑/↓/⏎/Esc are intercepted ONLY while the slash menu or the wikilink
        /// autocomplete is open — never steal arrows or return during normal
        /// editing (plan risk register). The two menus are mutually exclusive
        /// (`refreshAutocomplete` won't open beside the slash menu), so the slash
        /// branch running first is priority in name only.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if var menu = parent.slashMenu.wrappedValue {
                // Marked-text Return/arrows belong to the IME, not the menu.
                guard SlashMenu.allowsInteraction(hasMarkedText: textView.hasMarkedText()) else {
                    return false
                }
                let items = SlashMenu.items(query: menu.query)
                guard !items.isEmpty else { return false }

                if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    menu.selectedIndex = min(menu.selectedIndex + 1, items.count - 1)
                    parent.slashMenu.wrappedValue = menu
                    return true
                }
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    menu.selectedIndex = max(menu.selectedIndex - 1, 0)
                    parent.slashMenu.wrappedValue = menu
                    return true
                }
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    performSlashCommand(items[min(menu.selectedIndex, items.count - 1)])
                    return true
                }
                if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    parent.slashMenu.wrappedValue = nil
                    return true
                }
                return false
            }

            if var menu = parent.autocomplete.wrappedValue {
                let candidates = WikilinkAutocomplete.rank(query: menu.query,
                                                           candidates: parent.noteCandidates)
                let rowCount = autocompleteRowCount(for: menu.query)
                guard rowCount > 0 else { return false }

                if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    menu.selectedIndex = min(menu.selectedIndex + 1, rowCount - 1)
                    parent.autocomplete.wrappedValue = menu
                    return true
                }
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    menu.selectedIndex = max(menu.selectedIndex - 1, 0)
                    parent.autocomplete.wrappedValue = menu
                    return true
                }
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    let index = min(menu.selectedIndex, rowCount - 1)
                    if index < candidates.count {
                        performWikilinkPick(candidates[index])
                    } else {
                        performWikilinkCreate(menu.query)   // the trailing Create row
                    }
                    return true
                }
                if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    parent.autocomplete.wrappedValue = nil
                    return true
                }
                return false
            }

            return false
        }

        // MARK: Slash menu — execution (the undo-safe splice)

        /// Commits one slash command: replaces the trigger text with the command's
        /// byte-pinned template via `insertText(_:replacementRange:)` — the ONE
        /// channel every 2b text mutation uses, so it lands in the undo stack as a
        /// single user-visible operation and fires `textDidChange` → binding →
        /// dirty dot, exactly like typing.
        func performSlashCommand(_ command: SlashCommand) {
            guard let textView, let menu = parent.slashMenu.wrappedValue else { return }
            guard SlashMenu.allowsInteraction(hasMarkedText: textView.hasMarkedText()) else { return }

            // Sub-page inserts a DANGLING [[Untitled]] link — no file is created
            // here. The deep-review panel showed why: creating the file before an
            // undoable splice makes ⌘Z asymmetric (text reverts, file persists)
            // and every undo→retry cycle minted an orphan "Untitled N". A slash
            // command is now pure text; the existing confirmed
            // create-from-dangling flow (click → "Create note?") owns creation.
            let insertion = SlashMenu.insertion(for: command.kind, noteTitle: nil)
            isPerformingEdit = true
            // Isolate from adjacent typing so ⌘Z removes exactly this insertion.
            textView.breakUndoCoalescing()
            textView.insertText(insertion.text, replacementRange: menu.triggerRange)
            textView.breakUndoCoalescing()
            textView.setSelectedRange(NSRange(location: menu.triggerRange.location + insertion.caretOffset,
                                              length: 0))
            isPerformingEdit = false
            parent.slashMenu.wrappedValue = nil
            textView.window?.makeFirstResponder(textView)
        }

        /// The gutter's "+" path: open the menu anchored at a block's start with an
        /// empty query and a zero-length trigger (a pure insert — commit splices at
        /// the block's first character, which is always a line start).
        func openSlashMenu(atBlock index: Int) {
            guard let textView else { return }
            let moveable = currentBlocks(textView.string).filter { !$0.isFrontmatter }
            guard index >= 0, index < moveable.count else { return }
            let location = moveable[index].range.location
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            parent.slashMenu.wrappedValue = SlashMenuState(
                query: "",
                triggerRange: NSRange(location: location, length: 0),
                anchor: overlayRect(forCharacterAt: location) ?? CGRect.zero,
                selectedIndex: 0
            )
        }

        // MARK: Wikilink autocomplete (Notes polish pack D)

        /// Recomputes the `[[` autocomplete state from the caret — the same
        /// open-on-text-change / close-only-on-selection-change contract as
        /// `refreshSlashMenu`. Never open alongside the slash menu (the slash
        /// trigger requires a line starting "/", so the two can't both be live;
        /// the guard is belt-and-braces).
        private func refreshAutocomplete(allowOpen: Bool = true) {
            guard !isPerformingEdit else { return }
            guard let textView else { return }
            let wasOpen = parent.autocomplete.wrappedValue != nil
            guard allowOpen || wasOpen else { return }

            let selection = textView.selectedRange()
            guard selection.length == 0,
                  parent.slashMenu.wrappedValue == nil,
                  let query = WikilinkAutocomplete.activeQuery(text: textView.string,
                                                               caretUTF16: selection.location),
                  autocompleteRowCount(for: query.text) > 0
            else {
                if wasOpen { parent.autocomplete.wrappedValue = nil }
                return
            }

            let previous = parent.autocomplete.wrappedValue
            let keptIndex = (previous?.query == query.text) ? (previous?.selectedIndex ?? 0) : 0
            let rowCount = autocompleteRowCount(for: query.text)
            parent.autocomplete.wrappedValue = WikilinkAutocompleteState(
                query: query.text,
                triggerRange: query.range,
                anchor: overlayRect(forCharacterAt: query.range.location) ?? CGRect.zero,
                selectedIndex: min(keptIndex, rowCount - 1)
            )
        }

        /// Total keyboard rows: ranked candidates + the trailing "Create" row
        /// (shown only for a non-blank query). One count, owned here, so the
        /// coordinator's ↑/↓/⏎ and the overlay's rendering can't drift apart —
        /// `WikilinkAutocompleteView` derives its rows from the same functions.
        private func autocompleteRowCount(for query: String) -> Int {
            let candidates = WikilinkAutocomplete.rank(query: query, candidates: parent.noteCandidates)
            let hasCreateRow = !query.trimmingCharacters(in: .whitespaces).isEmpty
            return candidates.count + (hasCreateRow ? 1 : 0)
        }

        /// Commits a pick: replaces the "[["+query trigger with the candidate's
        /// STEM-targeted link (`[[stem]]` / `[[stem|title]]` — links resolve by
        /// filename stem, never by display title) through the SAME undo-safe
        /// channel as slash commands.
        func performWikilinkPick(_ candidate: WikilinkAutocomplete.LinkCandidate) {
            guard let textView, let state = parent.autocomplete.wrappedValue else { return }
            let insertion = WikilinkAutocomplete.insertion(for: candidate)
            isPerformingEdit = true
            textView.breakUndoCoalescing()
            textView.insertText(insertion, replacementRange: state.triggerRange)
            textView.breakUndoCoalescing()
            textView.setSelectedRange(NSRange(
                location: state.triggerRange.location + (insertion as NSString).length, length: 0))
            isPerformingEdit = false
            parent.autocomplete.wrappedValue = nil
            textView.window?.makeFirstResponder(textView)
        }

        /// The "Create '<query>'" row: creates the note (no navigation — the caret
        /// must stay here) and links to it BY THE CREATED FILE'S STEM — sanitization
        /// or a collision suffix can make the filename diverge from the typed title,
        /// and splicing the raw title would then link the WRONG (pre-existing) note.
        /// File creation IS outside the undo group, same trade-off as
        /// create-from-dangling: ⌘Z reverts the text and the created note dangles.
        func performWikilinkCreate(_ query: String) {
            let title = query.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            let createdPath = parent.onCreateNote(title)
            let stem = createdPath.map(WikilinkAutocomplete.stem(ofPath:)) ?? title
            performWikilinkPick(WikilinkAutocomplete.LinkCandidate(title: title, stem: stem))
        }

        // MARK: Inline format toolbar (Phase 4 / BAK-253 — floating selection toolbar)

        /// Recomputes the format-toolbar's presentation state from the current
        /// selection. Shows only while THIS view has focus, the selection is
        /// non-empty, and `InlineFormat.isSingleBlockSelection` agrees the
        /// selection sits inside one (non-frontmatter) block — the same "single
        /// block" rule `InlineFormat.toggle` itself enforces before formatting,
        /// read here from the one function that owns it rather than
        /// re-derived. Hides on selection collapse (caret-only) and on any
        /// edit (`textDidChange` calls this too) per the spec's "hides on
        /// selection collapse/typing".
        private func refreshFormatBar() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            guard hasFocus, !isPerformingEdit, !isProgrammaticUpdate,
                  InlineFormat.isSingleBlockSelection(blocks: currentBlocks(textView.string),
                                                      selection: selection)
            else {
                if parent.formatBar.wrappedValue != nil { parent.formatBar.wrappedValue = nil }
                return
            }
            parent.formatBar.wrappedValue = InlineFormatBarState(
                anchor: overlayRect(forCharacterAt: selection.location) ?? CGRect.zero
            )
        }

        /// Applies one inline-format toggle from the floating toolbar. Pure
        /// decision in `InlineFormat.toggle` (wrap/unwrap/no-op — reads the
        /// LIVE selection, never a stale copy); this method only resolves the
        /// current selection and applies the result through the SAME whole-
        /// document splice channel `BlockTransform`'s four operations already
        /// use (`applyWholeDocumentSplice`) rather than `performSlashCommand`'s
        /// narrower `replacementRange:` channel. `InlineFormat.toggle` returns a
        /// WHOLE rewritten source (same shape as every `BlockTransform`
        /// function), not a computed sub-range delta — deriving a minimal diff
        /// range from two full strings would need its own diffing pass for no
        /// real benefit, whereas the existing whole-document channel already
        /// gives one undo step AND the full decoration + marker-visibility
        /// recompute this toggle needs (adding/removing delimiters can flip
        /// which markers are hideable in the touched block).
        func toggleInlineFormat(_ format: InlineFormat.Kind) {
            guard let textView else { return }
            let selection = textView.selectedRange()
            guard let result = InlineFormat.toggle(textView.string, selection: selection, format: format)
            else { return }
            applyWholeDocumentSplice(newSource: result.source, selection: result.selection)
        }

        // MARK: Block reorder (2b Task 9)

        /// Applies `BlockReorder.move` as ONE undoable edit through the shared
        /// whole-document splice channel (`applyWholeDocumentSplice`) — see that
        /// method's doc for the undo-grouping/decoration/scroll mechanics. Caret
        /// is clamped to its OLD location (a reorder doesn't ask the caret to
        /// follow the moved block — unlike the Phase 3 block-actions menu below,
        /// which computes a specific destination selection per action).
        func moveBlock(from: Int, to: Int) {
            guard let textView else { return }
            let moved = BlockReorder.move(textView.string, from: from, to: to)
            let savedSelection = textView.selectedRange()
            applyWholeDocumentSplice(newSource: moved,
                                     selection: NSRange(location: savedSelection.location, length: 0))
        }

        // MARK: Block actions (Phase 3 / BAK-252 — "turn into" + gutter context menu)

        /// Resolves a gutter/menu `index` (moveable-block indexing — the same
        /// convention `MarkdownBlockRect.index` and `BlockReorder.move`'s
        /// `from`/`to` already use) to the CURRENT `NoteDecoration.Block` it
        /// names. `nil` for a stale index (block count changed since the caller
        /// last read `MarkdownBlockRect`s) rather than acting on the wrong block.
        private func moveableBlock(at index: Int) -> NoteDecoration.Block? {
            guard let textView else { return nil }
            let moveable = currentBlocks(textView.string).filter { !$0.isFrontmatter }
            guard index >= 0, index < moveable.count else { return nil }
            return moveable[index]
        }

        /// "Turn into" — the gutter context menu's first section. Pure logic in
        /// `BlockTransform.turnInto` decides content/selection; this method only
        /// resolves the index and applies the result through the one undo-safe
        /// splice channel every 2b/Phase-3 mutation uses.
        func turnIntoBlock(at index: Int, target: BlockKind) {
            guard let textView, let block = moveableBlock(at: index),
                  let result = BlockTransform.turnInto(textView.string, block: block, target: target)
            else { return }
            applyWholeDocumentSplice(newSource: result.source, selection: result.selection)
        }

        /// "Actions" section — Duplicate.
        func duplicateBlock(at index: Int) {
            guard let textView, let block = moveableBlock(at: index),
                  let result = BlockTransform.duplicate(textView.string, block: block)
            else { return }
            applyWholeDocumentSplice(newSource: result.source, selection: result.selection)
        }

        /// "Actions" section — Delete.
        func deleteBlock(at index: Int) {
            guard let textView, let block = moveableBlock(at: index),
                  let result = BlockTransform.delete(textView.string, block: block)
            else { return }
            applyWholeDocumentSplice(newSource: result.source, selection: result.selection)
        }

        /// "Actions" section — Move up. Delegates the actual reorder to
        /// `BlockTransform.moveUp` (which itself delegates to
        /// `BlockReorder.move` — no index-math reimplementation anywhere), but
        /// unlike the gutter's drag path (`moveBlock`, above), the caret follows
        /// the moved block to its new position (`BlockTransform`'s computed
        /// selection) rather than staying at its old document offset — the menu
        /// action reads as "move THIS block", so the caret should stay with it.
        func moveBlockUp(at index: Int) {
            guard let textView, let block = moveableBlock(at: index),
                  let result = BlockTransform.moveUp(textView.string, block: block)
            else { return }
            applyWholeDocumentSplice(newSource: result.source, selection: result.selection)
        }

        /// "Actions" section — Move down (see `moveBlockUp`'s doc).
        func moveBlockDown(at index: Int) {
            guard let textView, let block = moveableBlock(at: index),
                  let result = BlockTransform.moveDown(textView.string, block: block)
            else { return }
            applyWholeDocumentSplice(newSource: result.source, selection: result.selection)
        }

        /// The ONE undo-safe whole-document splice channel: every mutation that
        /// can't stay caret-scoped (`moveBlock`, and every Phase 3 block action
        /// above) funnels through here. `insertText(_:replacementRange:)` is the
        /// same canonical channel slash insertions use, wrapped in an explicit
        /// undo group and bracketed by `breakUndoCoalescing` so ⌘Z reverts in
        /// exactly one step, never merged with surrounding typing. Always a FULL
        /// decoration + marker-visibility recompute (never the caret-scoped
        /// incremental path) — these splices can move, retype, duplicate, or
        /// remove whole blocks, invalidating ranges the incremental path assumes
        /// are stable. `selection` is clamped to the new document length (never
        /// negative) so a caller's computed offset can't crash on a shrinking
        /// edit (e.g. Delete at EOF). A no-op splice (`newSource == current`,
        /// e.g. `BlockReorder.move`'s identity/out-of-range case) is skipped
        /// entirely — no empty undo group, no spurious re-decoration.
        private func applyWholeDocumentSplice(newSource: String, selection: NSRange) {
            guard let textView else { return }
            let current = textView.string
            guard newSource != current else { return }

            let fullRange = NSRange(location: 0, length: (current as NSString).length)
            let clipView = textView.enclosingScrollView?.contentView
            let savedScrollOrigin = clipView?.bounds.origin

            isPerformingEdit = true
            textView.breakUndoCoalescing()
            textView.undoManager?.beginUndoGrouping()
            textView.insertText(newSource, replacementRange: fullRange)
            textView.undoManager?.endUndoGrouping()
            textView.breakUndoCoalescing()
            isPerformingEdit = false

            applyDecorations(scopedTo: nil)
            refreshMarkerVisibility()

            let newLength = (newSource as NSString).length
            let clampedLocation = max(0, min(selection.location, newLength))
            let clampedLength = max(0, min(selection.length, newLength - clampedLocation))
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
            if let clipView, let savedScrollOrigin {
                clipView.scroll(to: savedScrollOrigin)
                textView.enclosingScrollView?.reflectScrolledClipView(clipView)
            }
        }

        // MARK: Block rect publication (2b Task 9)

        /// TK1 layout heartbeat: once layout settles, recompute block geometry.
        func layoutManager(_ layoutManager: NSLayoutManager,
                           didCompleteLayoutFor textContainer: NSTextContainer?,
                           atEnd layoutFinishedFlag: Bool) {
            guard layoutFinishedFlag else { return }
            schedulePublishBlockRects()
        }

        @objc func clipViewBoundsDidChange(_ notification: Notification) {
            schedulePublishBlockRects()
            // A scroll moves the hovered link out from under the pointer — the
            // anchored popover would drift; hide it. (The slash/autocomplete menus
            // stay, matching the slash menu's existing scroll behavior.)
            clearHover()
        }

        /// Coalesces to one publication per runloop turn — layout/scroll callbacks
        /// arrive in bursts, and each publication is a SwiftUI state write. Also
        /// hops off the layout pass itself (mutating SwiftUI state mid-layout is
        /// reentrancy roulette).
        private func schedulePublishBlockRects() {
            guard !rectPublishScheduled else { return }
            rectPublishScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rectPublishScheduled = false
                self.publishBlockRects()
            }
        }

        private func publishBlockRects() {
            guard let textView,
                  let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else { return }

            let source = textView.string
            var rects: [MarkdownBlockRect] = []
            // Large-note fallback: no decoration → no handles; typing still works.
            if (source as NSString).length <= Self.plainTextFallbackLimit {
                let moveable = currentBlocks(source).filter { !$0.isFrontmatter }
                for (index, block) in moveable.enumerated() {
                    guard block.range.upperBound <= (source as NSString).length else { continue }
                    let glyphRange = layoutManager.glyphRange(forCharacterRange: block.range,
                                                              actualCharacterRange: nil)
                    var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                    let origin = textView.textContainerOrigin
                    rect.origin.x += origin.x
                    rect.origin.y += origin.y
                    let inScrollView = scrollView.convert(rect, from: textView)
                    let kind = NoteDecoration.blockKind(source, of: block) ?? .paragraph
                    rects.append(MarkdownBlockRect(index: index,
                                                   rect: flipToOverlay(inScrollView, in: scrollView),
                                                   kind: kind))
                }
            }
            if rects != lastPublishedRects {
                lastPublishedRects = rects
                parent.onBlockRectsChange(rects)
            }
        }

        // MARK: Overlay-space geometry

        /// Caret/character rect in the editor overlay's space (top-left origin) —
        /// the scroll view IS the representable's bounds, so SwiftUI overlays and
        /// these rects share one coordinate system.
        private func overlayRect(forCharacterAt location: Int) -> CGRect? {
            guard let textView,
                  let scrollView = textView.enclosingScrollView,
                  let window = textView.window
            else { return nil }
            let screenRect = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0),
                                                actualRange: nil)
            let windowRect = window.convertFromScreen(screenRect)
            let inScrollView = scrollView.convert(windowRect, from: nil)
            return flipToOverlay(inScrollView, in: scrollView)
        }

        /// AppKit's unflipped views put y at the bottom; SwiftUI overlays measure
        /// from the top. One flip, one place.
        private func flipToOverlay(_ rect: CGRect, in view: NSView) -> CGRect {
            guard !view.isFlipped else { return rect }
            return CGRect(x: rect.minX,
                          y: view.bounds.height - rect.maxY,
                          width: rect.width,
                          height: rect.height)
        }
    }
}

// MARK: - Focus-reporting text view (Phase 1 / BAK-250)

/// An `NSTextView` that reports first-responder gain/loss to the coordinator, so
/// marker hiding keys off ACTUAL focus. `textDidBegin/EndEditing` were the wrong
/// signal — they fire on the first/last keystroke of an editing session, so a
/// plain click-in (before typing) or click-away wouldn't toggle focus. Overriding
/// `become`/`resignFirstResponder` is the reliable hook.
final class FocusReportingTextView: NSTextView {
    weak var focusCoordinator: MarkdownTextView.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { focusCoordinator?.setFocus(true) }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { focusCoordinator?.setFocus(false) }
        return didResign
    }

    // MARK: Wikilink hover tracking (Notes polish pack C)

    /// One tracking area over the visible rect feeds mouseMoved into the
    /// coordinator's hover hit-test. `.inVisibleRect` keeps the rect in sync with
    /// scrolling/resizes without manual re-add; the coordinator owns all decisions
    /// (which link, debounce, publish) — this view only forwards pointer events.
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        focusCoordinator?.handleHoverMove(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        focusCoordinator?.clearHover()
    }

    /// A single click on a checkbox glyph toggles it instead of placing a caret.
    /// Everything else (multi-click, non-checkbox clicks) falls through to normal
    /// text-view behaviour.
    override func mouseDown(with event: NSEvent) {
        // Plain single clicks only — a modifier click (shift/cmd/etc.) must still
        // extend/place a selection that can start on a checkbox's column.
        let plainClick = event.modifierFlags
            .intersection([.shift, .command, .control, .option]).isEmpty
        if event.clickCount == 1, plainClick, let layoutManager, let textContainer,
           focusCoordinator?.handleCheckboxClick(
               at: convert(event.locationInWindow, from: nil),
               layoutManager: layoutManager,
               textContainer: textContainer,
               containerOrigin: textContainerOrigin) == true {
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Subpage-card drawing (2b Task 10)

/// TK1 layout manager that draws a Craft-style card BEHIND any range carrying the
/// `.mustardSubpageCard` attribute (set by the decoration pass for lines that are
/// exactly one bare wikilink). Drawing only — characters, caret movement, selection
/// and undo are untouched; the caret can enter the line and edit the raw `[[...]]`.
final class CardLayoutManager: NSLayoutManager {

    /// `doc.text` tinted to the tertiary token, rendered once. Bridged from
    /// `Theme.NSPalette` — never fresh hex.
    private static let cardIcon: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: NSFont.Weight.regular)
        guard let symbol = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let size = symbol.size
        return NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            Theme.NSPalette.textTertiary.set()
            rect.fill(using: NSCompositingOperation.sourceAtop)
            return true
        }
    }()

    /// One SF Symbol flattened to a single tint (same recipe as `cardIcon`),
    /// cached. `nil` only if the symbol is unavailable on the OS.
    private static func glyphImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: NSFont.Weight.regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let size = symbol.size
        return NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: NSCompositingOperation.sourceAtop)
            return true
        }
    }
    private static let checkboxUnchecked = glyphImage("square", pointSize: 15, color: Theme.NSPalette.textTertiary)
    private static let checkboxChecked = glyphImage("checkmark.square", pointSize: 15, color: Theme.NSPalette.accent)

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // Block glyphs (checkbox / bullet / divider) drawn over their transparent
        // raw-markdown characters (Phase: block-glyph rendering).
        storage.enumerateAttribute(NSAttributedString.Key.mustardBlockGlyph,
                                   in: charRange, options: []) { value, range, _ in
            guard let code = (value as? NSNumber)?.intValue,
                  let glyph = BlockGlyphCode(rawValue: code) else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            var markerRect = self.boundingRect(forGlyphRange: glyphRange, in: container)
            markerRect.origin.x += origin.x
            markerRect.origin.y += origin.y

            switch glyph {
            case .checkboxUnchecked, .checkboxChecked:
                let image = (glyph == .checkboxChecked)
                    ? CardLayoutManager.checkboxChecked : CardLayoutManager.checkboxUnchecked
                guard let image else { return }
                let iconRect = NSRect(x: markerRect.minX + 1.0,
                                      y: markerRect.midY - image.size.height / 2.0,
                                      width: image.size.width, height: image.size.height)
                image.draw(in: iconRect, from: NSRect.zero,
                           operation: NSCompositingOperation.sourceOver,
                           fraction: 1.0, respectFlipped: true, hints: nil)
            case .bullet:
                let diameter: CGFloat = 5.0
                let dot = NSRect(x: markerRect.minX + 3.0, y: markerRect.midY - diameter / 2.0,
                                 width: diameter, height: diameter)
                Theme.NSPalette.textPrimary.setFill()
                NSBezierPath(ovalIn: dot).fill()
            case .divider:
                // Span the whole line fragment, not the narrow "---" glyph rect.
                var lineRect = self.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                lineRect.origin.x += origin.x
                lineRect.origin.y += origin.y
                let path = NSBezierPath()
                path.move(to: NSPoint(x: lineRect.minX + 2.0, y: lineRect.midY))
                path.line(to: NSPoint(x: lineRect.maxX - 8.0, y: lineRect.midY))
                Theme.NSPalette.hairline.setStroke()
                path.lineWidth = 1.0
                path.stroke()
            }
        }

        storage.enumerateAttribute(NSAttributedString.Key.mustardSubpageCard,
                                   in: charRange,
                                   options: []) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            var rect = self.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += origin.x
            rect.origin.y += origin.y

            // Card chrome: slight outset, extra leading room for the glyph.
            var cardRect = rect.insetBy(dx: -4.0, dy: -2.0)
            let iconGutter: CGFloat = 18.0
            cardRect.origin.x -= iconGutter
            cardRect.size.width += iconGutter

            let path = NSBezierPath(roundedRect: cardRect,
                                    xRadius: Theme.Metrics.rLg,
                                    yRadius: Theme.Metrics.rLg)
            Theme.NSPalette.bg.setFill()
            path.fill()
            Theme.NSPalette.hairline.setStroke()
            path.lineWidth = 1.0
            path.stroke()

            if let icon = CardLayoutManager.cardIcon {
                let iconRect = NSRect(x: cardRect.minX + 6.0,
                                      y: cardRect.midY - icon.size.height / 2.0,
                                      width: icon.size.width,
                                      height: icon.size.height)
                icon.draw(in: iconRect,
                          from: NSRect.zero,
                          operation: NSCompositingOperation.sourceOver,
                          fraction: 1.0,
                          respectFlipped: true,
                          hints: nil)
            }
        }
    }
}
