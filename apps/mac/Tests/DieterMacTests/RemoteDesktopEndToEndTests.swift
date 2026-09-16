import AppKit
import DieterAPI
import DieterClient
import DieterCore
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import DieterMac

private struct ScreenFixtureConnection: Decodable {
    var url: String
    var certificate: Data
    var rtc: Data
}

@Test @MainActor func remoteDesktopNativeEndToEnd() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let executable = environment["DIETER_TEST_SCREEN_FIXTURE"],
        let helper = environment["DIETER_TEST_CAPTURE_HELPER"]
    else { return }
    let real = environment["DIETER_TEST_SCREEN_CAPTURE_REAL"] == "1"
    let stabilitySeconds = max(32, min(600, Int(environment["DIETER_TEST_SCREEN_QUALITY_SOAK_SECONDS"] ?? "32") ?? 32))
    let output = FileManager.default.temporaryDirectory.appending(path: "dieter-screen-viewer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let ready = output.appending(path: "ready.json")
    let log = output.appending(path: "fixture.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let logHandle = try FileHandle(forWritingTo: log)
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["--helper", helper, "--source", real ? "screen" : "native-synthetic", "--ready", ready.path]
    process.standardOutput = logHandle; process.standardError = logHandle
    if !real {
        var fixtureEnvironment = environment
        fixtureEnvironment["DIETER_TEST_CAPTURE_IDLE_CYCLE"] = "1"
        if stabilitySeconds >= 180 { fixtureEnvironment["DIETER_TEST_CAPTURE_QUALITY_CYCLE"] = "1" }
        process.environment = fixtureEnvironment
    }
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        try? logHandle.close()
        print("Native screen evidence: \(output.path)")
    }
    try await screenWait("fixture readiness", timeout: 10) {
        FileManager.default.fileExists(atPath: ready.path) || !process.isRunning
    }
    let fixture = try JSONDecoder().decode(ScreenFixtureConnection.self, from: Data(contentsOf: ready))
    let endpoint = try #require(DieterEndpoint.parse(fixture.url))
    let rpc = try DieterRPC(endpoint: endpoint)
    let rpcTask = Task<Void, Never> { try? await rpc.run() }
    let configuration = try Dieter_Gateway_V1_RTCConfiguration(serializedBytes: fixture.rtc)
    let connection = RemoteDesktopSignalingConnection(
        rpc: rpc, connectionTask: rpcTask,
        rtcConfiguration: configuration, daemonCertificatePEM: fixture.certificate, routeLabel: "Fixture loopback")
    let controller = RemoteDesktopController()
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: NSRect(x: 40, y: 30, width: 1440, height: 810), styleMask: [.titled, .closable, .resizable],
        backing: .buffered, defer: false)
    window.title = "Dieter screen end-to-end fixture"
    window.isReleasedWhenClosed = false
    let surface = RemoteDesktopInputView(renderer: controller.renderer, controller: controller)
    window.contentView = surface; window.makeKeyAndOrderFront(nil)
    surface.layoutSubtreeIfNeeded(); surface.layout()
    defer { controller.disconnect(); window.close() }
    try await verifyNativeScreenRenderer(controller.renderer)
    var presentationAges: [Double] = [], resumedAges: [Double] = []
    var previousPresentation: Double?
    controller.renderer.onPresentationTiming = { frame, presentedAt in
        // This fixture captures and presents on the SAME Mac. Its RTP timeline
        // is the host clock at 90 kHz; modular subtraction also tests RTP wrap.
        // Never apply this subtraction to unrelated clocks on remote machines.
        let presentationTicks = UInt32(truncatingIfNeeded: UInt64(presentedAt * 90000))
        let captureTicks = UInt32(bitPattern: frame.timeStamp)
        let age = Double(Int32(bitPattern: presentationTicks &- captureTicks)) / 90
        if presentationAges.count < 4096 { presentationAges.append(age) }
        if let previousPresentation, presentedAt - previousPresentation > 2 { resumedAges.append(age) }
        previousPresentation = presentedAt
    }
    await controller.connect(machineName: "Isolated native fixture") { connection }.value
    try await screenWait("hardware video decode: \(controller.phase)", timeout: 20) {
        (controller.sessionState.receiverFps > 0 && controller.controlActive) || controller.errorMessage != nil
    }
    try #require(controller.errorMessage == nil, "\(controller.errorMessage ?? "")")
    #expect(controller.sessionState.receiverFps > 0)
    #expect(controller.sessionState.width > 0)
    #expect(controller.sessionState.encoder.contains("VideoToolbox"))
    #expect(controller.immediatePlayoutNegotiated, "Bundled WebRTC must negotiate interactive playout")
    #expect(controller.controlActive)
    if real {
        try await screenWait("separate native cursor", timeout: 4) { !controller.remoteCursorState.shapeID.isEmpty }
        #expect(!controller.sessionState.embeddedCursor)
    }
    let firstGeneration = controller.sessionState.displayGeneration
    if !real {
        let presentationStart = Date(), presentedBefore = controller.renderer.framesPresented
        try await Task.sleep(for: .seconds(2))
        let presentedFPS =
            Double(controller.renderer.framesPresented - presentedBefore)
            / Date().timeIntervalSince(presentationStart)
        print("Actual Metal presentation rate: \(presentedFPS) fps")
        #expect(presentedFPS >= 45, "A 60 Hz stream must not be capped by a 30 Hz renderer")
        #expect(
            controller.renderer.lastPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || controller.renderer.lastPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let start = Date()
        controller.sendKey(code: 0, down: true, repeat: false, modifiers: [])
        controller.sendKey(code: 0, down: false, repeat: false, modifiers: [])
        controller.sendPointerButton(.left, down: true, clickCount: 1, x: 0, y: 0, modifiers: [])
        controller.sendPointerButton(.left, down: false, clickCount: 1, x: 0, y: 0, modifiers: [])
        // Real desktop interaction below is restricted to the owned probe window.
        // Synthetic mode verifies the same complete control protocol without posting.
        try await screenWait("native input acknowledgment", timeout: 4) {
            controller.sessionState.lastInputOrdinal >= 4 || controller.errorMessage != nil
        }
        #expect(controller.errorMessage == nil)
        print("Input acknowledgment observed within \(Date().timeIntervalSince(start) * 1000) ms")
        // Keep moving native pixels flowing through real WebRTC feedback long
        // enough to exercise both the reduction and recovery cooldowns.
        let initialWidth = controller.sessionState.width
        var previousFPS = controller.sessionState.fps
        var cadenceChanges = 0
        for second in 0..<stabilitySeconds {
            try await Task.sleep(for: .seconds(1))
            let state = controller.sessionState
            #expect(state.width >= initialWidth, "An uncongested local stream must preserve pixels")
            #expect(state.displayGeneration == firstGeneration, "LAN adaptation must not restart capture")
            #expect(controller.controlActive)
            if state.fps != previousFPS { cadenceChanges += 1; previousFPS = state.fps }
            if second % 15 == 0 {
                print(
                    "Native quality second \(second): \(state.width)x\(state.height)@\(state.fps), \(state.bitrateKbps) kbps, received \(state.receiverFps) fps, send \(state.sendMs) ms"
                )
            }
        }
        #expect(cadenceChanges <= 2, "Steady local conditions must not oscillate cadence")
        print("\(stabilitySeconds)-second LAN stability: \(initialWidth) pixels, \(cadenceChanges) cadence changes")
        let sortedAges = presentationAges.sorted()
        try #require(sortedAges.count > 120)
        let median = sortedAges[sortedAges.count / 2], p95 = sortedAges[sortedAges.count * 95 / 100]
        print(
            "Same-host capture → actual Metal presentation: median \(median) ms, p95 \(p95) ms; idle resumes \(resumedAges) ms"
        )
        #expect(sortedAges.first! >= 0, "Fixture clocks must match")
        #expect(p95 < 150, "Local motion must not accumulate stale frames")
        #expect(!resumedAges.isEmpty, "Exercise a real capture-idle gap")
        #expect(resumedAges.allSatisfy { $0 < 200 }, "Motion must resume without a slow keyframe drain")
        #expect(controller.sessionState.captureToSendMs > 0)
        #expect(controller.sessionState.renderMs >= 0)
        // Canceled resize tasks must not submit intermediate geometries.
        for width in [640, 1120, 1280, 800] {
            let scale = window.backingScaleFactor
            window.setContentSize(CGSize(width: CGFloat(width) / scale, height: CGFloat(width) * 9 / 16 / scale))
            surface.layoutSubtreeIfNeeded(); surface.layout()
            await Task.yield()
        }
        try await screenWait("coalesced viewport resize", timeout: 5) {
            controller.sessionState.configuration.maxWidth == 800
                && controller.sessionState.width == 800
        }
        #expect(controller.sessionState.displayGeneration == firstGeneration + 1)
    }
    if real {
        let targetExecutable = try #require(environment["DIETER_TEST_INPUT_TARGET"])
        let targetReport = output.appending(path: "input-target.json")
        let launch = NSWorkspace.OpenConfiguration()
        launch.arguments = [targetReport.path, String(ProcessInfo.processInfo.processIdentifier)]
        launch.activates = true
        let target = try await NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: targetExecutable), configuration: launch)
        defer { if !target.isTerminated { target.terminate() } }
        func report() -> [String: Any] {
            guard let data = try? Data(contentsOf: targetReport) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        try await screenWait("owned input target activation", timeout: 4) { report()["active"] as? Bool == true }
        let x = try #require(report()["x"] as? Double), y = try #require(report()["y"] as? Double)
        controller.sendPointerButton(.left, down: true, clickCount: 1, x: x, y: y, modifiers: [])
        controller.sendPointerButton(.left, down: false, clickCount: 1, x: x, y: y, modifiers: [])
        controller.sendKey(code: 0, down: true, repeat: false, modifiers: [])
        controller.sendKey(code: 0, down: false, repeat: false, modifiers: [])
        try await screenWait("posted keyboard and mouse events", timeout: 4) {
            (report()["ups"] as? Int ?? 0) > 0 && (report()["keys"] as? [String] ?? []).contains("0:up")
        }
        #expect((report()["keys"] as? [String] ?? []).contains("0:down"))
        try #require(report()["active"] as? Bool == true)
        controller.sendText("é漢字🙂")
        controller.sendScroll(
            deltaX: 0.25, deltaY: 2.5, precise: true, modifiers: [],
            phase: .changed, momentumPhase: [])
        controller.sendKey(code: 1, down: true, repeat: false, modifiers: [])
        controller.releaseAllInput()
        try await screenWait("Unicode, precise scroll, and held-key release", timeout: 4) {
            (report()["text"] as? String ?? "").contains("é漢字🙂")
                && (report()["scrolls"] as? Int ?? 0) > 0
                && (report()["keys"] as? [String] ?? []).contains("1:up")
        }
        target.terminate()
        try await screenWait("input target teardown", timeout: 4) { target.isTerminated }
    }
    controller.releaseAllInput()
    controller.configure(quality: .detail, refresh: true)
    try await screenWait("live quality change", timeout: 5) { controller.sessionState.configuration.quality == .detail }
    if real, let second = controller.capabilities.displays.first(where: { !$0.primary }) {
        controller.configure(displayID: second.id)
        try await screenWait("display switch", timeout: 8) {
            controller.sessionState.displayID == second.id
                && controller.sessionState.displayGeneration > firstGeneration && controller.controlActive
        }
        #expect(controller.sessionState.width <= second.physicalWidth)
    }
    if real {
        window.makeKeyAndOrderFront(nil)
        surface.layoutSubtreeIfNeeded(); surface.layout()
        try await Task.sleep(for: .milliseconds(250))
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), output.appending(path: "viewer.png").path]
        capture.standardError = logHandle
        try capture.run()
        try await screenWait("Metal viewer screenshot", timeout: 4) { !capture.isRunning }
        #expect(capture.terminationStatus == 0)
    }
    print(
        "Latency stages: capture→send \(controller.sessionState.captureToSendMs) ms, paced send \(controller.sessionState.sendMs) ms, jitter buffer \(controller.sessionState.jitterBufferMs) ms, render \(controller.sessionState.renderMs) ms. Cursor embedded=\(controller.sessionState.embeddedCursor) shape=\(controller.remoteCursorState.shapeID); displayed \(controller.sessionState.width)x\(controller.sessionState.height), \(controller.sessionState.receiverFps) fps, encode \(controller.sessionState.encodeMs) ms, RTT \(controller.sessionState.rttMs) ms, \(controller.mediaRouteLabel)"
    )
    controller.disconnect()
    try await screenWait("session teardown", timeout: 4) { !controller.controlActive }
    process.terminate()
    try await screenWait("fixture process teardown", timeout: 5) { !process.isRunning }
}

