import AppKit
import DieterCore
import Foundation
import Observation

struct ScreenShareInactivityPreferences: Equatable {
    static let defaultMinutes = 30
    static let enabledKey = "DieterScreenShareInactivityTimeoutEnabled"
    static let minutesKey = "DieterScreenShareInactivityTimeoutMinutes"

    var enabled: Bool
    var minutes: Int

    static func load(from defaults: UserDefaults) -> Self {
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? false
        let storedMinutes = defaults.object(forKey: minutesKey) as? Int ?? defaultMinutes
        return .init(enabled: enabled, minutes: clamped(storedMinutes))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(Self.clamped(minutes), forKey: Self.minutesKey)
    }

    static func clamped(_ minutes: Int) -> Int { min(max(minutes, 1), 240) }
}

@MainActor
@Observable
final class ScreenShareSession: Identifiable {
    let id: String
    let machineID: String
    let machineName: String
    let controller: RemoteDesktopController
    var isDetached = false
    var matchClientResolution = false
    @ObservationIgnored lazy var videoSurface = RemoteDesktopInputView(
        renderer: controller.renderer, controller: controller)
    @ObservationIgnored private var connectionFactory: (@MainActor () async throws -> RemoteDesktopSignalingConnection)?
    private(set) var inactivityMessage: String?
    @ObservationIgnored private var timeoutMinutes: Int?
    @ObservationIgnored private var lastActivityAt = Date()
    @ObservationIgnored private var inactivityTask: Task<Void, Never>?
    @ObservationIgnored private var inactivityMonitorGeneration = 0
    @ObservationIgnored private let monitorsInactivity: Bool

    init(
        id: String = UUID().uuidString.lowercased(), machineID: String, machineName: String,
        controller: RemoteDesktopController = RemoteDesktopController(), monitorsInactivity: Bool = true
    ) {
        self.id = id
        self.machineID = machineID
        self.machineName = machineName
        self.controller = controller
        self.monitorsInactivity = monitorsInactivity
        controller.onUserActivity = { [weak self] in self?.recordActivity() }
        controller.onSystemSleep = { [weak self] in self?.cancelInactivityMonitor() }
    }

    var isConnected: Bool { controller.phase == .streaming }

    var keepsConnectionOpen: Bool {
        switch controller.phase {
        case .loading, .disabled, .connecting, .waitingForHostApproval, .streaming, .reconnecting: true
        case .idle, .failed: false
        }
    }

    func connect(
        makeConnection: @escaping @MainActor () async throws -> RemoteDesktopSignalingConnection
    ) {
        connectionFactory = makeConnection
        inactivityMessage = nil
        lastActivityAt = Date()
        _ = controller.connect(machineName: machineName, makeConnection: makeConnection)
        startInactivityMonitorIfNeeded()
    }

    func reconnect() { if let connectionFactory { connect(makeConnection: connectionFactory) } }

    func disconnect() {
        cancelInactivityMonitor()
        inactivityMessage = nil
        controller.disconnect()
    }

    func configureInactivityTimeout(enabled: Bool, minutes: Int) {
        cancelInactivityMonitor()
        timeoutMinutes = enabled ? ScreenShareInactivityPreferences.clamped(minutes) : nil
        if enabled {
            startInactivityMonitorIfNeeded()
        }
    }

    func recordActivity(at now: Date = Date()) {
        lastActivityAt = now
        inactivityMessage = nil
        startInactivityMonitorIfNeeded()
    }

    @discardableResult
    func disconnectIfInactive(at now: Date = Date()) -> Bool {
        guard let timeoutMinutes, keepsConnectionOpen, !controller.systemSleeping,
            now.timeIntervalSince(lastActivityAt) >= TimeInterval(timeoutMinutes * 60)
        else { return false }
        let unit = timeoutMinutes == 1 ? "minute" : "minutes"
        inactivityMessage = "Disconnected after " + String(timeoutMinutes) + " " + unit + " of inactivity."
        controller.disconnect()
        cancelInactivityMonitor()
        return true
    }

    private func startInactivityMonitorIfNeeded() {
        guard monitorsInactivity, timeoutMinutes != nil, keepsConnectionOpen, inactivityTask == nil else { return }
        inactivityMonitorGeneration &+= 1
        let generation = inactivityMonitorGeneration
        inactivityTask = Task { [weak self] in
            await self?.monitorInactivity(generation: generation)
        }
    }

    private func cancelInactivityMonitor() {
        inactivityMonitorGeneration &+= 1
        inactivityTask?.cancel()
        inactivityTask = nil
    }

    private func monitorInactivity(generation: Int) async {
        defer {
            if inactivityMonitorGeneration == generation {
                inactivityTask = nil
            }
        }
        while !Task.isCancelled, let timeoutMinutes, keepsConnectionOpen {
            let deadline = lastActivityAt.addingTimeInterval(TimeInterval(timeoutMinutes * 60))
            do {
                try await DieterTaskSleep.seconds(max(0.05, deadline.timeIntervalSinceNow))
            } catch {
                return
            }
            if disconnectIfInactive() { return }
        }
    }
}

