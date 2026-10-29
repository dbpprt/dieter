import Carbon
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt
import PrivacyHIDProtocol
import ScreenCaptureKit
import Testing

@testable import dieter_capture

// Ported from the former standalone native/macos-capture/tests/InputState.swift.
struct CaptureStateTests {
    @Test func privacyLease() throws { try testPrivacyLease() }

    @Test func privacyHIDMonitor() throws { try testPrivacyHIDMonitor() }

    // Locks this Mac's physical input through the approved capture binary named
    // by DIETER_TEST_PRIVACY_HELPER; opt-in because it owns the desktop.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIETER_TEST_PRIVACY_PHYSICAL"] == "1"))
    func privacyDesktop() async throws { try await testPrivacyDesktop() }

    @Test func remoteDisplayActivity() throws { try testRemoteDisplayActivity() }

    @Test func displayModeLeases() throws { try testDisplayModeLeases() }

    @Test func encoderInputAndCommandState() async throws {
        let damageBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(captureChangedFraction(rects: [], bounds: damageBounds) == 0)
        #expect(
            captureChangedFraction(rects: [CGRect(x: 200, y: 0, width: 50, height: 50)], bounds: damageBounds) == nil,
            "Out-of-space damage cannot suppress a frame")
        #expect(
            captureChangedFraction(rects: [CGRect(x: 0, y: 0, width: 50, height: 50)], bounds: damageBounds) == 0.25)
        #expect(
            captureChangedFraction(rects: [], bounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)) == nil)
        var recovery = CaptureRecoverySchedule()
        check(
            recovery.request(now: 1_000_000_000, windowMS: 50, referenceAvailable: true, pending: false) == true)
        check(recovery.request(now: 1_010_000_000, windowMS: 50, referenceAvailable: true, pending: true) == nil)
        check(
            recovery.request(now: 1_050_000_000, windowMS: 50, referenceAvailable: true, pending: true) == false)
        check(
            recovery.request(now: 1_100_000_000, windowMS: 50, referenceAvailable: false, pending: false) == nil,
            "Repeated loss must not produce an IDR storm")
        check(
            recovery.request(now: 1_250_000_000, windowMS: 50, referenceAvailable: false, pending: false) == false)
        check(
            recovery.request(now: 1_300_000_000, windowMS: 50, referenceAvailable: true, pending: false) == true)
        #expect(recovery.referenceDeadline == 1_450_000_000, "Fallback must preserve the IDR throttle")
        check(!recovery.expireReference(now: 1_449_999_999))
        check(recovery.expireReference(now: 1_450_000_000))
        check(!recovery.expireReference(now: 1_450_000_001), "Only one fallback per episode")
        check(
            recovery.request(now: 1_450_000_000, windowMS: 50, referenceAvailable: false, pending: true) == false)
        check(
            recovery.request(now: 1_700_000_000, windowMS: 250, referenceAvailable: true, pending: false) == true)
        check(recovery.producedReference(now: 1_800_000_000))
        #expect(recovery.referenceDeadline == 2_050_000_000)
        check(
            !recovery.producedReference(now: 1_900_000_000), "One output cannot repeatedly extend ACK admission")
        #expect(recovery.referenceDeadline == 2_050_000_000)
        check(!recovery.expireReference(now: 2_049_999_999))
        recovery.acknowledgeRecovery()
        check(!recovery.expireReference(now: 2_100_000_000), "Decoded ACK cancels escalation")
        #expect(EncoderBurstEnvelope(milliseconds: 250).byteLimit(kbps: 12000) == 562500)
        #expect(EncoderBurstEnvelope(milliseconds: -1).seconds == 1)
        var burstAttempts = 0
        let fallback = EncoderBurstEnvelope(milliseconds: 250).apply(kbps: 12000) { _ in
            burstAttempts += 1; return burstAttempts == 1 ? -1 : 0
        }
        #expect(burstAttempts == 2 && fallback.contains("burst=1.0s") && fallback.contains("burstFallback=-1"))
        burstAttempts = 0
        let rejected = EncoderBurstEnvelope(milliseconds: 250).apply(kbps: 12000) { _ in
            burstAttempts += 1; return -1
        }
        #expect(burstAttempts == 2 && rejected.contains("burst=unsupported"))
        burstAttempts = 0
        _ = EncoderBurstEnvelope(milliseconds: nil).apply(kbps: 12000) { _ in
            burstAttempts += 1; return -1
        }
        #expect(burstAttempts == 1, "Do not retry an already rejected ordinary envelope")
        var credits = CaptureFrameCredits()
        check(credits.produced(id: 1, generation: 1, bytes: 1000))
        check(!credits.canEncode(generation: 1, now: 1, frameAge: 0, encodeEstimate: 1))
        credits.sending(id: 1, generation: 1, now: 1, budgetMS: 30)
        check(credits.canEncode(generation: 1, now: 1, frameAge: 0, encodeEstimate: 1))
        check(credits.produced(id: 2, generation: 1, bytes: 1000))
        check(!credits.canEncode(generation: 1, now: 1, frameAge: 0, encodeEstimate: 1))
        check(!credits.produced(id: 3, generation: 1, bytes: 1000))
        check(!credits.consumed(id: 1, generation: 2))
        check(credits.consumed(id: 1, generation: 1))
        check(!credits.consumed(id: 1, generation: 1))
        check(
            !credits.canEncode(generation: 1, now: 1, frameAge: 0, encodeEstimate: 1),
            "Consumption cannot invent another send-start token")
        credits.sending(id: 2, generation: 1, now: 1, budgetMS: 30)
        credits.sending(id: 2, generation: 1, now: 40_000_000, budgetMS: 30)
        check(
            !credits.canEncode(generation: 1, now: 40_000_000, frameAge: 0, encodeEstimate: 1),
            "Duplicate send-start extended admission")
        check(!credits.canEncode(generation: 2, now: 2, frameAge: 0, encodeEstimate: 1))
        let liveness = NativeDaemonLiveness(now: 0)
        #expect(liveness.timeoutDiagnostic(now: 3_000_000_000) == nil)
        liveness.receive("frame_consumed", now: 2_900_000_000)
        #expect(
            liveness.timeoutDiagnostic(now: 5_000_000_000) == nil,
            "Live command traffic must prevent an idle-heartbeat timeout")
        #expect(
            liveness.timeoutDiagnostic(now: 6_000_000_000)?.contains("lastCommand=frame_consumed") == true,
            "A silent owner must still expire and retain the last command kind")
        liveness.receive("heartbeat", now: 6_000_000_000)
        #expect(liveness.timeoutDiagnostic(now: 6_100_000_000) == nil)
        let input = InputInjector(bounds: CGRect(x: -1280, y: 0, width: 1280, height: 720), dryRun: true)
        var value = NativeInput(); value.kind = "key"; value.physicalKey = 4; value.generation = 1
        value.down = true; try input.handle(value)
        #expect(input.heldKeys == [0])
        value.down = false; try input.handle(value)
        #expect(input.heldKeys.isEmpty)
        for usage: UInt32 in [225, 229] {
            value.physicalKey = usage; value.down = true; value.modifiers = 1; try input.handle(value)
        }
        value.physicalKey = 225; value.down = false; try input.handle(value)
        #expect(input.heldKeys == [60])
        value.kind = "pointer_button"; value.button = 1; value.x = 0; value.y = 0; value.down = true
        try input.handle(value)
        #expect(input.position == CGPoint(x: -1280, y: 0))
        value.kind = "pointer_move"; value.x = 1_000_000; value.y = 1_000_000; try input.handle(value)
        #expect(input.position.x < 0 && input.position.y < 720 && input.heldButtons == [1])
        input.releaseAll()
        #expect(input.heldKeys.isEmpty && input.heldButtons.isEmpty)
        input.update(bounds: CGRect(x: 0, y: 0, width: 1600, height: 900), generation: 2)
        do { try input.handle(value); Issue.record("stale display accepted") } catch {}
        let first = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), dryRun: true)
        let second = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), dryRun: true)
        var held = NativeInput(); held.kind = "key"; held.physicalKey = 4; held.down = true; held.generation = 1
        try SharedInputAuthority.shared.handle(held, injector: first)
        SharedInputAuthority.shared.remove(second)
        #expect(first.heldKeys == [0], "Spectator teardown released the controller")
        try SharedInputAuthority.shared.handle(held, injector: second)
        #expect(first.heldKeys.isEmpty && second.heldKeys == [0], "Encoder move left held keys behind")
        held.kind = "release_all"
        try SharedInputAuthority.shared.handle(held, injector: first)
        #expect(second.heldKeys.isEmpty, "Handoff must release the machine's active injector")
        let queue = NativeCommandQueue(capacity: 2)
        let gate = CommandTestGate()
        #expect(queue.submit { await gate.wait() })
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await gate.entered
        #expect(entered)
        #expect(queue.submit { await gate.finish() })
        #expect(!queue.submit { Issue.record("unbounded native command queue") })
        await gate.release()
        for _ in 0..<200 {
            if await gate.finished { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let finished = await gate.finished
        #expect(finished)
        queue.close()
        #expect(!queue.submit { Issue.record("stopped native command queue") })
        let configurationGate = ConfigurationGate()
        await configurationGate.shutdown()
        do {
            try await configurationGate.acquire()
            Issue.record("stopped capture accepted configuration")
        } catch {
            #expect(error.localizedDescription == "native capture rendition stopped")
        }
        let stoppedRunner = CaptureRunner(options: CaptureOptions())
        await stoppedRunner.stopAndWait()
        let finalCredit = NativeCommand(
            version: CaptureInputProtocol.version, id: 1, kind: "frame_consumed", input: nil,
            configuration: nil, frameId: 1, streamId: nil, profile: nil, codec: nil)
        stoppedRunner.enqueue(finalCredit) { error in
            #expect(error == "native capture rendition stopped", "Final frame credit lost shutdown cause")
        }
        print(
            "Native input state: physical key zero, independent Shift sides, drag bounds, release and display generation passed"
        )
    }
}

