import Foundation
import Testing
@testable import DieterMac

@Test @MainActor func screenShareInactivityPreferencesDefaultAndPersist() throws {
    let suite = "dieter-screen-share-inactivity-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let initial = ScreensModel(defaults: defaults)
    #expect(initial.inactivityTimeoutEnabled)
    #expect(initial.inactivityTimeoutMinutes == 30)

    initial.inactivityTimeoutEnabled = false
    initial.inactivityTimeoutMinutes = 45

    let restored = ScreensModel(defaults: defaults)
    #expect(!restored.inactivityTimeoutEnabled)
    #expect(restored.inactivityTimeoutMinutes == 45)
}

@Test @MainActor func screenShareTabsAreMachineScopedAndClosingOnePreservesTheOthers() throws {
    let suite = "dieter-screen-share-tabs-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = ScreensModel(defaults: defaults)
    let first = ScreenShareSession(
        id: "first", machineID: "machine-a", machineName: "Alpha", monitorsInactivity: false)
    let second = ScreenShareSession(
        id: "second", machineID: "machine-b", machineName: "Beta", monitorsInactivity: false)
    model.sessions = [first, second]
    model.selectedSessionID = first.id
    first.controller.phase = .streaming
    second.controller.phase = .streaming

    #expect(model.connectedCount == 2)
    model.selectSession(second.id)
    #expect(model.selectedSession === second)

    model.closeSession(second.id)
    #expect(model.sessions.map(\.machineID) == ["machine-a"])
    #expect(model.selectedSession === first)
    #expect(first.controller.phase == .streaming)
    #expect(model.connectedCount == 1)

    model.closeSession(first.id)
    #expect(model.sessions.isEmpty)
    #expect(model.selectedSessionID == nil)
}

@Test @MainActor func inactiveScreenShareDisconnectsAtConfiguredDeadline() {
    let session = ScreenShareSession(
        machineID: "machine", machineName: "Machine", monitorsInactivity: false)
    session.controller.phase = .streaming
    session.configureInactivityTimeout(enabled: true, minutes: 2)
    let activity = Date(timeIntervalSinceReferenceDate: 100)
    session.recordActivity(at: activity)

    #expect(!session.disconnectIfInactive(at: activity.addingTimeInterval(119)))
    #expect(session.controller.phase == .streaming)
    #expect(session.disconnectIfInactive(at: activity.addingTimeInterval(120)))
    #expect(session.controller.phase == .idle)
    #expect(session.inactivityMessage == "Disconnected after 2 minutes of inactivity.")
}

@Test @MainActor func disabledScreenShareTimeoutNeverDisconnects() {
    let session = ScreenShareSession(
        machineID: "machine", machineName: "Machine", monitorsInactivity: false)
    session.controller.phase = .streaming
    session.configureInactivityTimeout(enabled: false, minutes: 1)
    let activity = Date(timeIntervalSinceReferenceDate: 100)
    session.recordActivity(at: activity)

    #expect(!session.disconnectIfInactive(at: activity.addingTimeInterval(3_600)))
    #expect(session.controller.phase == .streaming)
}
