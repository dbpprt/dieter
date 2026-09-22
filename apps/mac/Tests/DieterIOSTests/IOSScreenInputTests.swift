import Testing
@testable import DieterIOS

@Suite("iOS screen input controls")
struct IOSScreenInputTests {
    @Test func rightClickModeIsOneShot() {
        var mode = IOSRemoteDesktopClickMode()

        #expect(!mode.rightClickArmed)
        mode.toggleRightClick()
        #expect(mode.rightClickArmed)
        mode.consume()
        #expect(!mode.rightClickArmed)
    }

    @Test func rightClickModeCanBeCancelledOrToggledOff() {
        var mode = IOSRemoteDesktopClickMode()

        mode.toggleRightClick()
        mode.toggleRightClick()
        #expect(!mode.rightClickArmed)
        mode.toggleRightClick()
        mode.cancel()
        #expect(!mode.rightClickArmed)
    }

    @Test func armedControlTurnsSoftwareKeyboardLetterIntoPhysicalChord() throws {
        let stroke = try #require(IOSRemoteDesktopKeyStroke(text: "d", modifiers: 2))

        #expect(stroke.hid == 7)
        #expect(stroke.modifiers == 2)
    }

    @Test func armedModifiersPreserveTheShiftRequiredByTypedCharacter() throws {
        let uppercase = try #require(IOSRemoteDesktopKeyStroke(text: "D", modifiers: 2))
        let questionMark = try #require(IOSRemoteDesktopKeyStroke(text: "?", modifiers: 8))

        #expect(uppercase.hid == 7)
        #expect(uppercase.modifiers == 3)
        #expect(questionMark.hid == 56)
        #expect(questionMark.modifiers == 9)
    }

    @Test func ordinaryAndComposedTextRemainCommittedText() {
        #expect(IOSRemoteDesktopKeyStroke(text: "d", modifiers: 0) == nil)
        #expect(IOSRemoteDesktopKeyStroke(text: "paste", modifiers: 2) == nil)
        #expect(IOSRemoteDesktopKeyStroke(text: "é", modifiers: 2) == nil)
    }

    @Test func armedModifiersAreConsumedByACompletedNonModifierKey() {
        #expect(!IOSRemoteDesktopModifierPolicy.consumesArmedModifiers(hid: 7, down: true))
        #expect(IOSRemoteDesktopModifierPolicy.consumesArmedModifiers(hid: 7, down: false))
        #expect(!IOSRemoteDesktopModifierPolicy.consumesArmedModifiers(hid: 224, down: false))
    }
}
