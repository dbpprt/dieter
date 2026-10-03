#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import Metal
    import QuartzCore
    import SharedCore
    import UIKit
    @preconcurrency import WebRTC

    extension CoreScreenMedia {
        /// iPhone and iPad: screens draw through Metal.
        static func iOS() -> CoreScreenMedia {
            CoreScreenMedia { MTLCreateSystemDefaultDevice() == nil ? "Metal is unavailable on this device." : nil }
        }
    }

    /// A screen view's picture on iPhone and iPad: WebRTC's Metal view draws
    /// every decoded frame. Engines hand frames over on the decoder's thread;
    /// the newest one is drawn on the main thread and reported as presented.
    /// A reset starts a new generation, so decode paths handed out before it
    /// drop their frames and every engine takes a fresh one.
    @MainActor
    final class IOSScreenVideoView: UIView, ScreenRenderer {
        var onFramePresented: (@MainActor (RTCVideoFrame) -> Void)?
        var onFailure: (@MainActor (String) -> Void)?
        /// The decoded picture's size in pixels changed.
        var onVideoSize: (@MainActor (CGSize) -> Void)?
        /// The decoded picture's size in pixels, rotation applied; zero
        /// before the first frame.
        private(set) var videoSize = CGSize.zero
        private let video = RTCMTLVideoView(frame: .zero)
        nonisolated private let mailbox = IOSScreenFrameMailbox()
        /// RTCMTLVideoView draws a frame only when its timestamp changes, and
        /// decoders may leave it unset, so frames are restamped in order.
        private var drawn: Int64 = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            video.frame = bounds
            video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            video.videoContentMode = .scaleToFill
            video.isUserInteractionEnabled = false
            video.isHidden = true
            addSubview(video)
        }

        required init?(coder: NSCoder) { nil }

        func reset() {
            mailbox.advance()
            video.isHidden = true
        }

        func decodeHandler() -> @Sendable (RTCVideoFrame) -> Void {
            let mailbox = mailbox
            let generation = mailbox.generation
            return { [weak self] frame in
                guard mailbox.offer(frame, generation: generation) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.drawPending() } }
            }
        }

        nonisolated var presentationCounters: ScreenPresentationCounters { mailbox.counters }

        private func drawPending() {
            guard let frame = mailbox.take() else { return }
            let rotated = frame.rotation == ._90 || frame.rotation == ._270
            let size = CGSize(
                width: CGFloat(rotated ? frame.height : frame.width),
                height: CGFloat(rotated ? frame.width : frame.height))
            if size.width > 0, size.height > 0, size != videoSize {
                videoSize = size
                video.setSize(size)
                onVideoSize?(size)
            }
            drawn += 1
            let restamped = RTCVideoFrame(buffer: frame.buffer, rotation: frame.rotation, timeStampNs: drawn)
            restamped.timeStamp = frame.timeStamp
            let started = CACurrentMediaTime()
            video.renderFrame(restamped)
            if video.isHidden { video.isHidden = false }
            mailbox.presented(milliseconds: (CACurrentMediaTime() - started) * 1_000)
            onFramePresented?(frame)
        }
    }

    /// The newest decoded frame waiting for the main thread, and the
    /// presentation counters statistics read from any thread.
    private final class IOSScreenFrameMailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var pending: RTCVideoFrame?
        private var scheduled = false
        private var presentation = ScreenPresentationCounters()

        var generation: Int { lock.withLock { current } }

        var counters: ScreenPresentationCounters { lock.withLock { presentation } }

        /// Starts a generation: earlier decode paths and their frames are dropped.
        func advance() {
            lock.withLock {
                current += 1
                pending = nil
                presentation = ScreenPresentationCounters()
            }
        }

        /// Keeps `frame` as the newest; true when the main thread has to be woken.
        func offer(_ frame: RTCVideoFrame, generation: Int) -> Bool {
            lock.withLock {
                guard generation == current else { return false }
                pending = frame
                guard !scheduled else { return false }
                scheduled = true
                return true
            }
        }

        func take() -> RTCVideoFrame? {
            lock.withLock {
                scheduled = false
                defer { pending = nil }
                return pending
            }
        }

        func presented(milliseconds: Double) {
            lock.withLock {
                presentation.framesPresented += 1
                presentation.totalRenderMilliseconds += milliseconds
            }
        }
    }

    #if DEBUG
        /// The disposable native screen fixture the UI tests start
        /// (scripts/screens-fixture): every screen signals through its
        /// loopback daemon API instead of a machine's route.
        final class IOSScreenFixtureRoutes: NSObject, NativeScreenFixture, Sendable {
            /// What the fixture writes once it listens, base64-encoded JSON.
            private struct Connection: Decodable {
                let url: String
                let certificate: Data
                let rtc: Data
                let token: String
            }

            private let url: String
            private let token: String
            private let certificate: String
            private let rtc: Data

            /// Nil when `encoded` is not the fixture's connection.
            init?(encoded: String) {
                guard let data = Data(base64Encoded: encoded),
                    let connection = try? JSONDecoder().decode(Connection.self, from: data)
                else { return nil }
                url = connection.url
                token = connection.token
                certificate = String(decoding: connection.certificate, as: UTF8.self)
                rtc = connection.rtc
            }

            func open() -> NativeScreenFixtureRoute? {
                NativeScreenFixtureRoute(
                    url: url, token: token, certificatePem: certificate, rtc: rtc, label: "Fixture loopback")
            }
        }
    #endif
#endif
