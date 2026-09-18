import AppKit
import DieterAPI
import DieterCore
import Observation

struct RemoteDesktopDisplayTarget: Equatable {
    var width: Int
    var height: Int
    var scale: Double
    var refresh: Double

    func bestMode(in modes: [Dieter_V1_RemoteDesktopDisplayMode]) -> Dieter_V1_RemoteDesktopDisplayMode? {
        guard width > 0, height > 0, scale.isFinite, scale > 0 else { return nil }
        func score(_ mode: Dieter_V1_RemoteDesktopDisplayMode) -> Double {
            let w = Double(mode.logicalWidth), h = Double(mode.logicalHeight)
            let aspect = abs(log((w / h) / (Double(width) / Double(height))))
            let size = abs(log(w / Double(width))) + abs(log(h / Double(height)))
            let pixels =
                abs(log(Double(mode.pixelWidth) / (Double(width) * scale)))
                + abs(log(Double(mode.pixelHeight) / (Double(height) * scale)))
            let rate = mode.refreshRate > 0 && refresh > 0 ? abs(mode.refreshRate - refresh) / max(refresh, 1) : 0
            return aspect * 10 + size * 3 + pixels + rate * 0.1
        }
        return modes.filter { $0.logicalWidth > 0 && $0.logicalHeight > 0 && $0.pixelWidth > 0 && $0.pixelHeight > 0 }
            .min { score($0) == score($1) ? $0.id < $1.id : score($0) < score($1) }
    }
    func exactlyMatches(_ mode: Dieter_V1_RemoteDesktopDisplayMode) -> Bool {
        Int(mode.logicalWidth) == width && Int(mode.logicalHeight) == height
            && Int(mode.pixelWidth) == Int((Double(width) * scale).rounded())
            && Int(mode.pixelHeight) == Int((Double(height) * scale).rounded())
    }
}

// Reconcile serially: an exit/toggle during an in-flight mutation restores it
// after the reply, rather than cancelling and abandoning an uncertain outcome.
@MainActor @Observable final class RemoteDesktopDisplayMatching {
    struct Intent {
        let rpc: any ScreenSignalingRPC
        let sessionID: String
        let displayID: String
        let target: RemoteDesktopDisplayTarget
        func matches(_ other: Intent?) -> Bool {
            guard let other else { return false }
            return sessionID == other.sessionID && displayID == other.displayID && target == other.target
        }
    }
    private(set) var status = ""
    private(set) var busy = false
    @ObservationIgnored private var desired: Intent?
    @ObservationIgnored private var attempted: Intent?
    @ObservationIgnored private var leased: Intent?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored var beforeChange: () -> Void = {}

    func update(_ intent: Intent?, unavailable: String = "") {
        if intent?.matches(desired) == true || (intent == nil && desired == nil) {
            if intent == nil && worker == nil && !unavailable.isEmpty { status = unavailable }
            return
        }
        desired = intent; attempted = nil
        if worker == nil {
            worker = Task { [weak self] in await self?.reconcile() }
        }
    }

    private func reconcile() async {
        busy = true
        defer { busy = false; worker = nil }
        while true {
            if let lease = leased, !lease.matches(desired) {
                beforeChange()
                do {
                    _ = try await lease.rpc.restoreRemoteDesktopDisplayMode(sessionID: lease.sessionID)
                    status = "Remote resolution restored"
                } catch {
                    // Session close/handoff independently releases the server lease.
                    status = "Resolution restore: \(error.localizedDescription)"
                }
                leased = nil
            }
            guard let intent = desired, !intent.matches(attempted) else { return }
            attempted = intent
            // Monitor moves and fullscreen transitions can report several sizes.
            try? await Task.sleep(for: .milliseconds(350))
            guard intent.matches(desired) else { continue }
            do {
                let modes = try await intent.rpc.remoteDesktopDisplayModes(sessionID: intent.sessionID)
                guard intent.matches(desired) else { continue }
                guard !modes.superseded, let mode = intent.target.bestMode(in: modes.modes) else {
                    status = modes.superseded ? "Remote resolution changed locally" : "No supported remote resolution"
                    continue
                }
                if modes.currentModeID != mode.id {
                    beforeChange()
                    var request = Dieter_V1_SetRemoteDesktopDisplayModeRequest()
                    request.sessionID = intent.sessionID; request.displayID = modes.displayID
                    request.modeID = mode.id; request.expectedCurrentModeID = modes.currentModeID
                    leased = intent
                    let result = try await intent.rpc.setRemoteDesktopDisplayMode(request)
                    if !result.temporary { leased = nil }
                }
                let kind = intent.target.exactlyMatches(mode) ? "Matched" : "Closest supported"
                status =
                    "\(kind): \(mode.logicalWidth) × \(mode.logicalHeight) (\(mode.pixelWidth) × \(mode.pixelHeight) pixels)"
            } catch {
                let message = "Resolution matching unavailable: \(error.localizedDescription)"
                if let lease = leased {
                    _ = try? await lease.rpc.restoreRemoteDesktopDisplayMode(sessionID: lease.sessionID)
                    leased = nil
                }
                status = message
            }
        }
    }
}