private final class NativeScreenPixelBufferProbe: RTCCVPixelBuffer {
    private let lock = NSLock()
    private var conversions = 0
    var conversionCount: Int { lock.lock(); defer { lock.unlock() }; return conversions }
    override func toI420() -> any RTCI420BufferProtocol {
        lock.lock(); conversions += 1; lock.unlock()
        return super.toI420()
    }
}

@MainActor private func verifyNativeScreenRenderer(_ renderer: RemoteDesktopMetalView) async throws {
    #expect(renderer.initializationFailure == nil)
    var pixel: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    #expect(
        CVPixelBufferCreate(
            nil, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
        memset(
            CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 128,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let probe = NativeScreenPixelBufferProbe(pixelBuffer: buffer)
    // A burst received while the UI is busy must replace pending frames, not
    // schedule hundreds of draws or convert their native surfaces on the CPU.
    for timestamp in 1...1000 {
        renderer.renderFrame(RTCVideoFrame(buffer: probe, rotation: ._0, timeStampNs: Int64(timestamp)))
    }
    try await screenWait("direct NV12 Metal presentation", timeout: 5) { renderer.framesPresented == 1 }
    #expect(probe.conversionCount == 0)
    #expect(renderer.drawSubmissions <= 2)
    let submissions = renderer.drawSubmissions
    try await Task.sleep(for: .milliseconds(250))
    #expect(renderer.drawSubmissions == submissions, "An idle screen must not run a redraw timer")
    renderer.reset()
    #expect(renderer.framesPresented == 0)
    renderer.renderFrame(RTCVideoFrame(buffer: probe, rotation: ._0, timeStampNs: 2000))
    renderer.reset()
    try await Task.sleep(for: .milliseconds(100))
    #expect(renderer.drawSubmissions == 0, "Disconnect must invalidate queued draws")
    #expect(renderer.framesPresented == 0)
    // Immediate playout can give every decoded frame the same render time.
    // Only the RTP timestamp identifies a new video presentation.
    for timestamp: Int32 in [1, 2] {
        let frame = RTCVideoFrame(buffer: probe, rotation: ._0, timeStampNs: 0)
        frame.timeStamp = timestamp
        renderer.renderFrame(frame)
        try await screenWait("distinct RTP presentation", timeout: 2) { renderer.framesPresented == UInt64(timestamp) }
    }
    renderer.reset()
}

@MainActor private func screenWait(_ label: String, timeout: Double, condition: () -> Bool) async throws {
    FileHandle.standardError.write(Data("Screen test waiting: \(label)\n".utf8))
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    FileHandle.standardError.write(Data("Screen test completed: \(label) = \(condition())\n".utf8))
    #expect(condition(), "Timed out: \(label)")
    if !condition() { throw NSError(domain: "ScreenE2E", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
}

@Test func remoteDesktopScrollPhasesMatchQuartz() {
    #expect(RemoteDesktopScrollPhases.scroll(.changed) == 2)
    #expect(RemoteDesktopScrollPhases.scroll(.ended) == 4)
    #expect(RemoteDesktopScrollPhases.scroll(.mayBegin) == 128)
    #expect(RemoteDesktopScrollPhases.momentum(.ended) == 3)
    #expect(RemoteDesktopScrollPhases.momentum(.changed) == 2)
}

@Test func remoteDesktopDragsClampAtLetterboxingAndOutsideWindow() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 1920, height: 1080)
    #expect(
        RemoteDesktopInputGeometry.normalized(point: CGPoint(x: -20, y: 900), bounds: bounds, videoSize: size) == nil)
    #expect(
        RemoteDesktopInputGeometry.normalized(
            point: CGPoint(x: -20, y: 900), bounds: bounds, videoSize: size, clamp: true) == .zero)
    #expect(
        RemoteDesktopInputGeometry.normalized(
            point: CGPoint(x: 1100, y: -20), bounds: bounds, videoSize: size, clamp: true) == CGPoint(x: 1, y: 1))
}