private func testPrivacyHIDMonitor() throws {
    var root = PrivacyHIDStatus(available: true, active: true, deviceCount: 3, generation: "first")
    var actions = [String](), locks = 0
    let monitor = PrivacyHIDMonitor(
        exchange: { action in
            actions.append(action)
            return root
        }, requestLock: { locks += 1 })
    try monitor.acquire(); try monitor.audit()
    #expect(monitor.deviceCount == 3 && locks == 0)
    root.active = false
    for _ in 0..<2 { do { try monitor.audit(); Issue.record("lost protection reported healthy") } catch {} }
    #expect(locks == 1 && !actions.dropFirst().contains("on"))
    root.active = true; root.generation = "replacement"
    do { try monitor.audit(); Issue.record("replacement service adopted silently") } catch {}
    #expect(locks == 1)
    try monitor.acquire(); try monitor.audit()
    root.available = false
    do { try monitor.release(); Issue.record("failed restoration reported unlocked") } catch {}
    root.available = true; root.active = false
    try monitor.release()
    #expect(monitor.deviceCount == 0)
    print(
        "Privacy monitor: lost protection requests lock once, rejects restarted helpers and permits explicit recovery")
}

private func testRemoteDisplayActivity() throws {
    var calls = 0
    let activity = RemoteDisplayActivity { name, userType, assertionID in
        calls += 1
        #expect(name as String == "Dieter remote desktop connection")
        #expect(userType == kIOPMUserActiveRemote)
        #expect(assertionID.pointee == IOPMAssertionID(calls - 1))
        assertionID.pointee = IOPMAssertionID(calls)
        return kIOReturnSuccess
    }
    try activity.wake()
    try activity.wake()
    #expect(calls == 2, "Remote activity must reuse its IOKit assertion")

    let failing = RemoteDisplayActivity { _, _, _ in kIOReturnError }
    do {
        try failing.wake()
        Issue.record("A failed display wake was accepted")
    } catch {
        #expect(error.localizedDescription.contains("Unable to wake the macOS display"))
    }
}

