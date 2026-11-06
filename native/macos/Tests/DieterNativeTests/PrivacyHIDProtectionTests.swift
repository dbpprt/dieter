import Darwin
import DieterIdentity
import Foundation
import PrivacyHIDProtocol
import Security
import Testing

@testable import dieter_privacy

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

// Ported from the former standalone native/macos-capture/tests/PrivacyHIDProtectionTests.swift.
struct PrivacyHIDProtectionTests {
    @Test func privacyServiceAdmission() throws { try testPrivacyServiceAdmission() }

    @Test func privacyHelperLocation() throws { try testPrivacyHelperLocation() }

    @Test func callerAuthentication() throws { try testCallerAuthentication() }

    @Test func protectionLease() throws {
        let driver = TestHIDDriver()
        let lease = PrivacyHIDLease(driver: driver)
        #expect(!lease.perform("status", uid: 501).active && !driver.held)
        let enabled = lease.perform("on", uid: 501)
        #expect(enabled.active && enabled.available && enabled.deviceCount == 2)
        #expect(driver.held)
        // Disconnects, duplicate acquisition and another login cannot release it.
        #expect(lease.perform("on", uid: 501).generation == enabled.generation)
        #expect(!lease.perform("off", uid: 502).available && driver.held)
        driver.count = 3
        #expect(lease.perform("status", uid: 501).deviceCount == 3)
        driver.failure = true
        #expect(!lease.perform("status", uid: 501).active)
        #expect(!lease.perform("off", uid: 501).available && lease.owner == 501 && driver.held)
        driver.failure = false
        #expect(lease.perform("status", uid: 501).active)
        #expect(!lease.perform("off", uid: 501).active && lease.owner == nil && !driver.held)
        #expect(!PrivacyHIDLease(driver: TestHIDDriver()).perform("status", uid: 501).active)
        // A replacement service cannot be mistaken for the old protection lease.
        #expect(PrivacyHIDLease(driver: TestHIDDriver()).generation != enabled.generation)
        #expect(!PrivacyHIDConnection.authorized(-1, identifier: DistributionIdentity.captureIdentifier))
        print(
            "Privileged HID lease: ownership, disconnect lifetime, hot-plug failure, retryable restoration and restart identity passed"
        )
    }

    // Exercise the kernel peer token and Security framework with a live signed
    // caller: this test process connects to its own listening socket, so the
    // peer is real signed code. The test gets no exemption in the production
    // helper.
    private func testCallerAuthentication() throws {
        var code: SecCode?
        try #require(SecCodeCopySelf([], &code) == errSecSuccess)
        let selfCode = try #require(code)
        var staticCode: SecStaticCode?
        try #require(SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess)
        let signedCode = try #require(staticCode)
        var info: CFDictionary?
        try #require(SecCodeCopySigningInformation(signedCode, [], &info) == errSecSuccess)
        let signing = try #require(info) as NSDictionary
        let unique = try #require(signing[kSecCodeInfoUnique] as? Data)
        let hash = unique.map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(server >= 0)
        defer { close(server) }
        var address = Self.socketAddress(path)
        try #require(
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            } == 0)
        try #require(listen(server, 1) == 0)
        // A Unix stream connect completes against the listen backlog.
        let caller = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(caller >= 0)
        defer { close(caller) }
        try #require(
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(caller, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            } == 0)
        let client = accept(server, nil, nil)
        try #require(client >= 0)
        defer { close(client) }
        let capture = DistributionIdentity.captureIdentifier
        #expect(PrivacyHIDConnection.authorized(client, identifier: capture, developmentHash: hash))
        #expect(
            !PrivacyHIDConnection.authorized(
                client, identifier: capture, developmentHash: String(repeating: "0", count: 40)))
        #expect(!PrivacyHIDConnection.authorized(client, identifier: capture))
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
}

private func testPrivacyServiceAdmission() throws {
    let handled = try PrivacyHIDService.handle(["--capabilities", "--synthetic", "true"])
    #expect(!handled)
    for arguments in [
        ["--privacy-hid-service", "--display-service"],
        ["--privacy-hid-register", "--privacy-directory", "/tmp/untrusted"],
        ["--privacy-hid-unknown"],
    ] {
        do {
            _ = try PrivacyHIDService.handle(arguments)
            Issue.record("Internal privacy mode accepted untrusted arguments")
        } catch is PrivacyHIDError {}
    }
    if geteuid() != 0 {
        do {
            _ = try PrivacyHIDService.handle(["--privacy-hid-service"])
            Issue.record("Unprivileged helper entered the root input service")
        } catch is PrivacyHIDError {}
    }
    print("Privacy service admission: exact internal mode and root boundary passed")
}

private func testPrivacyHelperLocation() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let capture = root.appendingPathComponent("bin/dieter-capture")
    let adjacent = root.appendingPathComponent("bin/DieterPrivacyHelper.app")
    let resource = root.appendingPathComponent("libexec/DieterPrivacyHelper.app")
    #expect(PrivacyHelperPackage.bundle(for: capture).path == adjacent.path)
    for bundle in [resource, adjacent] {
        let main = bundle.appendingPathComponent("Contents/MacOS/dieter-privacy")
        try files.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: main)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: main.path)
        // Foundation adds a directory marker once a bundle exists. Compare the
        // canonical filesystem location, independent of that URL metadata.
        #expect(PrivacyHelperPackage.bundle(for: capture).path == bundle.path)
    }
    let alias = root.appendingPathComponent("alias/dieter-capture")
    try files.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: capture)
    try files.createSymbolicLink(at: alias, withDestinationURL: capture)
    #expect(PrivacyHelperPackage.bundle(for: alias).path == adjacent.path)
    print("Privacy helper discovery: standalone, Homebrew resource and canonical symlink paths passed")
}
