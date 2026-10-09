import Darwin
import Foundation
import IOKit.hid
import ServiceManagement
import Security
import SystemConfiguration

// Public liblaunch API from launch.h (Darwin's Swift module omits its declaration).
@_silgen_name("launch_activate_socket")
private func activateSocket(
    _ name: UnsafePointer<CChar>, _ sockets: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
    _ count: UnsafeMutablePointer<Int>
) -> Int32

enum PrivacyHIDService {
    static func handle(_ arguments: [String]) throws -> Bool {
        guard arguments.contains(where: { $0.hasPrefix("--privacy-hid-") }) else { return false }
        guard arguments.count == 1 else { throw PrivacyHIDError("Privacy service accepts exactly one internal action") }
        if arguments == ["--privacy-hid-service"] {
            guard geteuid() == 0 else { throw PrivacyHIDError("The input helper must be started by macOS as root") }
            try serve()
            return true
        }
        let service = try appService()
        if arguments == ["--privacy-hid-unregister"] {
            try service.unregister()
            return true
        }
        let value: PrivacyHIDStatus
        if arguments == ["--privacy-hid-register"] {
            value = try register()
        } else if arguments == ["--privacy-hid-status"] {
            value = status(service)
        } else {
            throw PrivacyHIDError("Unknown privacy service action")
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(value))
        return true
    }

    private static func appService() throws -> SMAppService {
        guard Bundle.main.bundleIdentifier == "com.dbpprt.dieter.privacy",
            Bundle.main.executableURL?.lastPathComponent == "dieter-privacy"
        else {
            throw PrivacyHIDError("Install DieterPrivacyHelper.app beside the daemon to set up privacy mode")
        }
        return SMAppService.daemon(plistName: "com.dbpprt.dieter.privacy.plist")
    }

    static func register() throws -> PrivacyHIDStatus {
        guard geteuid() != 0 else { throw PrivacyHIDError("Privacy setup must run as the login user") }
        let service = try appService()
        if service.status != .enabled && service.status != .requiresApproval {
            do { try service.register() } catch { if service.status != .requiresApproval { throw error } }
        }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return status(service)
    }

    private static func status(_ service: SMAppService) -> PrivacyHIDStatus {
        var value = PrivacyHIDStatus()
        value.available = service.status == .enabled
        value.reason =
            value.available
            ? ""
            : "Approve Dieter Privacy Helper in System Settings > General > Login Items & Extensions, then grant Input Monitoring"
        return value
    }

    #if DIETER_PRIVACY_DEVELOPMENT
        private static func developmentCaptureHash() throws -> String {
            var code: SecCode?, staticCode: SecStaticCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess,
                let hash = Bundle.main.object(forInfoDictionaryKey: "DieterDevelopmentCaptureHash") as? String,
                hash.count == 40, hash.allSatisfy({ $0.isHexDigit })
            else { throw PrivacyHIDError("Cannot verify this development helper's capture identity") }
            return hash
        }
    #endif

    private static func serve() throws {
        signal(SIGPIPE, SIG_IGN)
        var sockets: UnsafeMutablePointer<Int32>?, count = 0
        let result = "Control".withCString { activateSocket($0, &sockets, &count) }
        guard result == 0, count == 1, let sockets else {
            throw PrivacyHIDError("launchd did not supply the control socket")
        }
        let server = sockets[0]; free(sockets)
        defer { close(server) }
        let lease = PrivacyHIDLease(driver: SystemPrivacyHIDDriver())
        let loop = CFRunLoopGetMain()
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0
        ) { _ in
            if let owner = lease.owner { _ = lease.perform("status", uid: owner) }
        }
        CFRunLoopAddTimer(loop, timer, .commonModes)
        // There are no development authentication overrides in release builds.
        var developmentHash: String?
        #if DIETER_PRIVACY_DEVELOPMENT
            developmentHash = try developmentCaptureHash()
        #endif
        let trustedHash = developmentHash
        DispatchQueue.global().async {
            while true {
                let client = accept(server, nil, nil)
                if client < 0 { if errno == EINTR { continue }; return }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0,
                    PrivacyHIDConnection.authorized(
                        client, identifier: "com.dbpprt.dieter.capture", developmentHash: trustedHash)
                else { close(client); continue }
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var input = [UInt8](repeating: 0, count: 16)
                var request = Data()
                while request.count < input.count && !request.contains(10) {
                    let length = read(client, &input, input.count - request.count)
                    if length <= 0 { break }
                    request.append(contentsOf: input.prefix(length))
                }
                guard let action = String(data: request, encoding: .utf8),
                    ["on\n", "off\n", "status\n"].contains(action)
                else { close(client); continue }
                let done = DispatchSemaphore(value: 0)
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                    var consoleUID: uid_t = 0
                    _ = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil)
                    let value: PrivacyHIDStatus
                    if uid != consoleUID && lease.owner != uid {
                        value = .init(reason: "Privacy setup requires the current console login user")
                    } else {
                        value = lease.perform(String(action.dropLast()), uid: uid)
                    }
                    if var raw = try? JSONEncoder().encode(value) {
                        raw.append(10)
                        raw.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
                    }
                    close(client); done.signal()
                }
                CFRunLoopWakeUp(loop)
                done.wait()
            }
        }
        CFRunLoopRun()
    }
}
