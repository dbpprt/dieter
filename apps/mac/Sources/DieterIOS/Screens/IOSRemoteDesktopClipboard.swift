#if os(iOS)
    import DieterAPI
    import DieterCore
    import Foundation
    @preconcurrency import WebRTC

    /// Explicit, foreground-only text clipboard transport for an authenticated
    /// protocol-3 screen session. It never polls the local pasteboard and never
    /// retries an operation whose outcome is uncertain.
    @MainActor
    final class IOSRemoteDesktopClipboard: NSObject, RTCDataChannelDelegate {
        static let textLimit = 1 << 20

        var makeRequest: (() -> Dieter_V1_RemoteDesktopClipboardRequest?)?
        var isCurrentGrant: ((UInt64) -> Bool)?
        var onBusy: ((Bool) -> Void)?
        var onError: ((String) -> Void)?
        var onCopiedText: ((String) -> Void)?
        var onUnavailable: (() -> Void)?
        var onAvailabilityChanged: ((Bool) -> Void)?
        var onOperationFinished: ((Bool) -> Void)?

        private var channel: RTCDataChannel?
        private var continuation: CheckedContinuation<Dieter_V1_RemoteDesktopClipboardResponse, Error>?
        private var requestID = ""
        private var buffer = Data()
        private var serial: UInt64 = 0
        private var busy = false

        var available: Bool { channel?.readyState == .open && !busy }

        func attach(_ channel: RTCDataChannel) {
            close()
            self.channel = channel
            channel.delegate = self
            onAvailabilityChanged?(channel.readyState == .open)
        }

        func close() {
            serial &+= 1
            channel?.delegate = nil
            channel?.close()
            channel = nil
            continuation?.resume(throwing: CancellationError())
            continuation = nil
            requestID = ""
            buffer.removeAll(keepingCapacity: true)
            busy = false
            onBusy?(false)
            onAvailabilityChanged?(false)
        }

        func copySelection() {
            perform(.copy) { [weak self] response in
                guard response.hasText_p else {
                    self?.onError?("The remote selection has no text to copy.")
                    return
                }
                self?.onCopiedText?(response.text)
            }
        }

        func paste(text: String) {
            guard !text.isEmpty else {
                onError?("The pasteboard has no text to paste.")
                return
            }
            guard text.utf8.count <= Self.textLimit else {
                onError?("Clipboard text exceeds 1 MiB.")
                return
            }
            perform(.paste, text: text)
        }

        private func perform(
            _ action: Dieter_V1_RemoteDesktopClipboardRequest.Action,
            text: String = "",
            success: ((Dieter_V1_RemoteDesktopClipboardResponse) -> Void)? = nil
        ) {
            guard !busy else {
                onError?("A clipboard operation is still in progress.")
                return
            }
            let token = serial
            Task { [weak self] in
                guard let self else { return }
                var succeeded = false
                defer {
                    if token == self.serial { self.onOperationFinished?(succeeded) }
                }
                do {
                    let response = try await self.exchange(action, text: text)
                    guard token == self.serial else { return }
                    self.onError?("")
                    success?(response)
                    succeeded = true
                } catch {
                    guard token == self.serial, !DieterRPCFailure.isCancellation(error) else { return }
                    self.onError?(error.localizedDescription)
                }
            }
        }

        private func exchange(
            _ action: Dieter_V1_RemoteDesktopClipboardRequest.Action,
            text: String
        ) async throws -> Dieter_V1_RemoteDesktopClipboardResponse {
            guard text.utf8.count <= Self.textLimit,
                var request = makeRequest?(),
                let channel,
                channel.readyState == .open,
                isCurrentGrant?(request.controlGeneration) == true
            else { throw failure("Clipboard unavailable for this viewer.") }

            let token = serial
            busy = true
            onBusy?(true)
            defer {
                if token == serial {
                    busy = false
                    requestID = ""
                    buffer.removeAll(keepingCapacity: true)
                    onBusy?(false)
                }
            }

            request.operationID = UUID().uuidString.lowercased()
            request.action = action
            request.text = text
            request.acceptBinary = false
            requestID = request.operationID
            let raw = try request.serializedData()

            let response = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Dieter_V1_RemoteDesktopClipboardResponse, Error>) in
                self.continuation = continuation
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        for offset in stride(from: 0, to: raw.count, by: 16 * 1024) {
                            while channel.bufferedAmount > 32 * 1024 {
                                guard token == self.serial, self.continuation != nil else {
                                    throw CancellationError()
                                }
                                try await DieterTaskSleep.seconds(0.005)
                            }
                            guard token == self.serial, self.continuation != nil else {
                                throw CancellationError()
                            }
                            let end = min(raw.count, offset + 16 * 1024)
                            var frame = Dieter_V1_RemoteDesktopClipboardFrame()
                            frame.operationID = request.operationID
                            frame.data = raw.subdata(in: offset..<end)
                            frame.end = end == raw.count
                            guard
                                channel.sendData(
                                    RTCDataBuffer(data: try frame.serializedData(), isBinary: true))
                            else { throw self.failure("Clipboard transfer failed.") }
                        }
                    } catch {
                        if token == self.serial, self.requestID == request.operationID {
                            self.finish(.failure(error))
                        }
                    }
                }
                Task { [weak self] in
                    try? await DieterTaskSleep.seconds(30)
                    guard let self, token == self.serial,
                        self.requestID == request.operationID, self.continuation != nil
                    else { return }
                    self.finish(.failure(self.failure("Clipboard timed out; the operation was not retried.")))
                    channel.close()
                }
            }

            guard token == serial, isCurrentGrant?(request.controlGeneration) == true else {
                throw CancellationError()
            }
            if !response.error.isEmpty { throw failure(response.error) }
            return response
        }

        private func failure(_ text: String) -> NSError {
            NSError(
                domain: "DieterClipboard", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
        }

        private func finish(_ result: Result<Dieter_V1_RemoteDesktopClipboardResponse, Error>) {
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }

        nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
            Task { @MainActor [weak self] in
                guard let self, self.channel === dataChannel else { return }
                self.onAvailabilityChanged?(dataChannel.readyState == .open)
                guard dataChannel.readyState == .closed else { return }
                self.finish(.failure(self.failure("Clipboard transfer interrupted; the operation was not retried.")))
                self.onUnavailable?()
            }
        }

        nonisolated func dataChannel(
            _ dataChannel: RTCDataChannel,
            didReceiveMessageWith data: RTCDataBuffer
        ) {
            guard data.isBinary, data.data.count <= 16 * 1024 + 128 else { return }
            let raw = data.data
            Task { @MainActor [weak self] in
                guard let self, self.channel === dataChannel, self.continuation != nil else { return }
                do {
                    let frame = try Dieter_V1_RemoteDesktopClipboardFrame(serializedBytes: raw)
                    guard frame.operationID == self.requestID, frame.data.count <= 16 * 1024,
                        self.buffer.count + frame.data.count <= Self.textLimit + 65_536
                    else { throw self.failure("Invalid clipboard response.") }
                    self.buffer.append(frame.data)
                    if frame.end {
                        self.finish(
                            .success(
                                try Dieter_V1_RemoteDesktopClipboardResponse(
                                    serializedBytes: self.buffer)))
                    }
                } catch {
                    self.finish(.failure(error))
                    dataChannel.close()
                }
            }
        }
    }
#endif
