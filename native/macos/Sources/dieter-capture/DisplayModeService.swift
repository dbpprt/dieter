import CoreGraphics
import Foundation

struct DesktopMode: Codable, Equatable {
    var id: String
    var logicalWidth: Int
    var logicalHeight: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double
}

struct DesktopModes: Codable {
    var displayId: String
    var modes: [DesktopMode]
    var currentModeId: String
    var originalModeId = ""
    var temporary = false
    var superseded = false
}

protocol DesktopModeDriver {
    func snapshot(_ display: String) throws -> DesktopModes
    func apply(_ display: String, mode: String) throws
}

struct SystemDesktopModeDriver: DesktopModeDriver {
    private func display(_ value: String) throws -> CGDirectDisplayID {
        let id = value == "primary" ? CGMainDisplayID() : UInt32(value) ?? 0
        guard id != 0, CGDisplayIsOnline(id) != 0, CGDisplayIsInMirrorSet(id) == 0 else {
            throw CaptureError.invalidArgument("Display is unavailable or mirrored")
        }
        return id
    }
    private func identifier(_ display: CGDirectDisplayID, _ mode: CGDisplayMode) -> String {
        return
            "\(display):\(CGDisplayVendorNumber(display)):\(CGDisplayModelNumber(display)):\(CGDisplaySerialNumber(display)):\(mode.ioDisplayModeID):\(mode.pixelWidth)x\(mode.pixelHeight)"
    }
    private func modes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() && $0.width >= 320 && $0.height >= 180 }
    }
    func snapshot(_ value: String) throws -> DesktopModes {
        let id = try display(value)
        guard let current = CGDisplayCopyDisplayMode(id) else {
            throw CaptureError.invalidArgument("Display has no mode")
        }
        var available = modes(id)
        available.removeAll { $0.ioDisplayModeID == current.ioDisplayModeID }
        available.insert(current, at: 0)
        return DesktopModes(
            displayId: String(id),
            modes: available.prefix(256).map {
                DesktopMode(
                    id: identifier(id, $0), logicalWidth: $0.width, logicalHeight: $0.height,
                    pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight, refreshRate: $0.refreshRate)
            }, currentModeId: identifier(id, current))
    }
    func apply(_ value: String, mode: String) throws {
        let id = try display(value)
        guard let selected = modes(id).first(where: { identifier(id, $0) == mode }) else {
            throw CaptureError.invalidArgument("Display mode is no longer available")
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw CaptureError.invalidArgument("Cannot begin display configuration")
        }
        guard CGConfigureDisplayWithDisplayMode(config, id, selected, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            throw CaptureError.invalidArgument("Cannot configure display mode")
        }
        // WindowServer rolls this back even if the daemon/helper crashes. Never
        // change the user's permanent display preferences or capture the display.
        guard CGCompleteDisplayConfiguration(config, .forAppOnly) == .success else {
            throw CaptureError.invalidArgument("macOS rejected this display mode")
        }
    }
}

// One helper owns one temporary display lease. Its IPC and heartbeat lifetime
// are independent of video encoders and spectator sessions.
final class DesktopModeLease {
    let driver: any DesktopModeDriver
    private var lease: (display: String, original: String, applied: String)?
    init(driver: any DesktopModeDriver) { self.driver = driver }

    func list(_ display: String) throws -> DesktopModes {
        var result = try driver.snapshot(display)
        if let lease, lease.display == result.displayId {
            result.originalModeId = lease.original
            result.temporary = result.currentModeId == lease.applied
            result.superseded = !result.temporary
        }
        return result
    }
    func set(_ display: String, mode: String, expected: String) throws -> DesktopModes {
        let before = try list(display)
        guard before.currentModeId == expected, !before.superseded,
            before.modes.contains(where: { $0.id == mode })
        else { throw CaptureError.invalidArgument("Display changed; refresh its supported modes") }
        if let lease, lease.display != before.displayId {
            throw CaptureError.invalidArgument("Restore the previous display before switching displays")
        }
        if before.currentModeId == mode { return before }
        let previous = lease
        lease = (before.displayId, lease?.original ?? before.currentModeId, mode)
        do {
            try driver.apply(before.displayId, mode: mode)
            if lease?.original == mode { lease = nil }
            let result = try list(before.displayId)
            guard result.currentModeId == mode else {
                throw CaptureError.invalidArgument("Display did not accept the mode")
            }
            return result
        } catch {
            // Restore only a change we actually applied, never a subsequent local change.
            if (try? driver.snapshot(before.displayId).currentModeId) == mode {
                try? driver.apply(before.displayId, mode: before.currentModeId)
            }
            lease = previous
            throw error
        }
    }
    func restore(_ display: String) throws -> DesktopModes {
        var superseded = false
        if let lease {
            if let current = try? driver.snapshot(lease.display) {
                superseded = current.currentModeId != lease.applied
                if !superseded { try driver.apply(lease.display, mode: lease.original) }
            }
            self.lease = nil
        }
        var result = try driver.snapshot(display)
        result.superseded = superseded
        return result
    }
    func restoreOnExit() {
        if let lease { _ = try? restore(lease.display) }
    }
}

// Only selected by the disposable native fixture's --dry-run argument.
final class SyntheticDesktopModeDriver: DesktopModeDriver {
    private var current: [String: String] = [:]
    func snapshot(_ display: String) throws -> DesktopModes {
        let id = display == "primary" ? "synthetic" : display
        return DesktopModes(
            displayId: id,
            modes: [
                DesktopMode(
                    id: "1080", logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 1920, pixelHeight: 1080,
                    refreshRate: 60),
                DesktopMode(
                    id: "720", logicalWidth: 1280, logicalHeight: 720, pixelWidth: 1280, pixelHeight: 720,
                    refreshRate: 60),
            ], currentModeId: current[id] ?? "1080")
    }
    func apply(_ display: String, mode: String) throws { current[display] = mode }
}

enum DisplayModeService {
    private struct Request: Decodable {
        var action: String
        var displayId: String
        var modeId: String
        var expectedCurrentModeId: String
    }
    private struct Reply: Encodable {
        var result: DesktopModes?
        var error: String?
    }
    static func run(dryRun: Bool) {
        signal(SIGPIPE, SIG_IGN)
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        let lease = DesktopModeLease(driver: dryRun ? SyntheticDesktopModeDriver() : SystemDesktopModeDriver())
        defer { lease.restoreOnExit() }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        var pending = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 3500) > 0 else { return }
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            guard count > 0 else { return }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count <= 8192 else { return }
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                guard let request = try? decoder.decode(Request.self, from: line) else { return }
                pending.removeSubrange(...end)
                var reply = Reply()
                do {
                    switch request.action {
                    case "list": reply.result = try lease.list(request.displayId)
                    case "set":
                        reply.result = try lease.set(
                            request.displayId, mode: request.modeId, expected: request.expectedCurrentModeId)
                    case "restore": reply.result = try lease.restore(request.displayId)
                    case "heartbeat": break
                    default: throw CaptureError.invalidArgument("display action")
                    }
                } catch { reply.error = error.localizedDescription }
                guard var data = try? encoder.encode(reply), data.count <= 131072 else { return }
                data.append(10)
                guard writeReply(data) else { return }
            }
        }
    }

    private static func writeReply(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
            while offset < bytes.count {
                let count = write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                guard errno == EAGAIN || errno == EINTR, DispatchTime.now().uptimeNanoseconds < deadline else {
                    return false
                }
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 10)
            }
            return true
        }
    }
}
