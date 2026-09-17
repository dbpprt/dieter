import AppKit
import DieterAPI
import DieterCore
import Foundation
@preconcurrency import WebRTC

@MainActor
final class RemoteDesktopClipboard: NSObject, RTCDataChannelDelegate {
    static let limit = 1 << 20
    var binarySupported = false
    var stagingDirectory = ScreenClipboardContent.defaultDirectory
    var makeRequest: (() -> Dieter_V1_RemoteDesktopClipboardRequest?)?
    var onOperationFinished: ((Bool) -> Void)?
    var onBusy: ((Bool) -> Void)?
    var isCurrentGrant: ((UInt64) -> Bool)?
    var onUnavailable: (() -> Void)?
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
                        let content = try ScreenClipboardContent.read(self.pasteboard, binary: self.binarySupported)
                        if content.text != nil || !content.items.isEmpty {
                            let response = try await self.exchange(.write, text: content.text ?? "", items: content.items)
                            self.revision = response.revision
                        }
                    } else {
                        let count = self.pasteboard.changeCount
                        let previous = self.revision
                        let response = try await self.exchange(.read)
                        guard self.makeRequest?()?.controlGeneration == context.controlGeneration else { continue }
                        self.revision = response.revision
                        if !previous.isEmpty, response.changed, response.hasText_p || !response.items.isEmpty, self.pasteboard.changeCount == count {
                            try self.apply(response)
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
        guard enabled else { return }
        do {
            let content = try ScreenClipboardContent.read(pasteboard, binary: true)
            guard content.text != nil || !content.items.isEmpty else { onError?("Clipboard has no supported content"); return }
            guard content.items.isEmpty || binarySupported else { onError?("Update the daemon to paste images and files"); return }
            perform(.paste, text: content.text ?? "", items: content.items)
        } catch { onError?(error.localizedDescription) }
    }
    func copySelection() { perform(.copy) }
    func cut() { perform(.cut) }
    func perform(_ action: Dieter_V1_RemoteDesktopClipboardRequest.Action, text: String = "", items: [ScreenClipboardItem] = []) {
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
                let response = try await self.exchange(action, text: text, items: items, initial: context)
                guard token == self.serial else { return }
                self.revision = response.revision
                if (action == .copy || action == .cut), response.hasText_p || !response.items.isEmpty, self.enabled, self.pasteboard.changeCount == count {
                    try self.apply(response)
                    self.localCount = self.pasteboard.changeCount
                } else { self.localCount = count }
                self.completedOperations += 1; succeeded = true; self.onError?("")
            } catch { if token == self.serial { self.onError?(error.localizedDescription) } }
        }
    }
    func exchange(_ action: Dieter_V1_RemoteDesktopClipboardRequest.Action, text: String = "", items: [ScreenClipboardItem] = [], enabled: Bool = true, initial: Dieter_V1_RemoteDesktopClipboardRequest? = nil) async throws -> Dieter_V1_RemoteDesktopClipboardResponse {
        try ScreenClipboardContent(text: items.isEmpty ? text : nil, items: items).validate()
        guard items.isEmpty || binarySupported else { throw failure("Update the daemon to share images and files") }
        let token = serial
        for _ in 0..<3000 {
            if !busy { break }; try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !busy, token == serial, var request = initial ?? makeRequest?(), let channel, channel.readyState == .open else { throw failure("Clipboard unavailable for this viewer") }
        guard isCurrentGrant?(request.controlGeneration) ?? true else { throw CancellationError() }
        busy = true
        defer { if token == serial { busy = false; requestID = ""; buffer.removeAll() } }
        request.operationID = UUID().uuidString; request.action = action; request.text = text
        request.knownRevision = revision; request.enabled = enabled
        request.acceptBinary = binarySupported
        request.items = items.map { item in
            var value = Dieter_V1_RemoteDesktopClipboardItem()
            value.kind = .init(rawValue: Int(item.kind)) ?? .file; value.name = item.name
            value.mimeType = item.mimeType; value.data = item.data
            return value
        }
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
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, token == self.serial, self.requestID == request.operationID, self.continuation != nil else { return }
                self.finish(.failure(self.failure("Clipboard timed out; paste was not retried")))
                channel.close()
            }
        }
        guard token == serial, (isCurrentGrant?(request.controlGeneration) ?? (makeRequest?()?.controlGeneration == request.controlGeneration)) else { throw CancellationError() }
        if !response.error.isEmpty { throw failure(response.error) }
        return response
    }
    private func apply(_ response: Dieter_V1_RemoteDesktopClipboardResponse) throws {
        let content = ScreenClipboardContent(text: response.hasText_p ? response.text : nil, items: response.items.map {
            ScreenClipboardItem(kind: Int32($0.kind.rawValue), name: $0.name, mimeType: $0.mimeType, data: $0.data)
        })
        try content.write(pasteboard, directory: stagingDirectory)
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "DieterClipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func finish(_ result: Result<Dieter_V1_RemoteDesktopClipboardResponse, Error>) {
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.channel === dataChannel, dataChannel.readyState == .closed else { return }
            self.finish(.failure(self.failure("Clipboard transfer interrupted; shortcut was not retried")))
            self.onUnavailable?()
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith data: RTCDataBuffer) {
        guard data.isBinary, data.data.count <= 16 * 1024 + 128 else { return }
        let raw = data.data
        Task { @MainActor [weak self] in
            guard let self, self.channel === dataChannel, self.continuation != nil else { return }
            do {
                let frame = try Dieter_V1_RemoteDesktopClipboardFrame(serializedBytes: raw)
                guard frame.operationID == self.requestID, frame.data.count <= 16 * 1024,
                    self.buffer.count + frame.data.count <= ScreenClipboardContent.binaryLimit + 65536 else { throw self.failure("Invalid clipboard response") }
                self.buffer.append(frame.data)
                if frame.end { self.finish(.success(try Dieter_V1_RemoteDesktopClipboardResponse(serializedBytes: self.buffer))) }
            } catch { self.finish(.failure(error)); dataChannel.close() }
        }
    }
}
