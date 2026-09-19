import DieterAPI
import Testing
@testable import DieterMac

@Test func linuxPortalCapabilityUsesLocalCursorWhileControlling() {
    var capabilities = Dieter_V1_RemoteDesktopCapabilities()
    capabilities.platform = "linux"
    capabilities.capturePermission = "not_requested"
    capabilities.controlSupported = true
    capabilities.controlPermission = "not_requested"
    capabilities.cursorSupported = false

    #expect(remoteDesktopShouldRequestControl(enabled: true, capabilities: capabilities))
    #expect(!remoteDesktopShouldRequestControl(enabled: false, capabilities: capabilities))
    #expect(remoteDesktopShouldEmbedCursor(capabilities, requestingControl: false))
    #expect(!remoteDesktopShouldEmbedCursor(capabilities, requestingControl: true))
    #expect(remoteDesktopNeedsHostApproval(capabilities))

    capabilities.platform = "darwin"
    #expect(!remoteDesktopShouldRequestControl(enabled: true, capabilities: capabilities))
    capabilities.controlPermission = "granted"
    capabilities.cursorSupported = true
    #expect(remoteDesktopShouldRequestControl(enabled: true, capabilities: capabilities))
    #expect(!remoteDesktopShouldEmbedCursor(capabilities, requestingControl: false))
    #expect(!remoteDesktopShouldEmbedCursor(capabilities, requestingControl: true))
    #expect(!remoteDesktopNeedsHostApproval(capabilities))
}
