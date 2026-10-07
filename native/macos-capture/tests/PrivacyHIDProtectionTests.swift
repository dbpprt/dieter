import Darwin
import Foundation
import Security

private final class TestHIDDriver: PrivacyHIDDriver {
    var held = false
    var count = 2
    var failure = false
    func availability() throws {}
    func acquire() throws { held = true }
    func audit() throws -> Int {
        if failure { throw PrivacyHIDError("new keyboard cannot be seized") }
        return count
    }
    func release() throws {
        if failure { throw PrivacyHIDError("device restoration failed") }
        held = false
    }
}

@main enum HIDProtectionTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--auth-client" {
            try authenticationClient(CommandLine.arguments[2])
            return
        }
        try testCallerAuthentication()
        let driver = TestHIDDriver()
        let lease = PrivacyHIDLease(driver: driver)
        precondition(!lease.perform("status", uid: 501).active && !driver.held)
        let enabled = lease.perform("on", uid: 501)
        precondition(enabled.active && enabled.available && enabled.deviceCount == 2)
        precondition(driver.held)
        // Disconnects, duplicate acquisition and another login cannot release it.
        precondition(lease.perform("on", uid: 501).generation == enabled.generation)
        precondition(!lease.perform("off", uid: 502).available && driver.held)
        driver.count = 3
        precondition(lease.perform("status", uid: 501).deviceCount == 3)
        driver.failure = true
        precondition(!lease.perform("status", uid: 501).active)
        precondition(!lease.perform("off", uid: 501).available && lease.owner == 501 && driver.held)
        driver.failure = false
        precondition(lease.perform("status", uid: 501).active)
        precondition(!lease.perform("off", uid: 501).active && lease.owner == nil && !driver.held)
        precondition(!PrivacyHIDLease(driver: TestHIDDriver()).perform("status", uid: 501).active)
        // A replacement service cannot be mistaken for the old protection lease.
        precondition(PrivacyHIDLease(driver: TestHIDDriver()).generation != enabled.generation)
        precondition(!PrivacyHIDConnection.authorized(-1, identifier: "com.dbpprt.dieter.capture"))
        print(
            "Privileged HID lease: ownership, disconnect lifetime, hot-plug failure, retryable restoration and restart identity passed"
        )
    }

    // Exercise the kernel peer token and Security framework with a live signed
    // caller. The test gets no exemption in the production helper.
    private static func testCallerAuthentication() throws {
        var code: SecCode?
        precondition(SecCodeCopySelf([], &code) == errSecSuccess)
        var staticCode: SecStaticCode?
        precondition(SecCodeCopyStaticCode(code!, [], &staticCode) == errSecSuccess)
        var info: CFDictionary?
        precondition(SecCodeCopySigningInformation(staticCode!, [], &info) == errSecSuccess)
        let hash = ((info! as NSDictionary)[kSecCodeInfoUnique] as! Data)
            .map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(server >= 0)
        defer { close(server) }
        var address = socketAddress(path)
        precondition(
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            } == 0)
        precondition(listen(server, 1) == 0)
        let caller = Process()
        caller.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        caller.arguments = ["--auth-client", path]
        try caller.run()
        defer { if caller.isRunning { caller.terminate(); caller.waitUntilExit() } }
        var ready = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        precondition(poll(&ready, 1, 5000) == 1)
        let client = accept(server, nil, nil)
        precondition(client >= 0)
        defer { close(client) }
        precondition(
            PrivacyHIDConnection.authorized(client, identifier: "com.dbpprt.dieter.capture", developmentHash: hash))
        precondition(
            !PrivacyHIDConnection.authorized(
                client, identifier: "com.dbpprt.dieter.capture", developmentHash: String(repeating: "0", count: 40)))
        precondition(!PrivacyHIDConnection.authorized(client, identifier: "com.dbpprt.dieter.capture"))
        var reply: UInt8 = 1
        precondition(write(client, &reply, 1) == 1)
        caller.waitUntilExit()
        precondition(caller.terminationStatus == 0)
        print("Live caller authentication: exact signed code accepted, wrong code hash and release identity rejected")
    }

    private static func socketAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func authenticationClient(_ path: String) throws {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(client >= 0)
        defer { close(client) }
        var address = socketAddress(path)
        precondition(
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            } == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var reply: UInt8 = 0
        precondition(read(client, &reply, 1) == 1 && reply == 1)
    }
}
