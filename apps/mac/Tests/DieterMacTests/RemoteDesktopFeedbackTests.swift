import DieterAPI
import Foundation
import Testing
@testable import DieterMac

@Test @MainActor func remoteDesktopFrameRateChoicesRespectHostCapabilities() {
    let controller = RemoteDesktopController()
    #expect(controller.availableFrameRates == [30, 60])
    controller.capabilities.maxFps = 30
    #expect(controller.availableFrameRates == [30])
    controller.capabilities.maxFps = 120
    #expect(controller.availableFrameRates == [30, 60, 90, 120])
}
