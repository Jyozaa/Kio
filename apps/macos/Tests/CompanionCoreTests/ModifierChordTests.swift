import XCTest
@testable import CompanionCore

final class ModifierChordTests: XCTestCase {
    func testOptionCommandTriggersOnceOnRelease() {
        var chord = ModifierChordRecognizer()
        XCTAssertFalse(chord.modifiersChanged(optionDown: true, commandDown: false))
        XCTAssertFalse(chord.modifiersChanged(optionDown: true, commandDown: true))
        XCTAssertFalse(chord.modifiersChanged(optionDown: false, commandDown: true))
        XCTAssertTrue(chord.modifiersChanged(optionDown: false, commandDown: false))
        XCTAssertFalse(chord.modifiersChanged(optionDown: false, commandDown: false))
    }

    func testEitherModifierOrderAndAggregateLeftRightFlags() {
        var commandFirst = ModifierChordRecognizer()
        XCTAssertFalse(commandFirst.modifiersChanged(optionDown: false, commandDown: true))
        XCTAssertFalse(commandFirst.modifiersChanged(optionDown: true, commandDown: true))
        XCTAssertTrue(commandFirst.modifiersChanged(optionDown: false, commandDown: false))

        // Releasing one of two same-side variants leaves the aggregate flag held.
        var bothSides = ModifierChordRecognizer()
        XCTAssertFalse(bothSides.modifiersChanged(optionDown: true, commandDown: true))
        XCTAssertFalse(bothSides.modifiersChanged(optionDown: true, commandDown: true))
        XCTAssertTrue(bothSides.modifiersChanged(optionDown: false, commandDown: false))
    }

    func testLetterAndEscapeShortcutsDoNotTrigger() {
        for key in ["K", "Escape", "other"] {
            var chord = ModifierChordRecognizer()
            XCTAssertFalse(chord.modifiersChanged(optionDown: true, commandDown: true), key)
            chord.nonModifierKeyDown()
            XCTAssertFalse(chord.modifiersChanged(optionDown: false, commandDown: false), key)
        }
    }

    func testSingleModifierOrInterruptedTapDoesNotTrigger() {
        var chord = ModifierChordRecognizer()
        XCTAssertFalse(chord.modifiersChanged(optionDown: true, commandDown: false))
        XCTAssertFalse(chord.modifiersChanged(optionDown: false, commandDown: false))
        XCTAssertFalse(chord.modifiersChanged(optionDown: true, commandDown: true))
        chord.reset()
        XCTAssertFalse(chord.modifiersChanged(optionDown: false, commandDown: false))
    }
}
