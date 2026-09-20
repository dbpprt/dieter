import Foundation

final class MediaWriter: @unchecked Sendable {
    static let shared = MediaWriter()
    private let lock = NSLock()
    func write(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return data.withUnsafeBytes { bytes in
            var offset = 0
            let deadline = DispatchTime.now().uptimeNanoseconds + 750_000_000
            while offset < bytes.count {
                let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
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

private final class PendingCapture {
    var cancelled = false  // NativeCaptureService.lock
    let completion = DispatchGroup()
    init() { completion.enter() }
    func wait() async {
        await withCheckedContinuation { continuation in
            completion.notify(queue: .global()) { continuation.resume() }
        }
    }
}

final class NativeCaptureService: @unchecked Sendable {
    private let options: CaptureOptions
    private let events: EventWriter
    private let lock = NSLock()
    private var runners: [UInt64: CaptureRunner] = [:]
    private var pending: [UInt64: PendingCapture] = [:]
    private var retiring = Set<UInt64>()
    private var stopped = false
    private let liveness = NativeDaemonLiveness()
    private var delayedTestHeartbeat = false
    private let done = DispatchSemaphore(value: 0)
    private var signals: [DispatchSourceSignal] = []
    private var testStopFile: String? {
        options.synthetic ? ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_STOP_FILE"] : nil
    }
    init(options: CaptureOptions) { self.options = options; events = EventWriter(fd: options.eventFD) }

    func run() async throws {
        signal(SIGPIPE, SIG_IGN)
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        guard MediaWriter.shared.write(Data("DTH3".utf8)) else { throw CaptureError.invalidFrame }
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            // The disposable authenticated fixture can stop its own synthetic
            // helper once. Removing the marker lets a new helper recover.
            if let path = self.testStopFile, (try? FileManager.default.removeItem(atPath: path)) != nil {
                self.stop(reason: "native capture rendition stopped")
                return
            }
            if let diagnostic = self.liveness.timeoutDiagnostic() {
                writeDiagnostic(diagnostic)
                self.stop(reason: "native daemon heartbeat expired")
            }
        }
        watchdog.resume()
        for value in [SIGTERM, SIGINT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume(); signals.append(source)
        }
        DispatchQueue.global(qos: .userInteractive).async { self.read() }
        await Task.detached { self.wait() }.value
        watchdog.cancel(); signals.forEach { $0.cancel() }
    }
    private func wait() { done.wait() }
    private func stop(reason: String? = nil) {
        let active: [CaptureRunner]? = lock.withLock {
            if stopped { return nil }
            stopped = true
            let active = Array(runners.values); runners.removeAll()
            return active
        }
        guard let active else { return }
        if let reason { writeDiagnostic(reason) }
        SharedInputAuthority.shared.releaseAll()
        active.forEach { $0.stop(reason: reason ?? "native capture rendition stopped") }
        done.signal()
    }
    private func read() {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ stopped }) {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            while let end = data.firstIndex(of: 10) {
                let line = data.prefix(upTo: end)
                guard line.count <= 16384, let command = try? decoder.decode(NativeCommand.self, from: line),
                    command.version == CaptureContract.version
                else { stop(reason: "native command decoding failed"); return }
                data.removeSubrange(...end)
                liveness.receive(command.kind)
                if command.kind == "create" {
                    let accepted = lock.withLock { () -> Bool in
                        guard !stopped, runners.count + pending.count + retiring.count < 4, let id = command.streamId,
                            id != 0,
                            runners[id] == nil, pending[id] == nil
                        else { return false }
                        pending[id] = PendingCapture(); return true
                    }
                    guard accepted else {
                        reply(
                            command,
                            lock.withLock { stopped }
                                ? "native capture helper stopped" : "Native encoder capacity reached")
                        continue
                    }
                    // Starting a display/encoder must not stall existing input or frame credits.
                    Task { await self.create(command) }
                } else if command.kind == "remove" {
                    Task { await self.remove(command) }
                } else if command.kind == "heartbeat" {
                    // Fault injection is restricted to synthetic capture and a
                    // single reply, so tests cannot accumulate delayed tasks.
                    if options.synthetic, !delayedTestHeartbeat,
                        let raw = ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_HEARTBEAT_ACK_DELAY_MS"],
                        let delay = UInt64(raw), delay <= 5000
                    {
                        delayedTestHeartbeat = true
                        Task {
                            try? await Task.sleep(nanoseconds: delay * 1_000_000)
                            self.reply(command, nil)
                        }
                    } else {
                        reply(command, nil)
                    }
                } else if command.kind == "stop" {
                    reply(command, nil); stop()
                } else if let id = command.streamId, let runner = lock.withLock({ runners[id] }) {
                    runner.enqueue(command) { self.reply(command, $0) }
                } else {
                    // Shutdown removes runners before publishing their terminal
                    // events. A final frame credit must retain a recoverable
                    // shutdown cause whichever response reaches the daemon first.
                    reply(
                        command, lock.withLock { stopped } ? "native capture helper stopped" : "Unknown native stream")
                }
            }
            if data.count > 16384 { break }
        }
        stop()
    }
    private func create(_ command: NativeCommand) async {
        let id = command.streamId!
        guard let admission = lock.withLock({ pending[id] }) else { return }
        defer {
            _ = lock.withLock { pending.removeValue(forKey: id) }
            admission.completion.leave()
        }
        var runner: CaptureRunner?
        do {
            guard let config = command.configuration else { throw CaptureError.invalidArgument("configuration") }
            try config.validate()
            var value = options
            value.codec = command.codec ?? "H264"
            value.referenceRecovery = command.referenceRecovery ?? false
            guard ["H264", "H265"].contains(value.codec) else { throw CaptureError.invalidArgument("codec") }
            value.streamID = id; value.profile = command.profile == "baseline" ? "baseline" : "high"
            value.displayID = config.displayId; value.maxWidth = config.maxWidth; value.maxHeight = config.maxHeight
            value.fps = config.fps; value.bitrateKbps = config.bitrateKbps; value.embeddedCursor = config.embeddedCursor
            let created = CaptureRunner(options: value); runner = created
            try await created.start()
            let accepted = lock.withLock { () -> Bool in
                if stopped || admission.cancelled { return false }
                pending.removeValue(forKey: id)
                runners[id] = created; return true
            }
            if !accepted { throw CaptureError.stopped }
            reply(command, nil)
        } catch {
            await runner?.stopAndWait()
            reply(command, error.localizedDescription)
        }
    }
    private func remove(_ command: NativeCommand) async {
        guard let id = command.streamId else { reply(command, "Missing stream ID"); return }
        let values = lock.withLock { () -> (CaptureRunner?, PendingCapture?) in
            let admission = pending[id]
            admission?.cancelled = true
            let runner = runners.removeValue(forKey: id)
            if runner != nil { retiring.insert(id) }
            return (runner, admission)
        }
        await values.1?.wait()
        await values.0?.stopAndWait()
        _ = lock.withLock { retiring.remove(id) }
        reply(command, nil)
    }

    private func reply(_ command: NativeCommand, _ error: String?) {
        if options.synthetic, ProcessInfo.processInfo.environment["DIETER_TEST_CAPTURE_DROP_ACKS"] == "1" { return }
        if !events.send(NativeEvent(streamId: command.streamId ?? 0, ack: command.id, error: error)) {
            stop(reason: "native event pipe unavailable")
        }
    }
}