private func testDisplayModeLeases() throws {
    let driver = SyntheticDesktopModeDriver()
    let lease = DesktopModeLease(driver: driver)
    let changed = try lease.set("synthetic", mode: "720", expected: "1080")
    #expect(changed.temporary && changed.originalModeId == "1080")
    do {
        _ = try lease.set("synthetic", mode: "1080", expected: "1080")
        Issue.record("Stale modes accepted")
    } catch {}
    let restored = try lease.restore("synthetic")
    #expect(restored.currentModeId == "1080" && !restored.temporary)
    _ = try lease.set("synthetic", mode: "720", expected: "1080")
    try driver.apply("synthetic", mode: "local-change")
    let manual = try lease.restore("synthetic")
    #expect(manual.currentModeId == "local-change" && manual.superseded)
    try driver.apply("synthetic", mode: "1080")
    _ = try lease.set("synthetic", mode: "720", expected: "1080")
    let original = try lease.set("synthetic", mode: "1080", expected: "720")
    #expect(!original.temporary)
    _ = try lease.set("synthetic", mode: "720", expected: "1080")
    lease.restoreOnExit()
    let exited = try driver.snapshot("synthetic")
    #expect(exited.currentModeId == "1080")
}

private actor CommandTestGate {
    var entered = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
    func finish() { finished = true }
}

