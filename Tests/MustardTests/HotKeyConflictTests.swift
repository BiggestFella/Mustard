import XCTest

@testable import MustardKit

/// Duplicate-chord detection across the whole registry — scope does not
/// matter (a global and an in-app action sharing a chord shadow each other).
final class HotKeyConflictTests: XCTestCase {
    private var defaults: [HotKeyAction: HotKeyChord] {
        Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, $0.defaultChord) })
    }

    func test_uniqueChord_hasNoConflict() {
        XCTAssertNil(HotKeyConflicts.conflictingAction(
            with: HotKeyChord(keyCode: 11, carbonModifiers: 0x1800),
            for: .commandBar, chords: defaults))
    }

    func test_takingAnotherActionsChord_namesTheOwner() {
        // ⌘⇧H is hover's default — assigning it to the command bar conflicts.
        XCTAssertEqual(
            HotKeyConflicts.conflictingAction(
                with: HotKeyChord(keyCode: 4, carbonModifiers: 0x300),
                for: .commandBar, chords: defaults),
            .hover)
    }

    func test_crossScope_globalTakingInAppChord_conflicts() {
        XCTAssertEqual(
            HotKeyConflicts.conflictingAction(
                with: HotKeyChord(keyCode: 40, carbonModifiers: 0x100),
                for: .rewrite, chords: defaults),
            .commandBar)
    }

    func test_reassigningYourOwnChord_isNotAConflict() {
        XCTAssertNil(HotKeyConflicts.conflictingAction(
            with: HotKeyChord(keyCode: 4, carbonModifiers: 0x300),
            for: .hover, chords: defaults))
    }

    func test_defaultChords_haveNoDuplicatesAmongThemselves() {
        for action in HotKeyAction.allCases {
            XCTAssertNil(
                HotKeyConflicts.conflictingAction(
                    with: action.defaultChord, for: action, chords: defaults),
                "\(action) default collides")
        }
    }
}
