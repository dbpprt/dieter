import Darwin
import Foundation
import Security

struct PrivacyHIDStatus: Codable {
    var available = false
    var active = false
    var deviceCount = 0
    var generation = ""
    var reason = ""
}

struct PrivacyHIDError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

// launchd owns this transient socket. No privileged code accepts a filesystem
// path, executable, shell command, or persistent state from a client.
enum PrivacyHIDConnection {
    static let socketPath = "/var/run/com.dbpprt.dieter.privacy.sock"
    static let team = "DS6N5L85E7"

    static func authorized(_ fd: Int32, identifier: String, developmentHash: String? = nil) -> Bool {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, 0, LOCAL_PEERTOKEN, &token, &size) == 0,
            size == MemoryLayout<audit_token_t>.size
        else { return false }
        let audit = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: audit] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }
        // Development artifacts trust only the exact capture binary built with
        // this bundle. Releases always require Apple's signature and our team.
        let expression: String
        if let hash = developmentHash, hash.count == 40, hash.allSatisfy({ $0.isHexDigit }) {
            expression = "cdhash H\"\(hash)\""
        } else {
            expression =
                "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func exchange(_ action: String) throws -> PrivacyHIDStatus {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PrivacyHIDError("Cannot contact the privacy input helper") }
        defer { close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw PrivacyHIDError(
                "Set up the privacy helper on this Mac, then approve it in System Settings > General > Login Items & Extensions"
            )
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else {
            throw PrivacyHIDError("Privacy input helper is not privileged")
        }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let raw = Data((action + "\n").utf8)
        guard raw.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == raw.count else {
            throw PrivacyHIDError("Privacy input helper did not accept the request")
        }
        var reply = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while reply.count < 8192 && !reply.contains(10) {
            let count = read(fd, &buffer, min(buffer.count, 8192 - reply.count))
            guard count > 0 else { throw PrivacyHIDError("Privacy input helper did not reply") }
            reply.append(contentsOf: buffer.prefix(count))
        }
        guard let end = reply.firstIndex(of: 10) else {
            throw PrivacyHIDError("Privacy input helper returned an oversized reply")
        }
        let value = try JSONDecoder().decode(PrivacyHIDStatus.self, from: reply.prefix(upTo: end))
        guard (0...128).contains(value.deviceCount), value.reason.utf8.count <= 1024,
            value.generation.count <= 64, !value.active || value.available
        else { throw PrivacyHIDError("Privacy input helper returned an invalid status") }
        return value
    }
}

// Capture-side monitoring must not silently reacquire after a privileged
// service restart. Explicit on is the only operation that adopts a new epoch.
final class PrivacyHIDMonitor {
    private let exchange: (String) throws -> PrivacyHIDStatus
    private let requestLock: () -> Void
    private var generation = ""
    private var lockRequested = false
    private(set) var deviceCount = 0
    init(
        exchange: @escaping (String) throws -> PrivacyHIDStatus = PrivacyHIDConnection.exchange,
        requestLock: @escaping () -> Void
    ) {
        self.exchange = exchange; self.requestLock = requestLock
    }
    func acquire() throws {
        let input = try exchange("on")
        guard input.available && input.active && !input.generation.isEmpty else {
            throw PrivacyHIDError(input.reason.isEmpty ? "Input device protection did not activate" : input.reason)
        }
        generation = input.generation; deviceCount = input.deviceCount; lockRequested = false
    }
    func audit() throws {
        do {
            let input = try exchange("status")
            guard input.available && input.active && input.generation == generation else {
                throw PrivacyHIDError(
                    input.reason.isEmpty
                        ? "Privacy input helper restarted or lost exclusive input protection" : input.reason)
            }
            deviceCount = input.deviceCount
        } catch {
            protectionLost()
            throw error
        }
    }
    func protectionLost() {
        if !lockRequested && !generation.isEmpty { lockRequested = true; requestLock() }
    }
    func release() throws {
        let input = try exchange("off")
        guard input.available && !input.active else {
            throw PrivacyHIDError(input.reason.isEmpty ? "Cannot restore local input; retry unlock" : input.reason)
        }
        generation = ""; deviceCount = 0; lockRequested = false
    }
}