private final class FailingPrivacyDriver: PrivacyDesktopDriver {
    var failing = false
    var held = false
    func availability() -> PrivacySnapshot { .init(supported: true, displayCount: 2) }
    func acquire() throws { held = true }
    func maintain() throws { if failing { throw CaptureError.invalidArgument("lost protection") } }
    func release() throws { if failing { throw CaptureError.invalidArgument("restore failed") }; held = false }
}
private func testPrivacyLease() throws {
    let driver = FailingPrivacyDriver(), lease = PrivacyLease(driver: FailingPrivacyDriver())
    #expect(lease.snapshot().state == 0)
    let active = PrivacyLease(driver: driver)
    let enabled = try active.set(true)
    #expect(enabled.state == 1)
    #expect(driver.held)
    driver.failing = true
    active.audit()
    #expect(active.snapshot().state == 2 && active.snapshot().requested)
    do { _ = try active.set(false); Issue.record("failed restore reported unlocked") } catch {}
    #expect(active.snapshot().state == 2 && active.snapshot().requested && driver.held)
    driver.failing = false
    active.audit()
    #expect(active.snapshot().state == 1)
    let disabled = try active.set(false)
    #expect(disabled.state == 0)
    #expect(!driver.held)
    let physical = CGEvent(source: CGEventSource(stateID: .hidSystemState))!
    let remote = CGEvent(source: CGEventSource(stateID: .privateState))!
    #expect(SystemPrivacyDesktopDriver.isPhysical(physical))
    #expect(!SystemPrivacyDesktopDriver.isPhysical(remote))
    print("Privacy lease: degraded protection, retryable restoration and physical input classification passed")
}

private final class PrivacyInputObservation {
    var physical = 0
    var remote = 0
}

