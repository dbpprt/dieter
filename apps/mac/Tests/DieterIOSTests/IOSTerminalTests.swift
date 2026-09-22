import Foundation
import Testing
@testable import DieterIOS

@Suite("iOS remote terminals")
struct IOSTerminalTests {
    @Test func terminalScreenAppendsOutputAndReplacesItOnDaemonReset() {
        var screen = IOSTerminalScreenState()
        screen.apply(data: Data("first ".utf8), reset: true)
        screen.apply(data: Data("second".utf8), reset: false)

        #expect(screen.accessibilityText == "first second")
        #expect(screen.revision == 2)
        #expect(screen.resetRevision == 1)

        screen.apply(data: Data("fresh".utf8), reset: true)
        #expect(screen.accessibilityText == "fresh")
        #expect(screen.resetRevision == 2)
    }

    @Test func terminalScreenBoundsRetainedReplayAndMarksItForAFullRedraw() {
        var screen = IOSTerminalScreenState()
        screen.apply(data: Data(repeating: 0x61, count: 96), reset: true, limit: 64)
        screen.apply(data: Data(repeating: 0x62, count: 32), reset: false, limit: 64)

        #expect(screen.byteCount == 64)
        #expect(screen.accessibilityText == String(repeating: "a", count: 32) + String(repeating: "b", count: 32))
        #expect(screen.resetRevision == 3)
    }

    @Test func terminalSpecialKeysUseStandardVTSequences() {
        #expect(IOSTerminalKeyInput.arrow(.up) == Data([0x1b, 0x5b, 0x41]))
        #expect(IOSTerminalKeyInput.arrow(.down) == Data([0x1b, 0x5b, 0x42]))
        #expect(IOSTerminalKeyInput.arrow(.left) == Data([0x1b, 0x5b, 0x44]))
        #expect(IOSTerminalKeyInput.arrow(.right) == Data([0x1b, 0x5b, 0x43]))
        #expect(IOSTerminalKeyInput.function(1) == Data("\u{1b}OP".utf8))
        #expect(IOSTerminalKeyInput.function(12) == Data("\u{1b}[24~".utf8))
        #expect(IOSTerminalKeyInput.function(13) == nil)
    }

    @Test func terminalControlModifierTransformsOnlyOneAsciiKey() {
        #expect(IOSTerminalKeyInput.controlModified(Data("c".utf8)) == Data([0x03]))
        #expect(IOSTerminalKeyInput.controlModified(Data("[".utf8)) == Data([0x1b]))
        #expect(IOSTerminalKeyInput.controlModified(Data("?".utf8)) == Data([0x7f]))
        #expect(IOSTerminalKeyInput.controlModified(Data("paste".utf8)) == nil)
        #expect(IOSTerminalKeyInput.controlModified(Data("é".utf8)) == nil)
    }
}
