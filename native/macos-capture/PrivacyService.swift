import CoreGraphics
import Darwin
import Foundation

struct PrivacySnapshot: Codable, Equatable {
    var supported = false
    var requested = false
    var state = 0  // Same values as MachinePrivacy.State.
    var reason = ""
    var displayCount = 0
    var error: String?
}

protocol PrivacyDesktopDriver: AnyObject {
    func availability() -> PrivacySnapshot
    func acquire() throws
    func maintain() throws
    func release() throws
}

// Requested state survives transport disconnects. A healthy badge requires
// both the physical display lease and the event tap to remain effective.
final class PrivacyLease {
    let driver: any PrivacyDesktopDriver
    private(set) var requested = false
    private var failure = ""
    init(driver: any PrivacyDesktopDriver) { self.driver = driver }

    func snapshot() -> PrivacySnapshot {
        var value = driver.availability()
        value.requested = requested
        value.state = requested ? (failure.isEmpty && value.supported ? 1 : 2) : 0
        if !failure.isEmpty { value.reason = failure }
        return value
    }
    func set(_ enabled: Bool) throws -> PrivacySnapshot {
        if enabled {
            guard driver.availability().supported else {
                throw CaptureError.invalidArgument(driver.availability().reason)
            }
            if !requested {
                do { try driver.acquire() } catch {
                    do { try driver.release() } catch {
                        requested = true; failure = String(error.localizedDescription.prefix(1024)); throw error
                    }
                    throw error
                }
                requested = true
            }
            do { try driver.maintain(); failure = "" } catch {
                failure = String(error.localizedDescription.prefix(1024)); throw error
            }
        } else {
            // Do not report unlocked if restoration failed. Repeating off
            // retries the owned restoration and cannot toggle protection on.
            do { try driver.release() } catch { failure = String(error.localizedDescription.prefix(1024)); throw error }
            requested = false; failure = ""
        }
        return snapshot()
    }
    func audit() {
        guard requested else { return }
        do { try driver.maintain(); failure = "" } catch { failure = String(error.localizedDescription.prefix(1024)) }
    }
}

struct PrivacyGammaTable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    static func read(_ display: CGDirectDisplayID) throws -> PrivacyGammaTable {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard (2...4096).contains(capacity) else {
            throw CaptureError.invalidArgument("This display does not support verified privacy blanking")
        }
        var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count) == .success,
            count >= 2, count <= capacity, (r + g + b).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else { throw CaptureError.invalidArgument("Cannot read this display's color transfer table") }
        return .init(
            red: Array(r.prefix(Int(count))), green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
    }
    func apply(_ display: CGDirectDisplayID) throws {
        let status = CGSetDisplayTransferByTable(display, UInt32(red.count), red, green, blue)
        guard status == .success else { throw CaptureError.invalidArgument("macOS rejected display privacy blanking") }
    }
    var black: Bool { (red + green + blue).allSatisfy { $0 <= 0.0001 } }
    static func blank(count: Int) -> PrivacyGammaTable {
        let zeros = [Float](repeating: 0, count: count)
        return .init(red: zeros, green: zeros, blue: zeros)
    }
}

// Blanking the scan-out transfer tables preserves desktop pixels for ALL
// screen-capture providers. An opaque window would hide independent agent
// screenshots. Hosts/displays that cannot round-trip these tables are refused.
final class SystemPrivacyDesktopDriver: PrivacyDesktopDriver {
    private var originals: [CGDirectDisplayID: PrivacyGammaTable] = [:]
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hiddenCursor = false
    private var disabledAt: [TimeInterval] = []

