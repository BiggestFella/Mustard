# Verification — Craft editor eye-check fixes (agent/bak254-craft-editor-glyphs)

## Checks (final, post review-fix)
- swift test → Executed 866 tests, 1 skipped, 0 failures (baseline 840 → +26 pure-logic tests)
- swift build → Build complete!
- ./build-app.sh → app assembles; Leon eye-confirmed hiding + checkbox/bullet/divider render and checkbox click toggles.

## What landed (two concerns)
1. Marker-hiding mechanism rewrite: setNotShownAttribute → NSLayoutManager
   shouldGenerateGlyphs `.null` glyph property. Root cause of the eye-check
   failure: setNotShownAttribute left advance width (no reflow) and was wiped on
   glyph regeneration, so markers never hid. Null glyphs reflow + survive regen.
   Focus via FocusReportingTextView (become/resignFirstResponder). Policy:
   always hidden (Leon's call).
2. Block glyphs: checkbox (clickable, toggles [ ]↔[x]), bullet, divider drawn
   over transparent raw markdown via .mustardBlockGlyph + CardLayoutManager.
   Pure NoteDecoration.blockGlyph + CheckboxToggle (26 tests).

## Fresh-context review: APPROVE, 0 blocking
Verified: text==source invariant (no NSTextAttachment; only length-preserving
CheckboxToggle mutates), null-glyph delegate buffer safety, no hidden/block-glyph
range collision, no stale-range race (synchronous refresh in textDidChange).
Non-blocking finding (below-last-line false toggle) FIXED inline (fragment-rect
guard) + modifier-click exclusion. Remaining non-blocking notes → BAK-254.