private final class ScreenFrameReadiness: @unchecked Sendable {
    let lock = NSLock()
    private var values: [String] = []
    func record(_ token: UInt64, _ generation: UInt64) {
        lock.lock(); defer { lock.unlock() }; values.append("\(token):\(generation)")
    }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@Test func remoteDesktopControlWaitsForDisplayFrameAndHandlesTimestampWrap() throws {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let buffer = RTCCVPixelBuffer(pixelBuffer: try #require(pixel))
    let observer = RemoteDesktopFrameObserver()
    let readiness = ScreenFrameReadiness()
    observer.onReady = { readiness.record($0, $1) }
    func frame(_ timestamp: UInt32) {
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 0)
        frame.timeStamp = Int32(bitPattern: timestamp)
        observer.renderFrame(frame)
    }
    observer.expect(token: 1, generation: 1, timestamp: 100)
    frame(99)
    #expect(readiness.recorded.isEmpty)
    frame(100); frame(101)
    #expect(readiness.recorded == ["1:1"])
    observer.expect(token: 1, generation: 2, timestamp: 200)
    frame(150)
    #expect(readiness.recorded == ["1:1"])
    frame(201)
    #expect(readiness.recorded == ["1:1", "1:2"])
    observer.reset()
    observer.expect(token: 2, generation: 1, timestamp: UInt32.max - 10)
    #expect(readiness.recorded.count == 2)
    frame(UInt32.max - 11)
    #expect(readiness.recorded.count == 2)
    frame(5)
    #expect(readiness.recorded == ["1:1", "1:2", "2:1"])
    // A frame can beat its reliable metadata onto the viewer.
    observer.reset(); frame(400)
    observer.expect(token: 3, generation: 1, timestamp: 390)
    #expect(readiness.recorded.last == "3:1")
}

// Companion for the emulator fixture: it stays connected while Android changes
// quality, transfers control, expires its own session, and reconnects repeatedly.
@Test @MainActor func remoteDesktopAndroidCompanion() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["DIETER_TEST_SCREEN_COMPANION"] else { return }
    let root = URL(fileURLWithPath: path).deletingLastPathComponent()
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    let fixture = try JSONDecoder().decode(ScreenFixtureConnection.self, from: raw)
    let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    let endpoint = try #require(DieterEndpoint.parse(fixture.url))
    let rpc = try DieterRPC(endpoint: endpoint, accessToken: json["token"] as? String)
    let task = Task<Void, Never> { try? await rpc.run() }
    let connection = RemoteDesktopSignalingConnection(
        rpc: rpc, connectionTask: task,
        rtcConfiguration: try .init(serializedBytes: fixture.rtc), daemonCertificatePEM: fixture.certificate,
        routeLabel: "Isolated concurrent fixture")
    let controller = RemoteDesktopController()
    NSApplication.shared.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: NSRect(x: 20, y: 40, width: 960, height: 540),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Dieter concurrent Mac viewer"
    window.isReleasedWhenClosed = false
    let surface = RemoteDesktopInputView(renderer: controller.renderer, controller: controller)
    window.contentView = surface; window.makeKeyAndOrderFront(nil)
    surface.layoutSubtreeIfNeeded(); surface.layout()
    defer { controller.disconnect(); window.close() }
    await controller.connect(machineName: "Concurrent fixture") { connection }.value
    try await screenWait("companion video/control", timeout: 25) {
        controller.controlActive || controller.errorMessage != nil
    }
    try #require(controller.errorMessage == nil, "\(controller.errorMessage ?? "")")
    controller.transferControl(take: false)
    try await screenWait("companion releases initial control", timeout: 5) {
        !controller.sessionState.controlActive && !controller.controlTransferPending
    }
    let initial = try await rpc.remoteDesktopSessions()
    let ownID = try #require(initial.sessions.first?.sessionID)
    try Data(ownID.utf8).write(to: root.appending(path: "mac-ready"))
    var handoffs = 0, observedPeers = false
    let start = Date(), originalFrames = controller.renderer.framesPresented
    while !FileManager.default.fileExists(atPath: root.appending(path: "mac-stop").path) {
        try #require(Date().timeIntervalSince(start) < 360, "Android companion test timed out")
        try #require(
            controller.errorMessage == nil,
            "Mac viewer failed during Android activity: \(controller.errorMessage ?? "")")
        if controller.sessionState.connectedClients >= 2 { observedPeers = true }
        if controller.sessionState.controlActive && !controller.controlTransferPending {
            handoffs += 1
            // Leave enough time for Android to observe revocation, then explicitly
            // release from the Mac client. Never inject into an unowned desktop.
            try await Task.sleep(for: .milliseconds(500))
            controller.transferControl(take: false)
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    let sessions = try await rpc.remoteDesktopSessions()
    #expect(sessions.sessions.contains { $0.sessionID == ownID })
    #expect(observedPeers)
    #expect(handoffs >= 1)
    #expect(controller.renderer.framesPresented > originalFrames + 60)
    let evidence: [String: Any] = [
        "session": ownID, "handoffs": handoffs, "observedPeers": observedPeers,
        "presentedFrames": controller.renderer.framesPresented, "captureStreams": sessions.captureStreams,
        "encoders": sessions.encoders, "width": controller.sessionState.width, "height": controller.sessionState.height,
    ]
    try JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted).write(
        to: root.appending(path: "mac-stats.json"))
    print("Concurrent Mac viewer evidence: \(root.path)")
}
