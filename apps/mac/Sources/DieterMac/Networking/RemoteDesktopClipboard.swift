import AppKit
import DieterAPI
import Foundation
@preconcurrency import WebRTC

@MainActor
final class RemoteDesktopClipboard: NSObject, RTCDataChannelDelegate {
    static let limit = 1 << 20
    var makeRequest: (() -> Dieter_V1_RemoteDesktopClipboardRequest?)?
    var onOperationFinished: ((Bool) -> Void)?
    var onBusy: ((Bool) -> Void)?
    var isCurrentGrant: ((UInt64) -> Bool)?
    var onError: ((String) -> Void)?
    var pasteboard = NSPasteboard.general
    private var channel: RTCDataChannel?
    private var polling: Task<Void, Never>?
    private var continuation: CheckedContinuation<Dieter_V1_RemoteDesktopClipboardResponse, Error>?
    private var requestID = ""
    private var buffer = Data()
    private var revision = ""
    private var localCount = 0
    private var grant: UInt64 = 0
    private var serial: UInt64 = 0
    private var busy = false
    private(set) var operationPending = false
    private(set) var completedOperations = 0
    var enabled = true {
        didSet { if enabled != oldValue { revision = ""; localCount = pasteboard.changeCount } }
    }

    func attach(_ channel: RTCDataChannel) {
        close(); self.channel = channel; channel.delegate = self
        localCount = pasteboard.changeCount
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.enabled, let context = self.makeRequest?(), self.channel?.readyState == .open else { continue }
                if self.grant != context.controlGeneration {
                    self.grant = context.controlGeneration; self.revision = ""; self.localCount = self.pasteboard.changeCount
                }
                guard !self.busy, !self.operationPending else { continue }
                do {
                    if self.pasteboard.changeCount != self.localCount {
                        self.localCount = self.pasteboard.changeCount
                        if let text = self.pasteboard.string(forType: .string) {
                            let response = try await self.exchange(.write, text: text)
                            self.revision = response.revision
                        }
                    } else {
                        let count = self.pasteboard.changeCount
                        let previous = self.revision
                        let response = try await self.exchange(.read)
                        guard self.makeRequest?()?.controlGeneration == context.controlGeneration else { continue }
                        self.revision = response.revision
                        if !previous.isEmpty, response.changed, response.hasText_p, self.pasteboard.changeCount == count,
                            self.pasteboard.string(forType: .string) != response.text {
                            self.pasteboard.clearContents(); self.pasteboard.setString(response.text, forType: .string)
                            self.localCount = self.pasteboard.changeCount
                        }
                    }
                } catch { if !Task.isCancelled { self.onError?(error.localizedDescription) } }
            }
        }
    }
    func close() {
        serial &+= 1; polling?.cancel(); polling = nil
        channel?.delegate = nil; channel?.close(); channel = nil
        continuation?.resume(throwing: CancellationError()); continuation = nil
        requestID = ""; buffer.removeAll(); revision = ""; grant = 0; busy = false; operationPending = false
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        let token = serial
        let context = makeRequest?()
        Task { [weak self] in
            guard let self, token == self.serial else { return }
            do { _ = try await self.exchange(.configure, enabled: value, initial: context); self.revision = ""; self.localCount = self.pasteboard.changeCount }
            catch { if token == self.serial { self.onError?(error.localizedDescription) } }
        }
    }
    func paste() {
        guard enabled, let text = pasteboard.string(forType: .string) else { onError?("Clipboard has no text"); return }
        perform(.paste, text: text)
    }
    func copySelection() { perform(.copy) }
    func cut() { perform(.cut) }
    func perform(_ action: Dieter_V1_RemoteDesktopClipboardRequest.Action, text: String = "") {
        guard enabled, let context = makeRequest?() else { return }
        guard !operationPending else { onError?("A clipboard operation is still in progress"); return }
        operationPending = true; onBusy?(true)
        let token = serial
        let count = pasteboard.changeCount
        Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            defer { if token == self.serial { self.operationPending = false; self.onBusy?(false); self.onOperationFinished?(succeeded) } }
            do {
                let response = try await self.exchange(action, text: text, initial: context)
                guard token == self.serial else { return }
                self.revision = response.revision
                if (action == .copy || action == .cut), response.hasText_p, self.enabled, self.pasteboard.changeCount == count {
                    self.pasteboard.clearContents(); self.pasteboard.setString(response.text, forType: .string)
                    self.localCount = self.pasteboard.changeCount
                } else { self.localCount = count }
                self.completedOperations += 1; succeeded = true; self.onError?("")
            } catch { if token == self.serial { self.onError?(error.localizedDescription) } }
        }
    }
    func exchange(_ action: Dieter_V1_RemoteDesktopClipboardRequest.Action, text: String = "", enabled: Bool = true, initial: Dieter_V1_RemoteDesktopClipboardRequest? = nil) async throws -> Dieter_V1_RemoteDesktopClipboardResponse {
        guard text.utf8.count <= Self.limit else { throw failure("Clipboard text exceeds 1 MiB") }
        let token = serial
        for _ in 0..<500 {
            if !busy { break }; try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !busy, token == serial, var request = initial ?? makeRequest?(), let channel, channel.readyState == .open else { throw failure("Clipboard unavailable for this viewer") }
        guard isCurrentGrant?(request.controlGeneration) ?? true else { throw CancellationError() }
        busy = true
        defer { if token == serial { busy = false; requestID = ""; buffer.removeAll() } }
        request.operationID = UUID().uuidString; request.action = action; request.text = text
        request.knownRevision = revision; request.enabled = enabled
        requestID = request.operationID
        let raw = try request.serializedData()
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Dieter_V1_RemoteDesktopClipboardResponse, Error>) in
            self.continuation = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    for offset in stride(from: 0, to: raw.count, by: 16 * 1024) {
                        while channel.bufferedAmount > 32 * 1024 {
                            guard token == self.serial, self.continuation != nil else { throw CancellationError() }
                            try await Task.sleep(nanoseconds: 5_000_000)
                        }
                        guard token == self.serial, self.continuation != nil else { throw CancellationError() }
                        let end = min(raw.count, offset + 16 * 1024)
                        var frame = Dieter_V1_RemoteDesktopClipboardFrame()
                        frame.operationID = request.operationID; frame.data = raw.subdata(in: offset..<end); frame.end = end == raw.count
                        guard channel.sendData(RTCDataBuffer(data: try frame.serializedData(), isBinary: true)) else { throw self.failure("Clipboard transfer failed") }
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                } catch { if token == self.serial, self.requestID == request.operationID { self.finish(.failure(error)) } }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, token == self.serial, self.requestID == request.operationID, self.continuation != nil else { return }
                self.finish(.failure(self.failure("Clipboard timed out; paste was not retried")))
                channel.close()
            }
        }
        guard token == serial, (isCurrentGrant?(request.controlGeneration) ?? (makeRequest?()?.controlGeneration == request.controlGeneration)) else { throw CancellationError() }
        if !response.error.isEmpty { throw failure(response.error) }
        return response
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "DieterClipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func finish(_ result: Result<Dieter_V1_RemoteDesktopClipboardResponse, Error>) {
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith data: RTCDataBuffer) {
        guard data.isBinary, data.data.count <= 16 * 1024 + 128 else { return }
        let raw = data.data
        Task { @MainActor [weak self] in
            guard let self, self.channel === dataChannel, self.continuation != nil else { return }
            do {
                let frame = try Dieter_V1_RemoteDesktopClipboardFrame(serializedBytes: raw)
                guard frame.operationID == self.requestID, frame.data.count <= 16 * 1024,
                    self.buffer.count + frame.data.count <= Self.limit + 4096 else { throw self.failure("Invalid clipboard response") }
                self.buffer.append(frame.data)
                if frame.end { self.finish(.success(try Dieter_V1_RemoteDesktopClipboardResponse(serializedBytes: self.buffer))) }
            } catch { self.finish(.failure(error)); dataChannel.close() }
        }
    }
}
