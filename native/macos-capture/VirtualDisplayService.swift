import AppKit
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

// Private APIs are resolved at runtime. No dependency on BetterDisplay, no
// permanent display preferences, and no claim of support from OS version alone.
private enum VirtualDisplayAPI {
    typealias Enabled = @convention(c) (CGDisplayConfigRef?, UInt32, Bool) -> Int32
    static let enabled: Enabled? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Enabled.self)
    }()
    static var available: Bool {
        ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
            .allSatisfy { NSClassFromString($0) != nil }
    }
    static func create(width: Int, height: Int, scale: Int) throws -> NSObject {
        guard let display = DieterCreateVirtualDisplay(UInt32(width), UInt32(height), UInt32(scale)) else {
            throw CaptureError.invalidArgument("macOS could not create this virtual display mode")
        }
        return display
    }

}

struct VirtualDesktopState: Codable {
    var active = false
    var displayId = ""
    var pixelWidth = 0
    var pixelHeight = 0
    var scale = 1
    var awaitingPresentation = false
    var physicalDisabled = false
    var originalDisplayId = ""
}

private struct VirtualDisplayOriginal: Codable {
    var id: UInt32
    var uuid: String
    var x: Int32
    var y: Int32
    var mode: Int32
    var appliedX: Int32?
    var appliedY: Int32?
    static func identity(_ id: UInt32) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    var present: Bool { !uuid.isEmpty && Self.identity(id) == uuid }
    // WindowServer hides a disabled output's UUID. Only a journaled disable
    // permits this ambiguity, and restoration must verify identity after enable.
    var mayBeDisabled: Bool {
        let current = Self.identity(id)
        return !uuid.isEmpty && (current.isEmpty || current == uuid)
    }
}

private struct VirtualDisplayRecovery: Codable {
    var leaseID = UUID().uuidString
    var originals: [VirtualDisplayOriginal]
    var originalMain: UInt32
    var virtualID: UInt32 = 0
    var shift: Int32
    var disabled = false
}

// Writes use the daemon's central cross-process writer lock and atomic rename.
// The independent watchdog reads this before a helper is allowed to disable a
// physical display, so SIGKILL cannot discard the only restoration information.
private final class VirtualDisplayJournal {
    let root: String
    var path: String { root + "/virtual-display/recovery.json" }
    init(root: String) throws {
        guard root.hasPrefix("/") else { throw CaptureError.invalidArgument("virtual display state root") }
        self.root = root
        try FileManager.default.createDirectory(
            atPath: root + "/virtual-display", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }
    func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = open(root + "/.writer-admission", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CaptureError.invalidArgument("virtual display journal lock") }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
                throw CaptureError.invalidArgument("virtual display journal busy")
            }
            usleep(5_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    func guardLock() throws -> Int32 {
        let fd = open(root + "/virtual-display/watchdog.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            throw CaptureError.invalidArgument("Previous virtual display watchdog is still restoring")
        }
        return fd
    }
    func write(_ recovery: VirtualDisplayRecovery) throws {
        try locked {
            let data = try JSONEncoder().encode(recovery)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic, .completeFileProtectionUnlessOpen])
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw CaptureError.invalidArgument("virtual display journal") }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw CaptureError.invalidArgument("virtual display journal sync") }
            let directory = open(root + "/virtual-display", O_RDONLY | O_NOFOLLOW)
            guard directory >= 0 else { throw CaptureError.invalidArgument("virtual display directory sync") }
            defer { close(directory) }
            guard fsync(directory) == 0 else { throw CaptureError.invalidArgument("virtual display directory sync") }
        }
    }
    func read() throws -> VirtualDisplayRecovery? {
        try locked {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard data.count <= 65536 else { throw CaptureError.invalidArgument("virtual display journal size") }
            return try JSONDecoder().decode(VirtualDisplayRecovery.self, from: data)
        }
    }
    func clear(_ leaseID: String) throws {
        try locked {
            guard FileManager.default.fileExists(atPath: path) else { return }
            let current = try JSONDecoder().decode(
                VirtualDisplayRecovery.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            if current.leaseID == leaseID { try FileManager.default.removeItem(atPath: path) }
        }
    }
}

