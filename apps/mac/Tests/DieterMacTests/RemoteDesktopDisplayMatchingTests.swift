import Foundation
import Testing
@testable import DieterMac

// Mode choice and the serial change/restore protocol are the core's
// (ScreenPoliciesTest and ScreenDisplaysTest); the Mac keeps the preference.
@Suite(.serialized) @MainActor struct RemoteDesktopDisplayMatchingTests {
    @Test func experimentalPreferenceDefaultsOffAndPersists() throws {
        let suite = "screen-resolution-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ScreensModel(defaults: defaults)
        #expect(!model.matchClientResolution)
        #expect(model.captureFullscreenKeyboard)
        model.matchClientResolution = true
        model.captureFullscreenKeyboard = false
        let restored = ScreensModel(defaults: defaults)
        #expect(restored.matchClientResolution)
        #expect(!restored.captureFullscreenKeyboard)
    }
}
