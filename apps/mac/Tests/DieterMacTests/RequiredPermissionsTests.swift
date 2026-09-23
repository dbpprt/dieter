import Testing
@testable import DieterMac

@MainActor
@Test func requiredPermissionsMustBeVerifiedAndRevocationClosesReadiness() {
    var granted: Set<RequiredPermissions.Permission> = []
    var requests: [RequiredPermissions.Permission] = []
    var opened: [RequiredPermissions.Permission] = []
    let permissions = RequiredPermissions(
        check: { granted.contains($0) }, request: { requests.append($0) },
        openSettings: {
            opened.append($0); return true
        })
    #expect(!permissions.isReady)
    permissions.grant(.accessibility)
    #expect(requests == [.accessibility])
    #expect(opened == [.accessibility])
    #expect(!permissions.isReady)  // Clicking the grant button is not consent.
    granted.insert(.accessibility)
    permissions.refresh()
    #expect(permissions.accessibility && !permissions.isReady)
    granted.insert(.screenRecording)
    permissions.refresh()
    #expect(permissions.isReady)
    granted.remove(.accessibility)
    permissions.refresh()
    #expect(!permissions.isReady)
    #expect(requests.count == 1)  // Passive checks never prompt.
}

@MainActor
@Test func requiredPermissionsExplainsSettingsOpenFailure() {
    let permissions = RequiredPermissions(check: { _ in false }, request: { _ in }, openSettings: { _ in false })
    permissions.grant(.screenRecording)
    #expect(permissions.settingsError?.contains("Privacy & Security") == true)
    #expect(!permissions.isReady)
}

@MainActor
@Test func skippingSetupAllowsTheAppWithoutPretendingPermissionsWereGranted() {
    let permissions = RequiredPermissions(check: { _ in false }, request: { _ in }, openSettings: { _ in true })

    #expect(!permissions.isReady)
    #expect(!permissions.canUseApp)

    permissions.skipSetup()

    #expect(permissions.canUseApp)
    #expect(permissions.setupSkipped)
    #expect(!permissions.isReady)
    #expect(!permissions.accessibility)
    #expect(!permissions.screenRecording)
}