private final class VirtualDesktopDriver {
    let journal: VirtualDisplayJournal
    let dryRun: Bool
    private var display: NSObject?
    private var recovery: VirtualDisplayRecovery?
    private var disableRequested = false
    private var watchdog: Process?
    private var heartbeat: FileHandle?
    private(set) var state = VirtualDesktopState()
    init(root: String, dryRun: Bool) throws { journal = try VirtualDisplayJournal(root: root); self.dryRun = dryRun }

    private static func geometryMatches(_ id: UInt32, width: Int, height: Int, scale: Int) -> Bool {
        let bounds = CGDisplayBounds(id)
        let pixels = nativeDisplayPixelSize(id)
        // Virtual displays can have no CGDisplayMode (including on macOS 27).
        // Query the actual framebuffer and logical desktop independently.
        return CGDisplayIsActive(id) == 1 && pixels.width == width
            && pixels.height == height
            && bounds.width == Double(width / scale) && bounds.height == Double(height / scale)
    }

    static func restore(_ snapshot: VirtualDisplayRecovery, session: Bool) throws {
        guard let main = snapshot.originals.first(where: { $0.id == snapshot.originalMain }),
            main.present || (snapshot.disabled && main.mayBeDisabled)
        else {
            // An unplugged original monitor must not erase the journal or destroy
            // the remaining virtual desktop. Reconnect it, then retry restoration.
            throw CaptureError.invalidArgument("Original physical display is unavailable; reconnect it to restore")
        }
        let originals = snapshot.originals.filter {
            $0.present || (snapshot.disabled && $0.id == main.id && $0.mayBeDisabled)
        }
        let ownedLayout =
            CGMainDisplayID() == snapshot.virtualID
            && originals.allSatisfy {
                let bounds = CGDisplayBounds($0.id)
                return CGDisplayIsActive($0.id) != 1
                    || (Int32(bounds.origin.x) == ($0.appliedX ?? $0.x + snapshot.shift)
                        && Int32(bounds.origin.y) == ($0.appliedY ?? $0.y))
            }
        // CoreGraphics returns -1, not just 0, after a disabled output vanishes
        // from its public display catalog. Only 1 proves an active output.
        let needsEnable = snapshot.disabled && CGDisplayIsActive(main.id) != 1
        if needsEnable {
            // Commit enabling separately: UUID and geometry are unavailable
            // while disabled, and must be verified before any layout mutation.
            var enableConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&enableConfig) == .success else {
                throw CaptureError.invalidArgument("physical display restore configuration")
            }
            guard let enabled = VirtualDisplayAPI.enabled, enabled(enableConfig, main.id, true) == 0 else {
                CGCancelDisplayConfiguration(enableConfig)
                throw CaptureError.invalidArgument("physical display re-enable")
            }
            guard CGCompleteDisplayConfiguration(enableConfig, session ? .forSession : .forAppOnly) == .success else {
                throw CaptureError.invalidArgument("physical display re-enable commit")
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while ProcessInfo.processInfo.systemUptime < deadline {
                if main.present && CGDisplayIsActive(main.id) == 1 { break }
                CFRunLoopRunInMode(.defaultMode, 0.025, false)
                usleep(25_000)
            }
            guard main.present && CGDisplayIsActive(main.id) == 1 else {
                throw CaptureError.invalidArgument("physical display identity after restoration not verified")
            }
        }
        if !ownedLayout && !needsEnable { return }  // WindowServer or a local change already restored it.
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw CaptureError.invalidArgument("display restore configuration")
        }
        var completed = false
        defer { if !completed { CGCancelDisplayConfiguration(config) } }
        if ownedLayout {
            for original in originals where original.present {
                guard CGConfigureDisplayOrigin(config, original.id, original.x, original.y) == .success else {
                    throw CaptureError.invalidArgument("display origin restore")
                }
            }
        }
        guard CGCompleteDisplayConfiguration(config, session ? .forSession : .forAppOnly) == .success else {
            throw CaptureError.invalidArgument("display restore")
        }
        completed = true
        guard main.present && CGDisplayIsActive(main.id) == 1 else {
            throw CaptureError.invalidArgument("physical display restoration not verified")
        }
    }

    func create(width: Int, height: Int, scale: Int, disable: Bool) throws -> VirtualDesktopState {
        guard !state.active, (320...3840).contains(width), (180...2160).contains(height), [1, 2].contains(scale),
            width % (2 * scale) == 0, height % (2 * scale) == 0
        else { throw CaptureError.invalidArgument("virtual display dimensions or active lease") }
        guard dryRun || VirtualDisplayAPI.available else {
            throw CaptureError.invalidArgument("Virtual display API unavailable")
        }
        guard
            !disable || dryRun
                || (ProcessInfo.processInfo.environment["DIETER_SCREEN_VIRTUAL_DISABLE"] == "1"
                    && VirtualDisplayAPI.enabled != nil)
        else { throw CaptureError.invalidArgument("Physical display disabling is not qualified on this host") }
        if dryRun {
            disableRequested = disable
            state = VirtualDesktopState(
                active: true, displayId: "virtual-synthetic", pixelWidth: width, pixelHeight: height, scale: scale,
                awaitingPresentation: disable, originalDisplayId: "synthetic")
            return state
        }
        // An older watchdog must finish before a new lease can reuse the journal.
        let guardFD = try journal.guardLock()
        close(guardFD)
        if let stale = try journal.read() { try Self.restore(stale, session: true); try journal.clear(stale.leaseID) }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success, count > 0, count < 32 else {
            throw CaptureError.noDisplay
        }
        let main = CGMainDisplayID()
        let originals = try ids.prefix(Int(count)).map { id -> VirtualDisplayOriginal in
            guard CGDisplayIsInMirrorSet(id) == 0, let mode = CGDisplayCopyDisplayMode(id) else {
                throw CaptureError.invalidArgument("Mirrored displays are not supported")
            }
            let bounds = CGDisplayBounds(id)
            return VirtualDisplayOriginal(
                id: id, uuid: VirtualDisplayOriginal.identity(id), x: Int32(bounds.origin.x), y: Int32(bounds.origin.y),
                mode: mode.ioDisplayModeID)
        }
        // The original main must be physical; never disable a third-party virtual display.
        guard
            !disable
                || (CGDisplayVendorNumber(main) != 0 && CGDisplayVendorNumber(main) != 0x4449
                    && CGDisplayModelNumber(main) != 0x76697274)
        else {
            throw CaptureError.invalidArgument("Cannot identify the original physical main display")
        }
        var snapshot = VirtualDisplayRecovery(
            originals: originals, originalMain: main, shift: Int32(width / scale + 64) - (originals.map(\.x).min() ?? 0)
        )
        try journal.write(snapshot)
        recovery = snapshot
        do {
            display = try VirtualDisplayAPI.create(width: width, height: height, scale: scale)
            guard let id = (display?.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else {
                throw CaptureError.noDisplay
            }
            snapshot.virtualID = id; recovery = snapshot; try journal.write(snapshot)
            // Wait for the exact backing/logical geometry before making it main.
            let modeDeadline = ProcessInfo.processInfo.systemUptime + 3
            var selectedMode = false
            while ProcessInfo.processInfo.systemUptime < modeDeadline {
                if Self.geometryMatches(id, width: width, height: height, scale: scale) {
                    selectedMode = true
                    break
                }
                let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
                let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
                if let mode = modes.first(where: {
                    $0.pixelWidth == width && $0.pixelHeight == height
                        && $0.width == width / scale && $0.height == height / scale
                }), CGDisplaySetDisplayMode(id, mode, nil) == .success {
                    continue
                }
                _ = DieterSelectVirtualDisplayMode(id, UInt32(width), UInt32(height), UInt32(scale))
                CFRunLoopRunInMode(.defaultMode, 0.025, false)
                usleep(25_000)
            }
            guard selectedMode else {
                throw CaptureError.invalidArgument(
                    "Virtual display geometry unavailable: pixels=\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) bounds=\(CGDisplayBounds(id)) expected=\(width)x\(height) scale=\(scale)"
                )
            }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else {
                throw CaptureError.invalidArgument("virtual display arrangement")
            }
            var complete = false
            defer { if !complete { CGCancelDisplayConfiguration(config) } }
            for original in originals {
                guard CGConfigureDisplayOrigin(config, original.id, original.x + snapshot.shift, original.y) == .success
                else { throw CaptureError.invalidArgument("virtual display arrangement") }
            }
            guard CGConfigureDisplayOrigin(config, id, 0, 0) == .success,
                CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
            else { throw CaptureError.invalidArgument("virtual display main") }
            complete = true
            let geometryDeadline = ProcessInfo.processInfo.systemUptime + 2
            while ProcessInfo.processInfo.systemUptime < geometryDeadline {
                if CGMainDisplayID() == id, Self.geometryMatches(id, width: width, height: height, scale: scale) {
                    break
                }
                usleep(25_000)
            }
            guard CGMainDisplayID() == id, Self.geometryMatches(id, width: width, height: height, scale: scale)
            else {
                throw CaptureError.invalidArgument(
                    "virtual geometry: main=\(CGMainDisplayID()) expected=\(id) pixels=\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) expected=\(width)x\(height)"
                )
            }
            disableRequested = disable
            // WindowServer snaps gaps between monitors. Journal the actual
            // applied layout so audits distinguish that from a later local edit.
            for index in snapshot.originals.indices {
                let bounds = CGDisplayBounds(snapshot.originals[index].id)
                snapshot.originals[index].appliedX = Int32(bounds.origin.x)
                snapshot.originals[index].appliedY = Int32(bounds.origin.y)
            }
            recovery = snapshot
            try journal.write(snapshot)
            state = VirtualDesktopState(
                active: true, displayId: String(id), pixelWidth: width, pixelHeight: height, scale: scale,
                awaitingPresentation: disable, originalDisplayId: String(main))
            try startWatchdog()
            return state
        } catch { _ = try? restore(); throw error }
    }
    private func startWatchdog() throws {
        let process = Process(), pipe = Pipe(), ready = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [
            "--virtual-display-watchdog", "--state-root", journal.root, "--lease-id", recovery!.leaseID,
        ]
        process.standardInput = pipe
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice
        try process.run()
        pipe.fileHandleForReading.closeFile()
        ready.fileHandleForWriting.closeFile()
        watchdog = process; heartbeat = pipe.fileHandleForWriting
        defer { ready.fileHandleForReading.closeFile() }
        var descriptor = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var byte: UInt8 = 0
        guard poll(&descriptor, 1, 2000) > 0, read(descriptor.fd, &byte, 1) == 1, byte == 1 else {
            throw CaptureError.invalidArgument("Virtual display watchdog did not become ready")
        }
        try heartbeat?.write(contentsOf: Data([1]))
    }

    func confirm() throws -> VirtualDesktopState {
        guard state.active else { throw CaptureError.invalidArgument("No virtual display lease") }
        if !disableRequested || state.physicalDisabled { return state }
        if !dryRun {
            guard watchdog?.isRunning == true, var snapshot = recovery, CGMainDisplayID() == snapshot.virtualID,
                let enabled = VirtualDisplayAPI.enabled
            else { throw CaptureError.invalidArgument("Virtual display recovery unavailable") }
            snapshot.disabled = true
            try journal.write(snapshot); recovery = snapshot
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else {
                throw CaptureError.invalidArgument("physical display configuration")
            }
            guard enabled(config, snapshot.originalMain, false) == 0 else {
                CGCancelDisplayConfiguration(config); throw CaptureError.invalidArgument("physical display disabling")
            }
            guard CGCompleteDisplayConfiguration(config, .forAppOnly) == .success,
                CGDisplayIsActive(snapshot.originalMain) != 1
            else { throw CaptureError.invalidArgument("Physical display disabling was not verified") }
        }
        state.physicalDisabled = true; state.awaitingPresentation = false
        return state
    }
    func audit() throws {
        guard state.active, !dryRun else { return }
        // A sleep/wake or local arrangement change ends the lease instead of
        // fighting the user. The daemon sees EOF and closes the owning session.
        guard let snapshot = recovery, CGMainDisplayID() == snapshot.virtualID,
            Self.geometryMatches(
                snapshot.virtualID, width: state.pixelWidth, height: state.pixelHeight, scale: state.scale),
            snapshot.originals.allSatisfy({ original in
                if snapshot.disabled && original.id == snapshot.originalMain {
                    return original.mayBeDisabled && CGDisplayIsActive(original.id) != 1
                }
                let bounds = CGDisplayBounds(original.id)
                return original.present && CGDisplayIsActive(original.id) == 1
                    && Int32(bounds.origin.x) == original.appliedX && Int32(bounds.origin.y) == original.appliedY
                    && CGDisplayCopyDisplayMode(original.id)?.ioDisplayModeID == original.mode
            }),
            watchdog?.isRunning == true
        else { throw CaptureError.invalidArgument("Virtual display changed locally") }
        try heartbeat?.write(contentsOf: Data([1]))
    }
    @discardableResult func restore() throws -> VirtualDesktopState {
        if !dryRun, let recovery { try Self.restore(recovery, session: false) }
        display = nil  // Physical output is verified before dropping the virtual display.
        if !dryRun, let recovery { try journal.clear(recovery.leaseID) }
        recovery = nil; state = VirtualDesktopState()
        heartbeat?.closeFile(); heartbeat = nil
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while watchdog?.isRunning == true, ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        guard watchdog?.isRunning != true else {
            // Never kill the independent recovery owner to satisfy a deadline.
            throw CaptureError.invalidArgument("Virtual display watchdog is still exiting")
        }
        watchdog = nil
        return state
    }
}

