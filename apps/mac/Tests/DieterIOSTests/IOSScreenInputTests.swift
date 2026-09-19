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
}