@MainActor private func testPrivacyDesktop() async throws {
    // Talk through the exact approved capture binary. The test executable has
    // no privileged authentication exemption and cannot control the root helper.
    let helper = ProcessInfo.processInfo.environment["DIETER_TEST_PRIVACY_HELPER"] ?? ""
    guard helper.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: helper) else {
        throw CaptureError.invalidArgument("DIETER_TEST_PRIVACY_HELPER must name the exact approved capture binary")
    }
    let directory = FileManager.default.currentDirectoryPath + "/tmp/privacy-physical-" + UUID().uuidString.prefix(8)
    try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let owner = Process(); owner.executableURL = URL(fileURLWithPath: helper)
    owner.arguments = ["--privacy-service", "--privacy-directory", directory]
    func exchange(_ action: String) throws -> PrivacySnapshot {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PrivacyHIDError("privacy test socket") }
        defer { close(fd) }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array((directory + "/control.sock").utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw PrivacyHIDError("privacy test socket path")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        guard
            withUnsafePointer(
                to: &address,
                {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }) == 0
        else { throw PrivacyHIDError("privacy test connection") }
        let request = Data(("{\"action\":\"" + action + "\"}\n").utf8)
        guard request.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == request.count else {
            throw PrivacyHIDError("privacy test request")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 8192 && !data.contains(10) {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { throw PrivacyHIDError("privacy test reply") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let end = data.firstIndex(of: 10) else { throw PrivacyHIDError("privacy test response limit") }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(PrivacySnapshot.self, from: data.prefix(upTo: end))
        if let error = value.error { throw PrivacyHIDError(error) }
        return value
    }
    func restore() async throws {
        let value = try exchange("off")
        guard !value.requested && value.state == 0 else {
            throw PrivacyHIDError("privacy restoration was not confirmed")
        }
        let deadline = Date().addingTimeInterval(5)
        while owner.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard !owner.isRunning else { throw PrivacyHIDError("privacy test owner did not exit after unlock") }
        guard owner.terminationStatus == 0 else { throw PrivacyHIDError("privacy test owner did not close cleanly") }
    }
    let original = try Dictionary(
        uniqueKeysWithValues: SystemPrivacyDesktopDriver.displays().map { ($0, try PrivacyGammaTable.read($0)) })
    let seen = PrivacyInputObservation()
    let reference = Unmanaged.passUnretained(seen).toOpaque()
    guard
        let observer = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.mouseMoved.rawValue,
            callback: { _, _, event, reference in
                let seen = Unmanaged<PrivacyInputObservation>.fromOpaque(reference!).takeUnretainedValue()
                if event.getIntegerValueField(.eventSourceUserData) == 901 { seen.physical += 1 }
                if event.getIntegerValueField(.eventSourceUserData) == 902 { seen.remote += 1 }
                return Unmanaged.passUnretained(event)
            }, userInfo: reference)
    else { throw CaptureError.invalidArgument("privacy test observer unavailable") }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observer, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    defer { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    try owner.run()
    do {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: directory + "/control.sock") && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let active = try exchange("on")
        guard active.supported && active.state == 1 && active.inputDeviceCount > 0 else {
            throw PrivacyHIDError("Privileged protection did not confirm any input devices")
        }
        for display in original.keys {
            guard try PrivacyGammaTable.read(display).black else {
                throw CaptureError.invalidArgument("display output is not black")
            }
        }
        let position = CGEvent(source: nil)!.location
        for (state, marker) in [(CGEventSourceStateID.hidSystemState, Int64(901)), (.privateState, Int64(902))] {
            let event = CGEvent(
                mouseEventSource: CGEventSource(stateID: state), mouseType: .mouseMoved, mouseCursorPosition: position,
                mouseButton: .left)!
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cgSessionEventTap)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard seen.physical == 0, seen.remote == 1 else {
            throw CaptureError.invalidArgument("privacy event filter: physical=\(seen.physical), remote=\(seen.remote)")
        }
        guard !IsSecureEventInputEnabled(), EnableSecureEventInput() == noErr else {
            throw PrivacyHIDError("Owned test could not enter Secure Event Input")
        }
        do {
            let secure = try exchange("status")
            guard secure.state == 1 && secure.inputDeviceCount == active.inputDeviceCount else {
                throw PrivacyHIDError("Device protection was lost during Secure Event Input")
            }
        } catch { _ = DisableSecureEventInput(); throw error }
        guard DisableSecureEventInput() == noErr else { throw PrivacyHIDError("Secure Event Input cleanup failed") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.invalidArgument("privacy capture needs a display")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration(); configuration.width = 640; configuration.height = 360;
        configuration.showsCursor = false
        let capture = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bytes = Array(capture.dataProvider!.data! as Data)
        let rgb = bytes.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
        guard rgb.filter({ $0 > 20 }).count > rgb.count / 10 else {
            throw CaptureError.invalidArgument("privacy obscured desktop captures")
        }
    } catch {
        try await restore()
        throw error
    }
    try await restore()
    for (display, previous) in original {
        let restored = try PrivacyGammaTable.read(display)
        guard restored.red == previous.red, restored.green == previous.green, restored.blue == previous.blue else {
            throw CaptureError.invalidArgument("privacy did not restore original display tables")
        }
    }
    print(
        "Privacy desktop: black output tables, unfiltered capture pixels, physical-source suppression, remote input and exact restoration passed"
    )
}