enum VirtualDisplayService {
    private static let displayChanged: CGDisplayReconfigurationCallBack = { _, _, _ in }
    static var supported: Bool { VirtualDisplayAPI.available }
    static var disablingSupported: Bool { VirtualDisplayAPI.enabled != nil }
    private struct Request: Decodable {
        var action: String
        var pixelWidth: Int?
        var pixelHeight: Int?
        var scale: Int?
        var disablePhysical: Bool?
    }
    static func run(root: String, dryRun: Bool) throws {
        signal(SIGPIPE, SIG_IGN)
        if !dryRun { CGDisplayRegisterReconfigurationCallback(displayChanged, nil) }
        defer { if !dryRun { CGDisplayRemoveReconfigurationCallback(displayChanged, nil) } }
        let driver = try VirtualDesktopDriver(root: root, dryRun: dryRun)
        let ownerFD = open(root + "/virtual-display/owner.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard ownerFD >= 0, flock(ownerFD, LOCK_EX | LOCK_NB) == 0 else {
            if ownerFD >= 0 { close(ownerFD) };
            throw CaptureError.invalidArgument("Another virtual display helper owns this host")
        }
        defer { close(ownerFD) }
        defer { _ = try? driver.restore() }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        var pending = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        while true {
            CFRunLoopRunInMode(.defaultMode, 0.001, false)
            var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, 3500) > 0 else { return }
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            guard count > 0 else { return }
            pending.append(contentsOf: bytes.prefix(count)); guard pending.count <= 8192 else { return }
            while let end = pending.firstIndex(of: 10) {
                let request = try decoder.decode(Request.self, from: pending.prefix(upTo: end));
                pending.removeSubrange(...end)
                var reply: [String: Any]
                do {
                    let result: VirtualDesktopState
                    switch request.action {
                    case "create":
                        result = try driver.create(
                            width: request.pixelWidth ?? 0, height: request.pixelHeight ?? 0, scale: request.scale ?? 0,
                            disable: request.disablePhysical ?? false)
                    case "confirm": result = try driver.confirm()
                    case "restore": result = try driver.restore()
                    case "heartbeat", "status": try driver.audit(); result = driver.state
                    default: throw CaptureError.invalidArgument("virtual display action")
                    }
                    reply = ["result": try JSONSerialization.jsonObject(with: encoder.encode(result))]
                } catch {
                    // A failed mutation is uncertain. Restore before returning an
                    // error; if that fails the watchdog retains the recovery journal.
                    _ = try? driver.restore()
                    reply = ["error": String(error.localizedDescription.prefix(1024))]
                }
                var raw = try JSONSerialization.data(withJSONObject: reply); raw.append(10)
                guard raw.count < 8192,
                    raw.withUnsafeBytes({ write(STDOUT_FILENO, $0.baseAddress, $0.count) }) == raw.count
                else { return }
            }
        }
    }
    static func watchdog(root: String, leaseID: String) throws {
        let journal = try VirtualDisplayJournal(root: root)
        let guardFD = try journal.guardLock()
        defer { close(guardFD) }
        var ready: UInt8 = 1
        guard write(STDOUT_FILENO, &ready, 1) == 1 else { throw CaptureError.invalidArgument("watchdog ready reply") }
        var bytes = [UInt8](repeating: 0, count: 128)
        while true {
            var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&fd, 1, 4500) <= 0 || read(STDIN_FILENO, &bytes, bytes.count) <= 0 { break }
        }
        if let recovery = try journal.read(), recovery.leaseID == leaseID {
            try VirtualDesktopDriver.restore(recovery, session: true)
            try journal.clear(recovery.leaseID)
        }
    }
}