    static func displays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count <= 32 else {
            throw CaptureError.invalidArgument("Cannot enumerate physical displays")
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            throw CaptureError.invalidArgument("Cannot enumerate physical displays")
        }
        return Array(displays.prefix(Int(count)))
    }
    func availability() -> PrivacySnapshot {
        do {
            let displays = try Self.displays()
            guard CGPreflightPostEventAccess() else {
                return .init(
                    reason: "Accessibility permission is required. Run dieter daemon permissions on this Mac.",
                    displayCount: displays.count)
            }
            for display in displays { _ = try PrivacyGammaTable.read(display) }
            return .init(supported: true, displayCount: displays.count)
        } catch { return .init(reason: String(error.localizedDescription.prefix(1024))) }
    }
    static func isPhysical(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceStateID) == CGEventSourceStateID.hidSystemState.rawValue
    }
    func acquire() throws {
        guard tap == nil else { return }
        // Session taps do not require root. A HID-location tap would.
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(1) << 14) { $0 | (CGEventMask(1) << $1.rawValue) }
        let reference = Unmanaged.passUnretained(self).toOpaque()
        guard
            let next = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<SystemPrivacyDesktopDriver>.fromOpaque(info).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.disabledAt.append(Date.timeIntervalSinceReferenceDate)
                        if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    return SystemPrivacyDesktopDriver.isPhysical(event) ? nil : Unmanaged.passUnretained(event)
                }, userInfo: reference)
        else { throw CaptureError.invalidArgument("macOS could not install the local input filter") }
        tap = next
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, next, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: next, enable: true)
        if CGDisplayHideCursor(CGMainDisplayID()) == .success { hiddenCursor = true }
        do { try maintain() } catch { try? release(); throw error }
    }
    func maintain() throws {
        guard CGPreflightPostEventAccess(), let tap else {
            throw CaptureError.invalidArgument("Privacy input protection lost its Accessibility permission")
        }
        let now = Date.timeIntervalSinceReferenceDate
        disabledAt.removeAll { now - $0 > 10 }
        guard disabledAt.count < 5 else {
            throw CaptureError.invalidArgument("macOS repeatedly disabled the privacy input filter")
        }
        if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        guard CGEvent.tapIsEnabled(tap: tap) else {
            throw CaptureError.invalidArgument("The privacy input filter is not active")
        }
        let online = try Self.displays()
        for display in online {
            let current = try PrivacyGammaTable.read(display)
            if originals[display] == nil { originals[display] = current }
            if !current.black { try PrivacyGammaTable.blank(count: current.red.count).apply(display) }
            guard try PrivacyGammaTable.read(display).black else {
                throw CaptureError.invalidArgument("This display cannot confirm privacy blanking")
            }
        }
    }
    func release() throws {
        // Restore displays before releasing input. Failed restoration is retryable.
        let online = try Self.displays()
        for (display, original) in originals {
            if online.contains(display) { try original.apply(display) }
            originals.removeValue(forKey: display)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil; disabledAt = []
        if hiddenCursor { _ = CGDisplayShowCursor(CGMainDisplayID()); hiddenCursor = false }
    }
}

final class SyntheticPrivacyDesktopDriver: PrivacyDesktopDriver {
    func availability() -> PrivacySnapshot { .init(supported: true, displayCount: 1) }
    func acquire() throws {}
    func maintain() throws {}
    func release() throws {}
}

enum PrivacyService {
    static func capabilities(dryRun: Bool) {
        let driver: any PrivacyDesktopDriver = dryRun ? SyntheticPrivacyDesktopDriver() : SystemPrivacyDesktopDriver()
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? encoder.encode(driver.availability()) { FileHandle.standardOutput.write(data) }
    }
    static func run(directory: String, dryRun: Bool) throws {
        signal(SIGPIPE, SIG_IGN)
        let lockFD = open(directory + "/owner.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }; return  // A live boot owner already exists.
        }
        defer { close(lockFD) }
        let path = directory + "/control.sock"
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= capacity else { throw CaptureError.invalidArgument("Privacy socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { throw CaptureError.invalidArgument("Cannot create privacy control socket") }
        defer { close(server); unlink(path) }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK else {
                throw CaptureError.invalidArgument("Privacy control path is not a socket")
            }
            unlink(path)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(server, 4) == 0 else {
            throw CaptureError.invalidArgument("Cannot bind privacy control socket")
        }
        let lease = PrivacyLease(driver: dryRun ? SyntheticPrivacyDesktopDriver() : SystemPrivacyDesktopDriver())
        let loop = CFRunLoopGetMain()
        let startedAt = Date.timeIntervalSinceReferenceDate
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0)
        { _ in
            lease.audit()
            if !lease.requested && Date.timeIntervalSinceReferenceDate - startedAt > 10 { CFRunLoopStop(loop) }
        }
        CFRunLoopAddTimer(loop, timer, .commonModes)
        defer { CFRunLoopTimerInvalidate(timer) }
        DispatchQueue.global().async {
            while true {
                let client = accept(server, nil, nil)
                if client < 0 { if errno == EINTR { continue }; return }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); continue }
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var pending = Data(), buffer = [UInt8](repeating: 0, count: 512)
                while pending.count <= 512 && !pending.contains(10) {
                    let count = read(client, &buffer, buffer.count)
                    if count <= 0 { break }; pending.append(contentsOf: buffer.prefix(count))
                }
                guard pending.count <= 512, let end = pending.firstIndex(of: 10),
                    let request = try? JSONSerialization.jsonObject(with: pending.prefix(upTo: end))
                        as? [String: String],
                    let action = request["action"], ["on", "off", "status"].contains(action)
                else { close(client); continue }
                let done = DispatchSemaphore(value: 0)
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                    var value: PrivacySnapshot
                    do {
                        if action == "status" { lease.audit() }
                        value = action == "status" ? lease.snapshot() : try lease.set(action == "on")
                    } catch { value = lease.snapshot(); value.error = String(error.localizedDescription.prefix(1024)) }
                    let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
                    if var raw = try? encoder.encode(value) {
                        raw.append(10)
                        raw.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < bytes.count {
                                let count = write(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                                if count <= 0 { break }; offset += count
                            }
                        }
                    }
                    close(client)
                    if action == "off" && !lease.requested { CFRunLoopStop(loop) }
                    done.signal()
                }
                CFRunLoopWakeUp(loop)
                done.wait()
            }
        }
        CFRunLoopRun()
    }
}
