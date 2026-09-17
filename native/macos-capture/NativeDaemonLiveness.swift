import Foundation

// The private command pipe has one owner. Any decoded command proves daemon
// liveness; a dedicated heartbeat is needed only when that pipe is otherwise
// idle. Keep the three-second orphan/input bound independent of rendering.
final class NativeDaemonLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var commandAt: UInt64
    private var heartbeatAt: UInt64
    private var lastKind = "startup"

    init(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        commandAt = now; heartbeatAt = now
    }

    func receive(_ kind: String, now: UInt64? = nil) {
        lock.withLock {
            let instant = now ?? DispatchTime.now().uptimeNanoseconds
            commandAt = instant; lastKind = String(kind.prefix(32))
            if kind == "heartbeat" { heartbeatAt = instant }
        }
    }

    func timeoutDiagnostic(now: UInt64? = nil) -> String? {
        lock.withLock {
            let instant = now ?? DispatchTime.now().uptimeNanoseconds
            guard instant > commandAt, instant - commandAt > 3_000_000_000 else { return nil }
            return "native daemon heartbeat expired: commandAgeMs=\((instant - commandAt) / 1_000_000) heartbeatAgeMs=\((instant - min(instant, heartbeatAt)) / 1_000_000) lastCommand=\(lastKind)"
        }
    }
}