@MainActor
@Observable
final class ScreensModel {
    private let defaults: UserDefaults
    var sessions: [ScreenShareSession] = []
    var selectedSessionID: String?
    var createScreenSharePresented = false
    @ObservationIgnored private(set) var detachedWindows: [String: ScreenShareWindowController] = [:]
    static let resolutionMatchingKey = "DieterScreenMatchClientResolutionExperimental"
    static let keyboardCaptureKey = "DieterScreenCaptureFullscreenKeyboard"
    var matchClientResolution: Bool {
        didSet {
            defaults.set(matchClientResolution, forKey: Self.resolutionMatchingKey)
            for session in sessions { session.matchClientResolution = matchClientResolution }
            for window in detachedWindows.values { window.updateDisplayMatching() }
        }
    }
    var captureFullscreenKeyboard: Bool {
        didSet {
            defaults.set(captureFullscreenKeyboard, forKey: Self.keyboardCaptureKey)
            for session in sessions { session.videoSurface.captureKeyboard = captureFullscreenKeyboard }
        }
    }
    var inactivityTimeoutEnabled: Bool {
        didSet {
            guard inactivityTimeoutEnabled != oldValue else { return }
            savePreferencesAndApply()
        }
    }
    var inactivityTimeoutMinutes: Int {
        didSet {
            let clamped = ScreenShareInactivityPreferences.clamped(inactivityTimeoutMinutes)
            if clamped != inactivityTimeoutMinutes {
                inactivityTimeoutMinutes = clamped
                return
            }
            guard inactivityTimeoutMinutes != oldValue else { return }
            savePreferencesAndApply()
        }
    }

    var selectedSession: ScreenShareSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var connectedCount: Int { sessions.filter(\.isConnected).count }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let preferences = ScreenShareInactivityPreferences.load(from: defaults)
        inactivityTimeoutEnabled = preferences.enabled
        inactivityTimeoutMinutes = preferences.minutes
        matchClientResolution = defaults.bool(forKey: Self.resolutionMatchingKey)
        captureFullscreenKeyboard = defaults.object(forKey: Self.keyboardCaptureKey) as? Bool ?? true
    }

    @discardableResult
    func createSession(
        machineID: String, machineName: String,
        makeConnection: @escaping @MainActor () async throws -> RemoteDesktopSignalingConnection
    ) -> ScreenShareSession {
        let session = ScreenShareSession(machineID: machineID, machineName: machineName)
        session.matchClientResolution = matchClientResolution
        session.videoSurface.captureKeyboard = captureFullscreenKeyboard
        session.configureInactivityTimeout(
            enabled: inactivityTimeoutEnabled, minutes: inactivityTimeoutMinutes)
        sessions.append(session)
        selectedSessionID = session.id
        createScreenSharePresented = false
        session.connect(makeConnection: makeConnection)
        return session
    }

    func selectSession(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        selectedSessionID = id
        session.recordActivity()
    }

    func closeSession(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedSessionID == id
        let replacementID: String? = {
            guard wasSelected, sessions.count > 1 else { return nil }
            return sessions[index == sessions.count - 1 ? index - 1 : index + 1].id
        }()
        detachedWindows.removeValue(forKey: id)?.dispose()
        sessions[index].isDetached = false
        sessions[index].disconnect()
        sessions.remove(at: index)
        if wasSelected { selectedSessionID = replacementID }
    }

    func undock(_ id: String, fullScreen: Bool = true, showInDieter: @escaping @MainActor () -> Void = {}) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if let existing = detachedWindows[id] { existing.present(fullScreen: fullScreen); return }
        session.recordActivity()
        let origin = session.videoSurface.window ?? NSApp.keyWindow
        session.isDetached = true
        let viewer = ScreenShareWindowController(session: session) { [weak self, weak origin] in
            guard let self else { return }
            self.detachedWindows.removeValue(forKey: id)?.dispose()
            session.isDetached = false
            self.selectedSessionID = id
            showInDieter()
            origin?.makeKeyAndOrderFront(nil)
        }
        detachedWindows[id] = viewer
        viewer.present(fullScreen: fullScreen)
    }

    func dock(_ id: String) { detachedWindows[id]?.returnToDieter() }

    private func savePreferencesAndApply() {
        let preferences = ScreenShareInactivityPreferences(
            enabled: inactivityTimeoutEnabled, minutes: inactivityTimeoutMinutes)
        preferences.save(to: defaults)
        for session in sessions {
            session.configureInactivityTimeout(
                enabled: inactivityTimeoutEnabled, minutes: inactivityTimeoutMinutes)
        }
    }
}
