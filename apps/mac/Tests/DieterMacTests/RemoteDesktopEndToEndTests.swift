import AppKit
import DieterAPI
import DieterClient
import DieterCore
import Foundation
import GRPCCore
import CryptoKit
import Testing
import SwiftUI
@preconcurrency import WebRTC
@testable import DieterMac

private struct ScreenFixtureConnection: Decodable {
    var url: String
    var certificate: Data
    var rtc: Data
    var clipboardName: String?
    var token: String
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["DIETER_TEST_SCREEN_FIXTURE"] != nil
            && ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_HELPER"] != nil,
        "Requires the disposable native screen fixture"))
@MainActor func remoteDesktopNativeEndToEnd() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let executable = environment["DIETER_TEST_SCREEN_FIXTURE"],
        let helper = environment["DIETER_TEST_CAPTURE_HELPER"]
    else { return }
    let real = environment["DIETER_TEST_SCREEN_CAPTURE_REAL"] == "1"
    let latencyOnly = environment["DIETER_TEST_SCREEN_LATENCY_ONLY"] == "1"
    let stabilitySeconds = max(32, min(600, Int(environment["DIETER_TEST_SCREEN_QUALITY_SOAK_SECONDS"] ?? "32") ?? 32))
    let output = FileManager.default.temporaryDirectory.appending(path: "dieter-screen-viewer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let ready = output.appending(path: "ready.json")
    let log = output.appending(path: "fixture.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let logHandle = try FileHandle(forWritingTo: log)
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [
        "--helper", helper, "--source", real ? "screen" : "native-synthetic", "--authenticate", "--ready", ready.path,
    ]
    process.standardOutput = logHandle; process.standardError = logHandle
    if !real {
        var fixtureEnvironment = environment
        fixtureEnvironment["DIETER_TEST_CAPTURE_IDLE_CYCLE"] = "1"
        fixtureEnvironment["DIETER_TEST_CAPTURE_INPUT_PATTERN"] = "1"
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
    let configuration = try Dieter_Gateway_V1_RTCConfiguration(serializedBytes: fixture.rtc)
    var routeOpenings = 0
    var unavailableRoutes = 0
    func openRoute() throws -> RemoteDesktopSignalingConnection {
        routeOpenings += 1
        if unavailableRoutes > 0 {
            unavailableRoutes -= 1; throw RPCError(code: .unavailable, message: "Injected sleeping laptop network")
        }
        let rpc = try DieterRPC(endpoint: endpoint, accessToken: fixture.token)
        let rpcTask = Task<Void, Never> { try? await rpc.run() }
        return RemoteDesktopSignalingConnection(
            rpc: rpc, connectionTask: rpcTask,
            rtcConfiguration: configuration, daemonCertificatePEM: fixture.certificate, routeLabel: "Fixture loopback")
    }
    @discardableResult func inject(_ path: String) async throws -> Int {
        var request = URLRequest(url: try #require(URL(string: fixture.url + path)))
        request.httpMethod = "POST"
        request.setValue("Bearer " + fixture.token, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 204)
        return Int(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Dieter-Test-Rejected-Signals")
                ?? (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Dieter-Test-Interrupted-Signals") ?? "0"
        )
            ?? 0
    }
    let controller = RemoteDesktopController()
    defer {
        if !controller.renderer.renderTrace.isEmpty {
            try? JSONEncoder().encode(controller.renderer.renderTrace).write(
                to: output.appending(path: "render-trace.json"))
        }
    }
    controller.codecPreference = environment["DIETER_TEST_SCREEN_CODEC"] == "hevc" ? .hevc : .h264
    let requestedFPS = Int32(environment["DIETER_TEST_SCREEN_FPS"] ?? "60") ?? 60
    controller.preferredMaxFPS = requestedFPS
    let clientClipboard = NSPasteboard(name: .init("com.dbpprt.dieter.fixture.viewer.\(UUID().uuidString)"))
    controller.clipboard.pasteboard = clientClipboard
    controller.clipboard.stagingDirectory = output.appending(path: "clipboard")
    // SwiftPM's test runner hosts an NSWindow without an NSApplication event
    // loop. Inject application activation; transport and native clipboard stay real.
    controller.clipboardApplicationActive = { true }
    defer { clientClipboard.releaseGlobally() }
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
    application.activate(ignoringOtherApps: true)
    try await verifyNativeScreenRenderer(controller.renderer)
    var presentationAges: [Double] = [], resumedAges: [Double] = []
    var previousPresentation: Double?
    var presentedSize = CGSize.zero
    controller.renderer.onPresentationTiming = { frame, presentedAt in
        presentedSize = CGSize(width: Int(frame.width), height: Int(frame.height))
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
    await controller.connect(machineName: "Isolated native fixture") { try openRoute() }.value
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
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(surface)
    controller.inputFocused = true

    var presentedFPS = 0.0
    if !real {
        // Measure initial motion before the synthetic source's deliberate
        // five-second idle cycle. Clipboard transfer duration depends on the
        // route, so sampling after those transfers can measure idle instead.
        let presentationStart = Date(), presentedBefore = controller.renderer.framesPresented
        try await Task.sleep(for: .seconds(2))
        presentedFPS =
            Double(controller.renderer.framesPresented - presentedBefore)
            / Date().timeIntervalSince(presentationStart)
        print("Actual Metal presentation rate: \(presentedFPS) fps")
        #expect(presentedFPS >= 45, "A 60 Hz stream must not be capped by a 30 Hz renderer")
        #expect(
            controller.renderer.lastPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || controller.renderer.lastPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }
    if environment["DIETER_TEST_FORCE_TURN"] == "1" {
        #expect(controller.mediaRouteLabel == "Relayed media")
    }

    let clipboardContext = try #require(controller.clipboard.makeRequest?())
    let hostClipboard = NSPasteboard(name: .init(try #require(fixture.clipboardName)))
    defer { hostClipboard.releaseGlobally() }
    try await Task.sleep(for: .milliseconds(600))
    if !real && !latencyOnly {
        for payload in ["Mac clipboard é漢字🙂\n  whitespace\n", String(repeating: "x", count: 1024 * 1024), ""] {
            clientClipboard.clearContents(); clientClipboard.setString(payload, forType: .string)
            let before = controller.clipboard.completedOperations
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v",
                    isARepeat: false, keyCode: 9))
            surface.keyDown(with: event)
            try await screenWait(
                "clipboard paste \(payload.utf8.count) bytes: \(controller.clipboardError)", timeout: 7
            ) {
                controller.clipboard.completedOperations > before || !controller.clipboardError.isEmpty
            }
            try #require(controller.clipboardError.isEmpty, "\(controller.clipboardError)")
            #expect(hostClipboard.string(forType: .string) == payload)
            let received = try await controller.clipboard.exchange(.read)
            #expect(received.text == payload || !received.changed)
        }
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCWQAAAAASUVORK5CYII="))
        let fileBytes = Data(repeating: 0xa7, count: 2 * 1024 * 1024)
        let copiedFile = output.appending(path: "copied.bin"), emptyFile = output.appending(path: "empty.txt")
        try fileBytes.write(to: copiedFile); try Data().write(to: emptyFile)
        for image in [true, false] {
            clientClipboard.clearContents()
            if image {
                clientClipboard.setData(png, forType: .png)
            } else {
                clientClipboard.writeObjects([copiedFile, emptyFile] as [NSURL])
            }
            let before = controller.clipboard.completedOperations
            controller.clipboard.paste()
            try await screenWait("native binary clipboard paste", timeout: 15) {
                controller.clipboard.completedOperations > before || !controller.clipboardError.isEmpty
            }
            try #require(controller.clipboardError.isEmpty, "\(controller.clipboardError)")
            if image {
                #expect(hostClipboard.data(forType: .png) == png)
            } else {
                let urls = try #require(
                    hostClipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                        as? [URL])
                #expect(urls.count == 2); #expect(try Data(contentsOf: urls[0]) == fileBytes);
                #expect(try Data(contentsOf: urls[1]).isEmpty)
                #expect(urls[0] != copiedFile, "Host must stage transferred bytes, not reuse the source path")
            }
            let copied = controller.clipboard.completedOperations
            // Clear only the viewer, then copy the native host selection back.
            controller.clipboard.enabled = false
            clientClipboard.clearContents()
            controller.clipboard.enabled = true
            controller.clipboard.copySelection()
            try await screenWait("native binary clipboard copy", timeout: 15) {
                controller.clipboard.completedOperations > copied || !controller.clipboardError.isEmpty
            }
            try #require(controller.clipboardError.isEmpty, "\(controller.clipboardError)")
            if image {
                #expect(clientClipboard.data(forType: .png) == png)
            } else {
                let urls = try #require(
                    clientClipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                        as? [URL])
                #expect(try Data(contentsOf: urls[0]) == fileBytes)
                #expect(try Data(contentsOf: urls[1]).isEmpty)
            }
        }
        let remoteText = "Remote → local 🦊\nCopy from app menu"
        hostClipboard.clearContents(); hostClipboard.setString(remoteText, forType: .string)
        try await screenWait("remote copy to local clipboard", timeout: 5) {
            clientClipboard.string(forType: .string) == remoteText
        }
        controller.clipboard.setEnabled(false)
        try await Task.sleep(for: .milliseconds(350))
        hostClipboard.clearContents(); hostClipboard.setString("disabled", forType: .string)
        try await Task.sleep(for: .milliseconds(400))
        #expect(clientClipboard.string(forType: .string) == remoteText)
        controller.clipboard.setEnabled(true)
        try await Task.sleep(for: .milliseconds(350))
        print("Clipboard: Unicode, empty text, 1 MiB paste, bidirectional transfer and disabled sharing passed")
    }
    let firstGeneration = controller.sessionState.displayGeneration
    if !real {
        let beforeSignalingRetry = controller.renderer.framesPresented
        #expect(try await inject("/test/interrupt-screen-signaling") == 1)
        // The HTTP signaling stream is canceled, while real WebRTC media
        // continues. Its retry must not put a spinner over a live desktop.
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(25))
            #expect(controller.phase == .streaming, "Signaling retry covered live native video")
        }
        #expect(controller.renderer.framesPresented > beforeSignalingRetry)
        #expect(routeOpenings == 1)
        // Continue real native media/feedback for longer than the 15-second
        // session lease while every unary renewal fails. No reconnect allowed.
        try await inject("/test/reject-screen-signals?enabled=true")
        let pointerBefore = controller.pointerSequence
        controller.sendPointerMove(x: 0.2, y: 0.2)
        #expect(controller.pointerSequence == pointerBefore + 1, "First pointer movement must dispatch synchronously")
        controller.sendPointerMove(x: 0.3, y: 0.3)
        controller.releaseAllInput()
        let releasedPointer = controller.pointerSequence
        try await Task.sleep(for: .milliseconds(15))
        #expect(controller.pointerSequence == releasedPointer, "Focus/release must cancel trailing motion")
        let start = Date()
        let inputBefore = controller.eventOrdinal
        controller.sendKey(code: 0, down: true, repeat: false, modifiers: [])
        controller.sendKey(code: 0, down: false, repeat: false, modifiers: [])
        controller.sendPointerButton(.left, down: true, clickCount: 1, x: 0, y: 0, modifiers: [])
        controller.sendPointerButton(.left, down: false, clickCount: 1, x: 0, y: 0, modifiers: [])
        // Real desktop interaction below is restricted to the owned probe window.
        // Synthetic mode verifies the same complete control protocol without posting.
        try await screenWait("native input acknowledgment", timeout: 4) {
            controller.sessionState.lastInputOrdinal >= inputBefore + 4 || controller.errorMessage != nil
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
        let responses = try await measureScreenInputResponse(controller, x: 0.02, y: 0.02) { white in
            controller.sendText("dieter-latency:\(white ? 235 : 16)")
        }
        let responseAges = responses.sorted()
        print(
            "Synthetic input → actual Metal presentation: median \(responseAges[responseAges.count / 2]) ms, p95 \(responseAges[responseAges.count * 95 / 100]) ms"
        )
        let report: [String: Any] = [
            "measurement": "same-host synthetic capture and input to actual Metal presentation",
            "requestedFps": requestedFPS, "achievedFps": presentedFPS, "captureSamples": sortedAges.count,
            "width": controller.sessionState.width, "height": controller.sessionState.height,
            "codec": controller.sessionState.codec, "presentationMode": controller.renderer.presentationMode.rawValue,
            "fastBitrate": environment["DIETER_SCREEN_FAST_BITRATE"] != "0",
            "latePresentations": controller.renderer.latePresentations,
            "captureMedianMs": median, "captureP95Ms": p95, "idleResumeMs": resumedAges,
            "inputSamples": responseAges.count, "inputMedianMs": responseAges[responseAges.count / 2],
            "inputP95Ms": responseAges[responseAges.count * 95 / 100],
            "encodeMs": controller.sessionState.encodeMs, "sendMs": controller.sessionState.sendMs,
            "jitterBufferMs": controller.sessionState.jitterBufferMs,
            "renderMs": controller.sessionState.renderMs,
            "schemaVersion": 1, "presentationEndpoint": "metal-presented-time",
            "maxUnpresented": controller.renderer.maxUnpresented,
            "presentationTimeouts": controller.renderer.presentationTimeouts,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appending(path: "latency.json"))
        if latencyOnly { return }
        controller.configure(maxFPS: 120)
        try await screenWait("120 fps live configuration", timeout: 8) {
            controller.sessionState.configuration.maxFps == 120
        }
        #expect(controller.sessionState.configuration.maxWidth <= 1920)
        controller.configure(maxFPS: 60)
        try await screenWait("60 fps live configuration", timeout: 8) {
            controller.sessionState.configuration.maxFps == 60
        }
        // Canceled resize tasks must not submit intermediate geometries. The
        // settled size is deliberately outside the old 160×90 size buckets.
        for width in [640, 1120, 1280, 832] {
            let scale = window.backingScaleFactor
            window.setContentSize(CGSize(width: CGFloat(width) / scale, height: CGFloat(width) * 9 / 16 / scale))
            surface.layoutSubtreeIfNeeded(); surface.layout()
            await Task.yield()
        }
        try await screenWait("coalesced viewport resize", timeout: 5) {
            controller.sessionState.configuration.maxWidth == 832
                && controller.sessionState.width == 832
                && presentedSize == CGSize(width: 832, height: 468)
        }
        #expect(controller.sessionState.displayGeneration == firstGeneration + 1)
    }
    if real {
        let targetExecutable = try #require(environment["DIETER_TEST_INPUT_TARGET"])
        let targetReport = output.appending(path: "input-target.json")
        let launch = NSWorkspace.OpenConfiguration()
        launch.arguments = [
            targetReport.path, String(ProcessInfo.processInfo.processIdentifier), try #require(fixture.clipboardName),
        ]
        // Same-host tests must activate the owned target rather than the viewer.
        controller.clipboard.makeRequest = { clipboardContext }
        controller.clipboard.enabled = false
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
        let responses = try await measureScreenInputResponse(controller, x: x, y: y) { white in
            controller.sendKey(code: white ? 18 : 19, down: true, repeat: false, modifiers: [])
            controller.sendKey(code: white ? 18 : 19, down: false, repeat: false, modifiers: [])
        }.sorted()
        let responseReport: [String: Any] = [
            "measurement": "owned app input to actual Metal presentation", "samples": responses.count,
            "inputSamples": responses.count, "inputMedianMs": responses[responses.count / 2],
            "inputP95Ms": responses[responses.count * 95 / 100], "requestedFps": requestedFPS,
            "width": controller.sessionState.width, "height": controller.sessionState.height,
            "codec": controller.sessionState.codec, "presentationMode": controller.renderer.presentationMode.rawValue,
            "fastBitrate": environment["DIETER_SCREEN_FAST_BITRATE"] != "0",
            "medianMs": responses[responses.count / 2], "p95Ms": responses[responses.count * 95 / 100],
            "schemaVersion": 1, "presentationEndpoint": "metal-presented-time",
            "maxUnpresented": controller.renderer.maxUnpresented,
            "presentationTimeouts": controller.renderer.presentationTimeouts,
        ]
        print("Owned app input → actual Metal presentation: \(responseReport)")
        try JSONSerialization.data(withJSONObject: responseReport, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appending(path: "input-latency.json"))
        if latencyOnly {
            target.terminate()
            try await screenWait("latency target teardown", timeout: 4) { target.isTerminated }
            return
        }
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
        let pasted = " Native clipboard paste é漢字🙂\n"
        controller.clipboard.enabled = true
        controller.inputFocused = true
        let beforePaste = controller.clipboard.completedOperations
        controller.clipboard.perform(.paste, text: pasted)
        controller.sendText("AFTER_PASTE")
        try await screenWait("ordered clipboard shortcut completes", timeout: 4) {
            controller.clipboard.completedOperations > beforePaste
        }
        controller.clipboard.enabled = false
        try await screenWait("typing stays after paste", timeout: 4) {
            (report()["text"] as? String ?? "").contains(pasted + "AFTER_PASTE")
        }
        try await screenWait("native app consumed clipboard paste", timeout: 4) {
            (report()["text"] as? String ?? "").contains(pasted)
        }
        _ = try await controller.clipboard.exchange(.copy)
        try await screenWait("native app copy updated pasteboard", timeout: 4) {
            hostClipboard.string(forType: .string) == (report()["text"] as? String)
        }
        let copied = try await controller.clipboard.exchange(.read)
        #expect(copied.text.contains(pasted))
        // Copy is an explicit operation: its result must still reach the local
        // clipboard if the viewer loses focus before the native app answers.
        controller.clipboard.enabled = true
        let beforeCopy = controller.clipboard.completedOperations
        controller.clipboard.copySelection()
        controller.clipboard.makeRequest = { nil }
        try await screenWait("copy completes after viewer focus loss", timeout: 4) {
            controller.clipboard.completedOperations > beforeCopy
        }
        #expect(clientClipboard.string(forType: .string) == (report()["text"] as? String))
        controller.clipboard.makeRequest = { clipboardContext }
        controller.clipboard.enabled = false
        let cut = try await controller.clipboard.exchange(.cut)
        try await screenWait("native app cut consumed selection", timeout: 4) { (report()["text"] as? String) == "" }
        #expect(cut.text.contains(pasted))
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCWQAAAAASUVORK5CYII="))
        for item in [
            ScreenClipboardItem(kind: 1, name: "pixel.png", mimeType: "image/png", data: png),
            ScreenClipboardItem(
                kind: 0, name: "copied.bin", mimeType: "application/octet-stream",
                data: Data(repeating: 0xa5, count: 2 * 1024 * 1024)),
        ] {
            _ = try await controller.clipboard.exchange(.paste, items: [item])
            let digest = SHA256.hash(data: item.data).map { String(format: "%02x", $0) }.joined()
            try await screenWait("owned native app consumed binary paste", timeout: 5) {
                (report()["pastedBinary"] as? [[String: Any]])?.first?["sha256"] as? String == digest
            }
            let returned = try await controller.clipboard.exchange(.copy)
            #expect(
                returned.items.first?.data == item.data, "Native application copy must return the same binary bytes")
        }
        print("Real native app clipboard copy, cut, paste and copy completion after focus loss passed")
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
    if environment["DIETER_TEST_FORCE_TURN"] == "1" {
        #expect(controller.mediaRouteLabel == "Relayed media")
    }
    if !real {
        #expect(routeOpenings == 1, "A healthy peer must survive missing unary lease renewals")
        let rejected = try await inject("/test/reject-screen-signals?enabled=false")
        #expect(rejected >= 3, "Fault injection must actually reject multiple renewal calls")
        unavailableRoutes = 5
        try await inject("/test/expire-screen")
        try await screenWait("expired session survives five unavailable routes and reauthenticates", timeout: 25) {
            routeOpenings == 7 && controller.controlActive && controller.sessionState.receiverFps > 0
        }
        #expect(controller.errorMessage == nil)
        #expect(controller.sessionState.configuration.quality == .detail)
        // Stop the real disposable helper, so recovery must replace capture as
        // well as the authenticated route and native WebRTC peer.
        try await inject("/test/stop-capture")
        try await screenWait("native helper shutdown automatically restarts capture", timeout: 15) {
            routeOpenings == 8 && controller.controlActive && controller.sessionState.receiverFps > 0
        }
        #expect(controller.errorMessage == nil)
        #expect(controller.sessionState.configuration.quality == .detail)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(controller.systemSleeping)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await screenWait("wake immediately rebuilds the peer and authenticated route", timeout: 12) {
            routeOpenings == 9 && controller.controlActive && controller.sessionState.receiverFps > 0
        }
        // Disconnect during a further interruption must cancel delayed recovery.
        try await inject("/test/expire-screen")
        try await screenWait("second interruption enters recovery", timeout: 4) { controller.phase == .reconnecting }
        controller.disconnect()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(routeOpenings == 9)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(routeOpenings == 9, "Explicit disconnect must not reconnect on wake")
        #expect(controller.phase == .idle)
        await controller.connect(machineName: "Interrupted clipboard fixture") { try openRoute() }.value
        try await screenWait("reconnect for interrupted binary transfer", timeout: 12) { controller.controlActive }
        controller.inputFocused = true
        controller.clipboard.enabled = false
        try await Task.sleep(for: .milliseconds(300))
        hostClipboard.clearContents(); hostClipboard.setString("Preserve clipboard on interruption", forType: .string)
        let partial = Task {
            try await controller.clipboard.exchange(
                .paste,
                items: [
                    .init(
                        kind: 0, name: "partial.bin", mimeType: "application/octet-stream",
                        data: Data(repeating: 0x5a, count: 8 * 1024 * 1024))
                ])
        }
        try await Task.sleep(for: .milliseconds(20))
        controller.disconnect()
        do { _ = try await partial.value; Issue.record("Interrupted clipboard operation unexpectedly completed") } catch
        {}
        try await Task.sleep(for: .milliseconds(300))
        #expect(hostClipboard.string(forType: .string) == "Preserve clipboard on interruption")
        print(
            "Lease/capture regression: \(rejected) rejected RPC renewals preserved native video; expiry and actual helper shutdown recovered; explicit disconnect canceled recovery"
        )
    }
    controller.disconnect()
    try await screenWait("session teardown", timeout: 4) { !controller.controlActive }
    process.terminate()
    try await screenWait("fixture process teardown", timeout: 5) { !process.isRunning }
}

private final class NativeScreenPixelBufferProbe: RTCCVPixelBuffer, @unchecked Sendable {
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
    // A burst replaces pending frames while rendering proceeds independently.
    // It must not convert the native surfaces on the CPU.
    for timestamp in 1...1000 {
        renderer.renderFrame(RTCVideoFrame(buffer: probe, rotation: ._0, timeStampNs: Int64(timestamp)))
    }
    try await screenWait("direct NV12 Metal presentation", timeout: 5) { renderer.framesPresented == 1 }
    #expect(probe.conversionCount == 0)
    #expect(renderer.drawSubmissions < 1000, "Decoder bursts must coalesce")
    // Let the initial visibility commit/redraw and GPU completion drain before
    // measuring idle behavior. A presented callback can precede that UI commit.
    try await Task.sleep(for: .milliseconds(250))
    let submissions = renderer.drawSubmissions
    try await Task.sleep(for: .milliseconds(250))
    #expect(renderer.drawSubmissions == submissions, "An idle screen must not run a redraw timer")
    let oldDecoder = renderer.decodeHandler()
    renderer.reset()
    #expect(renderer.framesPresented == 0)
    renderer.renderFrame(RTCVideoFrame(buffer: probe, rotation: ._0, timeStampNs: 2000))
    renderer.reset()
    try await Task.sleep(for: .milliseconds(100))
    #expect(renderer.drawSubmissions == 0, "Disconnect must invalidate queued draws")
    #expect(renderer.framesPresented == 0)
    oldDecoder(RTCVideoFrame(buffer: probe, rotation: ._0, timeStampNs: 3000))
    try await Task.sleep(for: .milliseconds(50))
    #expect(renderer.drawSubmissions == 0, "A released decoder must not draw into a new session")
    // Immediate playout can give every decoded frame the same render time.
    // Only the RTP timestamp identifies a new video presentation.
    for timestamp: Int32 in [1, 2] {
        let frame = RTCVideoFrame(buffer: probe, rotation: ._0, timeStampNs: 0)
        frame.timeStamp = timestamp
        renderer.renderFrame(frame)
        try await screenWait("distinct RTP presentation", timeout: 2) { renderer.framesPresented == UInt64(timestamp) }
    }
    // Keep the window unchanged and block only UI processing. Actual hardware
    // presentation counters must keep advancing on the render thread.
    let decode = renderer.decodeHandler()
    let producer = Task.detached {
        for timestamp: Int32 in 10...40 {
            if Task.isCancelled { return }
            let frame = RTCVideoFrame(buffer: probe, rotation: ._0, timeStampNs: 0)
            frame.timeStamp = timestamp
            decode(frame)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
    let beforeStall = renderer.framesPresented
    blockScreenUIForSchedulingTest()
    #expect(renderer.framesPresented > beforeStall + 2, "UI work stalled actual Metal presentation")
    producer.cancel()
    await producer.value
    #expect(probe.conversionCount == 0)
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
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["DIETER_TEST_SCREEN_COMPANION"] != nil,
        "Requires the concurrent Android fixture"))
@MainActor func remoteDesktopAndroidCompanion() async throws {
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

// The timestamp is taken before input dispatch, on the same clock as Metal's
// actual presentation callback. Pixel verification observes the response, not an
// input ACK or a frame captured before the application changed its content.
@MainActor private func measureScreenInputResponse(
    _ controller: RemoteDesktopController, x: Double, y: Double,
    send: (Bool) -> Void
) async throws -> [Double] {
    let previous = controller.renderer.onPresentationTiming
    var waiting: (white: Bool, started: Double)?
    var samples: [Double] = []
    controller.renderer.onPresentationTiming = { frame, presentedAt in
        previous?(frame, presentedAt)
        guard let pending = waiting, presentedAt >= pending.started,
            let buffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer,
            CVPixelBufferIsPlanar(buffer)
        else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let px = max(0, min(CVPixelBufferGetWidth(buffer) - 1, Int(x * Double(CVPixelBufferGetWidth(buffer)))))
        let py = max(0, min(CVPixelBufferGetHeight(buffer) - 1, Int(y * Double(CVPixelBufferGetHeight(buffer)))))
        let luma = base.load(fromByteOffset: py * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + px, as: UInt8.self)
        guard pending.white ? luma > 215 : luma < 35 else { return }
        samples.append((presentedAt - pending.started) * 1000)
        waiting = nil
    }
    defer { controller.renderer.onPresentationTiming = previous }
    let count = max(
        24, min(1000, Int(ProcessInfo.processInfo.environment["DIETER_TEST_SCREEN_INPUT_SAMPLES"] ?? "24") ?? 24))
    for index in 0..<count {
        waiting = (index % 2 != 0, CACurrentMediaTime())
        send(index % 2 != 0)
        try await screenWait("input changed presented pixels", timeout: 3) { waiting == nil }
    }
    #expect(samples.count == count)
    #expect(samples.allSatisfy { $0 >= 0 && $0 < 500 }, "Input response must not build a stale queue")
    return samples
}

// Intentional synchronous UI work models AppKit/layout contention.
@MainActor private func blockScreenUIForSchedulingTest() {
    Thread.sleep(forTimeInterval: 0.25)
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["DIETER_TEST_SCREEN_FIXTURE"] != nil
            && ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_HELPER"] != nil,
        "Requires the disposable native screen fixture"))
@MainActor func remoteDesktopUndockedEndToEnd() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let executable = env["DIETER_TEST_SCREEN_FIXTURE"], let helper = env["DIETER_TEST_CAPTURE_HELPER"] else {
        return
    }
    let output = FileManager.default.temporaryDirectory.appending(path: "dieter-undocked-\(UUID())")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let ready = output.appending(path: "ready.json"), log = output.appending(path: "fixture.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["--helper", helper, "--source", "native-synthetic", "--authenticate", "--ready", ready.path]
    var environment = env; environment["DIETER_TEST_CAPTURE_INPUT_PATTERN"] = "1"
    process.environment = environment; process.standardOutput = handle; process.standardError = handle
    try process.run()
    defer {
        if process.isRunning { process.terminate(); process.waitUntilExit() }; try? handle.close();
        print("Undocked screen evidence: \(output.path)")
    }
    try await screenWait("undocked fixture readiness", timeout: 10) {
        FileManager.default.fileExists(atPath: ready.path)
    }
    let fixture = try JSONDecoder().decode(ScreenFixtureConnection.self, from: Data(contentsOf: ready))
    let rpc = try DieterRPC(endpoint: #require(DieterEndpoint.parse(fixture.url)), accessToken: fixture.token)
    let rpcTask = Task { try? await rpc.run() }; defer { rpcTask.cancel() }
    let suite = "dieter-undocked-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite));
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = ScreensModel(defaults: defaults)
    let session = ScreenShareSession(machineID: "fixture", machineName: "Studio Mac", monitorsInactivity: false)
    model.sessions = [session]; model.selectedSessionID = session.id
    let controller = session.controller
    let surface = session.videoSurface
    let application = NSApplication.shared; application.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 1100, height: 800), styleMask: [.titled, .closable, .resizable],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "Dieter — Undock Integration"
    let root = NSHostingView(
        rootView: ScreensView(
            model: model, machines: [], initialMachineID: "fixture", makeConnection: { _ in throw CancellationError() })
    )
    root.sizingOptions = []; window.contentView = root
    window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
    defer { model.closeSession(session.id); window.contentView = nil; window.close() }
    session.connect {
        let connection = try DieterRPC(
            endpoint: #require(DieterEndpoint.parse(fixture.url)), accessToken: fixture.token)
        return RemoteDesktopSignalingConnection(
            rpc: connection, connectionTask: Task { try? await connection.run() },
            rtcConfiguration: try Dieter_Gateway_V1_RTCConfiguration(serializedBytes: fixture.rtc),
            daemonCertificatePEM: fixture.certificate, routeLabel: "Isolated fixture")
    }
    try await screenWait("docked hardware video", timeout: 20) {
        controller.controlActive && controller.renderer.framesPresented > 5
    }
    let original = try await rpc.remoteDesktopSessions()
    let sessionID = try #require(original.sessions.first?.sessionID)
    func capture(_ window: NSWindow, _ name: String) {
        let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appending(path: name + ".png").path]
        try? shot.run(); shot.waitUntilExit()
    }
    capture(window, "01-docked")
    let docked = try await measureScreenInputResponse(controller, x: 0.01, y: 0.01) {
        controller.sendText("dieter-latency:\($0 ? 235 : 16)")
    }.sorted()
    let framesBefore = controller.renderer.framesPresented
    model.undock(session.id)
    let viewer = try #require(model.detachedWindows[session.id])
    let detached = try #require(viewer.window)
    try await screenWait("native macOS fullscreen entered", timeout: 12) {
        detached.styleMask.contains(.fullScreen) && !viewer.transitioning
    }
    try await screenWait("fullscreen hardware presentation", timeout: 15) {
        surface.window === detached && controller.controlActive
            && controller.renderer.framesPresented > framesBefore + 5
    }
    #expect(session.videoSurface === surface)
    #expect(controller.clipboardWindow === detached)
    #expect(controller.renderer.superview === surface)
    capture(detached, "02-fullscreen")

    // Hover before acquiring keyboard focus: a single local cursor changes
    // immediately, before any network acknowledgement could arrive.
    // SwiftPM does not run NSApplication's event loop. Supply the focused
    // window here; ScreenShareUISmoke validates real application/key activation.
    surface.windowIsActive = { [weak detached] in $0 != nil && $0 === detached }
    detached.makeFirstResponder(nil)
    controller.remoteCursorState.visible = true
    controller.remoteCursorState.normalizedX = 100_000
    controller.remoteCursorState.normalizedY = 100_000
    controller.remoteCursor = .crosshair
    let center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
    let move = try #require(
        NSEvent.mouseEvent(
            with: .mouseMoved, location: surface.convert(center, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: detached.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    let beforeAck = controller.sessionState.lastInputOrdinal
    let beforeMove = controller.eventOrdinal
    let began = CACurrentMediaTime()
    surface.mouseMoved(with: move)
    let cursorMS = (CACurrentMediaTime() - began) * 1000
    #expect(!controller.inputFocused)
    #expect(surface.cursorPresentation == .local)
    #expect(!surface.hostCursorVisible)
    #expect(NSCursor.current === controller.remoteCursor)
    #expect(controller.sessionState.lastInputOrdinal == beforeAck)
    try await screenWait("fullscreen pointer reaches host", timeout: 3) {
        controller.eventOrdinal > beforeMove && controller.sessionState.lastInputOrdinal >= controller.eventOrdinal
    }

    // A remote pointer or an old host's baked cursor gets one cursor too.
    controller.transferControl(take: false)
    try await screenWait("view-only cursor", timeout: 4) {
        !controller.controlActive && !controller.controlTransferPending
    }
    surface.refreshCursor(at: center)
    #expect(surface.cursorPresentation == .remote && surface.hostCursorVisible)
    controller.sessionState.embeddedCursor = true
    surface.refreshCursor(at: center)
    #expect(surface.cursorPresentation == .embedded && !surface.hostCursorVisible)
    controller.sessionState.embeddedCursor = false
    controller.transferControl(take: true)
    try await screenWait("control restored", timeout: 4) { controller.controlActive }
    detached.makeFirstResponder(surface)
    let release = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: detached.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 53))
    surface.keyDown(with: release)
    #expect(!controller.inputFocused)
    let releasedOrdinal = controller.eventOrdinal
    surface.mouseMoved(with: move)
    let scroll = try #require(
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0))
    surface.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
    #expect(controller.eventOrdinal == releasedOrdinal, "Release shortcut must pause pointer input until clicked")
    detached.makeFirstResponder(surface)
    let fullscreen = try await measureScreenInputResponse(controller, x: 0.01, y: 0.01) {
        controller.sendText("dieter-latency:\($0 ? 235 : 16)")
    }.sorted()
    capture(detached, "03-fullscreen-active")
    // Exercise the experimental setting and real RPC/helper/capture generation
    // path against the disposable display driver, never the operator's monitor.
    let beforeMode = controller.sessionState.displayGeneration
    viewer.displayTarget = { _ in .init(width: 1280, height: 720, scale: 1, refresh: 60) }
    model.matchClientResolution = true
    var matchingDiagnostic = ""
    try await screenWait("experimental mode applied and fresh geometry presented", timeout: 15) {
        let diagnostic =
            "status=\(controller.displayMatching.status) busy=\(controller.displayMatching.busy) generation=\(controller.sessionState.displayGeneration)/\(beforeMode) control=\(controller.controlActive) supported=\(controller.capabilities.displayModeSwitchingSupported)"
        if diagnostic != matchingDiagnostic { print("Resolution test: \(diagnostic)"); matchingDiagnostic = diagnostic }
        return controller.displayMatching.status.hasPrefix("Matched:") && !controller.displayMatching.busy
            && controller.sessionState.displayGeneration > beforeMode && controller.controlActive
    }
    let matchedMode = try await rpc.remoteDesktopDisplayModes(sessionID: sessionID)
    #expect(matchedMode.temporary && matchedMode.currentModeID == "720")
    model.matchClientResolution = false
    try await screenWait("experimental resolution restored", timeout: 15) {
        controller.displayMatching.status == "Remote resolution restored" && !controller.displayMatching.busy
            && controller.controlActive
    }
    let restoredMode = try await rpc.remoteDesktopDisplayModes(sessionID: sessionID)
    #expect(!restoredMode.temporary && restoredMode.currentModeID == "1080")
    if let hold = Double(env["DIETER_TEST_SCREEN_UNDOCK_HOLD"] ?? ""), hold > 0 {
        try await Task.sleep(for: .seconds(min(hold, 30)))
    }
    model.dock(session.id)
    try await screenWait("redocked live viewer", timeout: 12) { !session.isDetached && surface.window === window }
    try await screenWait("redocked input readiness", timeout: 10) { controller.controlActive }
    let final = try await rpc.remoteDesktopSessions()
    #expect(final.sessions.count == 1 && final.sessions.first?.sessionID == sessionID)
    #expect(controller.clipboardWindow === window)
    #expect(controller.phase == .streaming)
    capture(window, "04-redocked")
    // Closing an ordinary undocked window docks it; closing a tab ends it.
    model.undock(session.id, fullScreen: false)
    let floating = try #require(model.detachedWindows[session.id]?.window)
    try await screenWait("floating viewer", timeout: 3) { surface.window === floating }
    capture(floating, "05-floating")
    floating.performClose(nil)
    try await screenWait("close returns viewer", timeout: 3) { !session.isDetached && surface.window === window }
    model.undock(session.id, fullScreen: false)
    let closing = model.detachedWindows[session.id]?.window
    model.closeSession(session.id)
    #expect(closing?.isVisible == false && model.detachedWindows.isEmpty)
    #expect(controller.phase == .idle)
    let report: [String: Any] = [
        "sameSession": sessionID, "cursorEventMs": cursorMS,
        "dockedInputMedianMs": docked[docked.count / 2], "dockedInputP95Ms": docked[docked.count * 95 / 100],
        "fullscreenInputMedianMs": fullscreen[fullscreen.count / 2],
        "fullscreenInputP95Ms": fullscreen[fullscreen.count * 95 / 100],
        "inputSamplesPerMode": docked.count, "measurement": "same-host synthetic input to actual Metal presentation",
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
        to: output.appending(path: "results.json"))
    print("Undocked screen result: \(report)")
}
