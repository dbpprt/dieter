import AppKit
import CryptoKit
import DieterAPI
import Foundation
import OSLog
import Observation
import Security
import SwiftProtobuf
@preconcurrency import WebRTC

enum RemoteDesktopPhase: Equatable, Sendable {
  case idle
  case loading
  case disabled(String)
  case connecting
  case streaming
  case reconnecting
  case failed(String)

  var label: String {
    switch self {
    case .idle: "Not connected"
    case .loading: "Checking machine…"
    case .disabled: "Screen sharing is off"
    case .connecting: "Connecting…"
    case .streaming: "Live"
    case .reconnecting: "Reconnecting…"
    case .failed: "Connection failed"
    }
  }
}

enum RemoteDesktopSessionTrust {
  enum Failure: LocalizedError {
    case invalidBinding
    case expiredBinding
    case invalidCertificate
    case invalidSignature

    var errorDescription: String? {
      switch self {
      case .invalidBinding:
        "The daemon returned a screen-sharing answer that was not bound to this request."
      case .expiredBinding: "The daemon screen-sharing binding has expired."
      case .invalidCertificate: "The enrolled daemon certificate is invalid."
      case .invalidSignature: "The daemon screen-sharing signature could not be verified."
      }
    }
  }

  static func verify(
    binding: Dieter_V1_RemoteDesktopSessionBinding,
    sessionID: String,
    clientNonce: String,
    offerSDP: String,
    answerSDP: String,
    daemonCertificatePEM: Data,
    now: Date = Date()
  ) throws {
    let offerHash = Data(SHA256.hash(data: Data(offerSDP.utf8)))
    guard binding.clientNonce == clientNonce,
      binding.offerSha256 == offerHash,
      binding.helperDtlsFingerprint == fingerprint(in: answerSDP),
      binding.inputProtocolVersion == 1,
      binding.inputEpoch.count == 16,
      !sessionID.isEmpty
    else { throw Failure.invalidBinding }
    guard let expires = timestamp(binding.expiresAt), expires > now else {
      throw Failure.expiredBinding
    }
    guard let certificate = certificate(fromPEM: daemonCertificatePEM),
      let publicKey = SecCertificateCopyKey(certificate)
    else { throw Failure.invalidCertificate }
    let message = bindingMessage(
      sessionID: sessionID, nonce: clientNonce,
      fingerprint: binding.helperDtlsFingerprint, expiresAt: binding.expiresAt,
      offerHash: offerHash, controlGranted: binding.controlGranted,
      displayID: binding.displayID, inputProtocolVersion: binding.inputProtocolVersion,
      inputEpoch: binding.inputEpoch
    )
    var keyError: Unmanaged<CFError>?
    guard let rawKey = SecKeyCopyExternalRepresentation(publicKey, &keyError) as Data?,
      let signingKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
      signingKey.isValidSignature(binding.daemonSignature, for: message)
    else {
      throw Failure.invalidSignature
    }
  }

  static func bindingMessage(
    sessionID: String,
    nonce: String,
    fingerprint: String,
    expiresAt: String,
    offerHash: Data,
    controlGranted: Bool,
    displayID: String,
    inputProtocolVersion: UInt32,
    inputEpoch: Data
  ) -> Data {
    let encodedHash = offerHash.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return Data(
      [
        "dieter-remote-desktop-v2", sessionID, nonce, fingerprint, expiresAt, encodedHash,
        controlGranted ? "true" : "false", displayID, String(inputProtocolVersion),
        inputEpoch.base64URLEncodedString(),
      ].joined(separator: "\n").utf8)
  }

  static func fingerprint(in sdp: String) -> String {
    for line in sdp.split(whereSeparator: \.isNewline) {
      let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix("a=fingerprint:") {
        return String(value.dropFirst("a=fingerprint:".count)).trimmingCharacters(in: .whitespaces)
      }
    }
    return ""
  }

  private static func timestamp(_ value: String) -> Date? {
    DieterTimestamp.date(from: value)
  }

  private static func certificate(fromPEM pem: Data) -> SecCertificate? {
    guard let text = String(data: pem, encoding: .utf8) else { return nil }
    let body =
      text
      .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
      .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
    guard let der = Data(base64Encoded: body) else { return nil }
    return SecCertificateCreateWithData(nil, der as CFData)
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

@MainActor
@Observable
final class RemoteDesktopController {
  private static let mediaLogger = Logger(
    subsystem: "com.dbpprt.dieter.mac", category: "remote-desktop-media")
  var phase: RemoteDesktopPhase = .idle
  var capabilities = Dieter_V1_RemoteDesktopCapabilities()
  var settings = Dieter_V1_RemoteDesktopSettings()
  var routeLabel = ""
  var machineName = ""
  var errorMessage: String?
  var controlActive = false
  var controlUnavailableReason = ""

  let renderer = RTCMTLNSVideoView(frame: .zero)

  private let factory = RTCPeerConnectionFactory(
    encoderFactory: RTCDefaultVideoEncoderFactory(),
    decoderFactory: RTCDefaultVideoDecoderFactory()
  )
  private let delegate = RemoteDesktopPeerDelegate()
  private var peerConnection: RTCPeerConnection?
  private var connection: RemoteDesktopSignalingConnection?
  private var request: Dieter_V1_StartRemoteDesktopRequest?
  private var binding: Dieter_V1_RemoteDesktopSessionBinding?
  private var answerSDP: String?
  private var remoteDescriptionApplied = false
  private var pendingLocalCandidates: [RTCIceCandidate] = []
  private var pendingRemoteCandidates: [RTCIceCandidate] = []
  private var sessionID = ""
  private var signalingTask: Task<Void, Never>?
  private var leaseTask: Task<Void, Never>?
  private var statisticsTask: Task<Void, Never>?
  private var videoTrack: RTCVideoTrack?
  private var pointerChannel: RTCDataChannel?
  private var stateChannel: RTCDataChannel?
  private var pointerChannelDelegate: RemoteDesktopDataChannelDelegate?
  private var stateChannelDelegate: RemoteDesktopDataChannelDelegate?
  private var pointerSequence: UInt64 = 0
  private var stateSequence: UInt64 = 0
  private var pendingPointer: (Int32, Int32)?
  private var pointerFlushTask: Task<Void, Never>?
  private var signalingReceiveFailure: String?

  init() {
    delegate.owner = self
    renderer.wantsLayer = true
    renderer.layer?.backgroundColor = NSColor.black.cgColor
  }

  func connect(store: DieterStore, machine: DieterEndpoint) async {
    disconnect()
    phase = .loading
    machineName = machine.name
    do {
      let connection = try await store.remoteDesktopConnection(machineID: machine.id)
      self.connection = connection
      routeLabel = connection.routeLabel
      settings = try await connection.rpc.remoteDesktopSettings()
      capabilities = try await connection.rpc.remoteDesktopCapabilities()
      guard settings.enabled else {
        phase = .disabled(capabilities.unavailableReason)
        return
      }
      try await startPeerSession()
    } catch is CancellationError {
      disconnect()
    } catch {
      fail(error)
    }
  }

  func enableAndConnect() async {
    guard let connection else { return }
    phase = .loading
    do {
      settings = try await connection.rpc.updateRemoteDesktopSettings(enabled: true)
      capabilities = try await connection.rpc.remoteDesktopCapabilities()
      try await startPeerSession()
    } catch {
      fail(error)
    }
  }

  func disconnect() {
    releaseAllInput()
    signalingTask?.cancel()
    leaseTask?.cancel()
    statisticsTask?.cancel()
    pointerFlushTask?.cancel()
    signalingTask = nil
    leaseTask = nil
    statisticsTask = nil
    pointerFlushTask = nil
    let previousConnection = connection
    let previousSessionID = sessionID
    if !previousSessionID.isEmpty {
      Task {
        try? await previousConnection?.rpc.closeRemoteDesktop(sessionID: previousSessionID)
        previousConnection?.shutdown()
      }
    } else {
      previousConnection?.shutdown()
    }
    videoTrack?.remove(renderer)
    videoTrack = nil
    pointerChannel?.close()
    stateChannel?.close()
    pointerChannel = nil
    stateChannel = nil
    pointerChannelDelegate = nil
    stateChannelDelegate = nil
    peerConnection?.close()
    peerConnection = nil
    connection = nil
    request = nil
    binding = nil
    answerSDP = nil
    remoteDescriptionApplied = false
    pendingLocalCandidates.removeAll()
    pendingRemoteCandidates.removeAll()
    signalingReceiveFailure = nil
    sessionID = ""
    pointerSequence = 0
    stateSequence = 0
    pendingPointer = nil
    controlActive = false
    routeLabel = ""
    if case .failed = phase {} else { phase = .idle }
  }

  private func startPeerSession() async throws {
    guard capabilities.ready else {
      throw NSError(
        domain: "DieterScreens", code: 5,
        userInfo: [
          NSLocalizedDescriptionKey: capabilities.unavailableReason.isEmpty
            ? "Screen sharing is not ready on this machine." : capabilities.unavailableReason
        ]
      )
    }
    guard let connection else { return }
    phase = .connecting
    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    configuration.continualGatheringPolicy = .gatherContinually
    configuration.iceServers = connection.rtcConfiguration.iceServers.map {
      RTCIceServer(
        urlStrings: $0.urls,
        username: $0.username.isEmpty ? nil : $0.username,
        credential: $0.credential.isEmpty ? nil : $0.credential
      )
    }
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    guard
      let peer = factory.peerConnection(
        with: configuration, constraints: constraints, delegate: delegate)
    else {
      throw NSError(
        domain: "DieterScreens", code: 6,
        userInfo: [NSLocalizedDescriptionKey: "WebRTC could not create a peer connection."])
    }
    peerConnection = peer
    let pointerConfiguration = RTCDataChannelConfiguration()
    pointerConfiguration.isOrdered = false
    pointerConfiguration.maxRetransmits = 0
    pointerChannel = peer.dataChannel(forLabel: "dieter-pointer-v1", configuration: pointerConfiguration)
    let stateConfiguration = RTCDataChannelConfiguration()
    stateConfiguration.isOrdered = true
    stateChannel = peer.dataChannel(forLabel: "dieter-input-state-v1", configuration: stateConfiguration)
    let pointerDelegate = RemoteDesktopDataChannelDelegate(owner: self)
    let stateDelegate = RemoteDesktopDataChannelDelegate(owner: self)
    pointerChannelDelegate = pointerDelegate
    stateChannelDelegate = stateDelegate
    pointerChannel?.delegate = pointerDelegate
    stateChannel?.delegate = stateDelegate
    let transceiver = RTCRtpTransceiverInit()
    transceiver.direction = .recvOnly
    guard let videoTransceiver = peer.addTransceiver(of: .video, init: transceiver) else {
      throw NSError(
        domain: "DieterScreens", code: 7,
        userInfo: [NSLocalizedDescriptionKey: "WebRTC could not create a receive-only video track."]
      )
    }
    let h264 = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
      .filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
    guard !h264.isEmpty else {
      throw NSError(
        domain: "DieterScreens", code: 12,
        userInfo: [
          NSLocalizedDescriptionKey: "This Mac does not provide a compatible H.264 WebRTC decoder."
        ])
    }
    try videoTransceiver.setCodecPreferences(h264, error: ())
    let offer = try await createOffer(peer, constraints: constraints)
    try await setLocalDescription(offer, on: peer)

    var request = Dieter_V1_StartRemoteDesktopRequest()
    request.clientNonce = UUID().uuidString.lowercased()
    request.rtcConfiguration = connection.rtcConfiguration
    request.displayID =
      capabilities.displays.first(where: \.primary)?.id ?? capabilities.displays.first?.id
      ?? "primary"
    request.maxFps = 30
    request.maxBitrateKbps = 4_000
    request.maxWidth = 1_920
    request.maxHeight = 1_080
    request.control = settings.controlEnabled && capabilities.controlSupported
      && capabilities.controlPermission == "granted"
    controlUnavailableReason = settings.controlEnabled && !request.control
      ? "Accessibility permission is required on the host" : ""
    var description = Dieter_V1_RemoteDesktopSessionDescription()
    description.type = "offer"
    description.sdp = offer.sdp
    request.offer = description
    self.request = request
    startSignaling(connection: connection, request: request)
  }

  private func startSignaling(
    connection: RemoteDesktopSignalingConnection, request: Dieter_V1_StartRemoteDesktopRequest
  ) {
    signalingTask?.cancel()
    signalingTask = Task { [weak self] in
      var attempt = 0
      while !Task.isCancelled {
        do {
          self?.signalingReceiveFailure = nil
          try await connection.rpc.startRemoteDesktop(request) { [weak self] signal in
            guard let self else { throw CancellationError() }
            do {
              try await self.receive(signal)
            } catch {
              await self.rememberSignalingReceiveFailure(DieterRPCFailure.message(for: error))
              throw error
            }
          }
          if !Task.isCancelled {
            throw NSError(
              domain: "DieterScreens", code: 8,
              userInfo: [NSLocalizedDescriptionKey: "Screen-sharing signaling ended."])
          }
        } catch is CancellationError {
          return
        } catch {
          let failureMessage = self?.signalingReceiveFailure ?? DieterRPCFailure.message(for: error)
          attempt += 1
          guard attempt <= 2, self?.peerConnection != nil else {
            self?.fail(message: failureMessage)
            return
          }
          self?.setReconnecting()
          try? await DieterTaskSleep.seconds(Double(attempt))
        }
      }
    }
  }

  private func receive(_ signal: Dieter_V1_RemoteDesktopSignal) async throws {
    if sessionID.isEmpty {
      sessionID = signal.sessionID
      flushLocalCandidates()
      startLease()
    } else if signal.sessionID != sessionID {
      throw RemoteDesktopSessionTrust.Failure.invalidBinding
    }
    switch signal.payload {
    case .binding(let value):
      binding = value
      try await applyVerifiedAnswerIfReady()
    case .description_p(let value):
      guard value.type == "answer" else { return }
      answerSDP = value.sdp
      try await applyVerifiedAnswerIfReady()
    case .candidate(let value):
      let candidate = RTCIceCandidate(
        sdp: value.candidate, sdpMLineIndex: value.sdpMlineIndex,
        sdpMid: value.sdpMid.isEmpty ? nil : value.sdpMid)
      if remoteDescriptionApplied {
        try await addIceCandidate(candidate)
      } else {
        pendingRemoteCandidates.append(candidate)
      }
    case .state(let value):
      if value.phase == "streaming" { phase = .streaming }
      if value.phase == "reconnecting" { phase = .reconnecting }
      if value.phase == "closed", phase != .idle {
        peerConnection?.close()
        peerConnection = nil
        throw NSError(
          domain: "DieterScreens", code: 9,
          userInfo: [
            NSLocalizedDescriptionKey: value.reason.isEmpty
              ? "The screen-sharing session closed." : value.reason
          ])
      }
    case .error(let value):
      if !value.recoverable {
        peerConnection?.close()
        peerConnection = nil
      }
      throw NSError(
        domain: "DieterScreens", code: 10, userInfo: [NSLocalizedDescriptionKey: value.message])
    case .leaseHeartbeat, .none:
      break
    }
  }

  private func applyVerifiedAnswerIfReady() async throws {
    guard !remoteDescriptionApplied,
      let connection, let request, let binding, let answerSDP
    else { return }
    try RemoteDesktopSessionTrust.verify(
      binding: binding, sessionID: sessionID, clientNonce: request.clientNonce,
      offerSDP: request.offer.sdp, answerSDP: answerSDP,
      daemonCertificatePEM: connection.daemonCertificatePEM
    )
    guard binding.controlGranted == request.control, binding.displayID == request.displayID else {
      throw RemoteDesktopSessionTrust.Failure.invalidBinding
    }
    guard let peerConnection else { throw CancellationError() }
    try await setRemoteDescription(
      RTCSessionDescription(type: .answer, sdp: answerSDP), on: peerConnection)
    remoteDescriptionApplied = true
    controlActive = binding.controlGranted
    let candidates = pendingRemoteCandidates
    pendingRemoteCandidates.removeAll()
    for candidate in candidates { try await addIceCandidate(candidate) }
  }

  private func startLease() {
    leaseTask?.cancel()
    leaseTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await DieterTaskSleep.seconds(5)
        guard !Task.isCancelled, let self, let connection = self.connection, !self.sessionID.isEmpty
        else { return }
        var signal = Dieter_V1_RemoteDesktopSignal()
        signal.sessionID = self.sessionID
        signal.leaseHeartbeat = Google_Protobuf_Empty()
        do { try await connection.rpc.sendRemoteDesktopSignal(signal) } catch {
          self.setReconnecting()
        }
      }
    }
  }

  fileprivate func generated(candidate: RTCIceCandidate) {
    guard !sessionID.isEmpty else {
      pendingLocalCandidates.append(candidate)
      return
    }
    send(candidate: candidate)
  }

  private func flushLocalCandidates() {
    let candidates = pendingLocalCandidates
    pendingLocalCandidates.removeAll()
    for candidate in candidates { send(candidate: candidate) }
  }

  private func send(candidate: RTCIceCandidate) {
    guard let connection, !sessionID.isEmpty else { return }
    var value = Dieter_V1_RemoteDesktopICECandidate()
    value.candidate = candidate.sdp
    value.sdpMid = candidate.sdpMid ?? ""
    value.sdpMlineIndex = candidate.sdpMLineIndex
    var signal = Dieter_V1_RemoteDesktopSignal()
    signal.sessionID = sessionID
    signal.candidate = value
    Task { try? await connection.rpc.sendRemoteDesktopSignal(signal) }
  }

  fileprivate func received(track: RTCVideoTrack) {
    videoTrack?.remove(renderer)
    videoTrack = track
    track.add(renderer)
  }

  fileprivate func connectionStateChanged(_ state: RTCPeerConnectionState) {
    switch state {
    case .connected:
      phase = .streaming
      startStatistics()
    case .disconnected:
      releaseAllInput()
      phase = .reconnecting
    case .failed:
      fail(
        NSError(
          domain: "DieterScreens", code: 11,
          userInfo: [NSLocalizedDescriptionKey: "The WebRTC connection failed."]))
    case .closed:
      if case .failed = phase { return }
      if phase != .idle { phase = .idle }
    default: break
    }
  }

  private func setReconnecting() { if phase != .idle { phase = .reconnecting } }

  func sendPointerMove(x: CGFloat, y: CGFloat) {
    guard controlActive else { return }
    pendingPointer = (normalized(x), normalized(y))
    guard pointerFlushTask == nil else { return }
    pointerFlushTask = Task { [weak self] in
      try? await DieterTaskSleep.seconds(0.008)
      guard !Task.isCancelled, let self else { return }
      self.pointerFlushTask = nil
      guard let point = self.pendingPointer else { return }
      self.pendingPointer = nil
      var move = Dieter_V1_RemoteDesktopPointerMove()
      move.normalizedX = point.0
      move.normalizedY = point.1
      self.sendPointer(.pointerMove(move))
    }
  }

  func sendPointerButton(
    _ button: Dieter_V1_RemoteDesktopPointerButton.Button, down: Bool,
    clickCount: Int, x: CGFloat, y: CGFloat, modifiers: NSEvent.ModifierFlags
  ) {
    var value = Dieter_V1_RemoteDesktopPointerButton()
    value.button = button
    value.down = down
    value.clickCount = Int32(max(0, min(3, clickCount)))
    value.normalizedX = normalized(x)
    value.normalizedY = normalized(y)
    value.modifiers = Self.modifiers(modifiers)
    sendState(.pointerButton(value))
  }

  func sendScroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool, modifiers: NSEvent.ModifierFlags) {
    var value = Dieter_V1_RemoteDesktopScroll()
    value.deltaX = Int32(clamping: Int(deltaX.rounded()))
    value.deltaY = Int32(clamping: Int(deltaY.rounded()))
    value.precise = precise
    value.modifiers = Self.modifiers(modifiers)
    sendState(.scroll(value))
  }

  func sendKey(code: UInt16, down: Bool, repeat isRepeat: Bool, modifiers: NSEvent.ModifierFlags) {
    var value = Dieter_V1_RemoteDesktopKey()
    value.keyCode = UInt32(code)
    value.down = down
    value.repeat = isRepeat
    value.modifiers = Self.modifiers(modifiers)
    sendState(.key(value))
  }

  func releaseAllInput() {
    guard controlActive else { return }
    sendState(.releaseAll(Dieter_V1_RemoteDesktopReleaseAll()))
  }

  private func sendPointer(_ payload: Dieter_V1_RemoteDesktopInput.OneOf_Payload) {
    guard let channel = pointerChannel, channel.readyState == .open, channel.bufferedAmount < 65_536,
      let binding else { return }
    pointerSequence &+= 1
    send(payload, sequence: pointerSequence, binding: binding, channel: channel)
  }

  private func sendState(_ payload: Dieter_V1_RemoteDesktopInput.OneOf_Payload) {
    guard controlActive, let channel = stateChannel, channel.readyState == .open,
      channel.bufferedAmount < 262_144, let binding else { return }
    stateSequence &+= 1
    send(payload, sequence: stateSequence, binding: binding, channel: channel)
  }

  private func send(
    _ payload: Dieter_V1_RemoteDesktopInput.OneOf_Payload, sequence: UInt64,
    binding: Dieter_V1_RemoteDesktopSessionBinding, channel: RTCDataChannel
  ) {
    var input = Dieter_V1_RemoteDesktopInput()
    input.protocolVersion = binding.inputProtocolVersion
    input.inputEpoch = binding.inputEpoch
    input.sequence = sequence
    input.payload = payload
    guard let data = try? input.serializedData(), data.count <= 4_096 else { return }
    _ = channel.sendData(RTCDataBuffer(data: data, isBinary: true))
  }

  private func normalized(_ value: CGFloat) -> Int32 {
    Int32((max(0, min(1, value)) * 1_000_000).rounded())
  }

  private static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var value: UInt32 = 0
    if flags.contains(.shift) { value |= 1 }
    if flags.contains(.control) { value |= 2 }
    if flags.contains(.option) { value |= 4 }
    if flags.contains(.command) { value |= 8 }
    if flags.contains(.capsLock) { value |= 16 }
    if flags.contains(.function) { value |= 32 }
    return value
  }

  private func startStatistics() {
    statisticsTask?.cancel()
    statisticsTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await DieterTaskSleep.seconds(5)
        guard !Task.isCancelled, let self, let peer = self.peerConnection else { return }
        let report = await peer.statistics()
        var inbound: [String: NSObject] = [:]
        var candidate: [String: NSObject] = [:]
        for statistic in report.statistics.values {
          if statistic.type == "inbound-rtp",
            statistic.values["kind"] as? String == "video"
          {
            inbound = statistic.values
          } else if statistic.type == "candidate-pair",
            statistic.values["nominated"] as? Bool == true
          {
            candidate = statistic.values
          }
        }
        let emitted = (inbound["jitterBufferEmittedCount"] as? NSNumber)?.doubleValue ?? 0
        let jitter = (inbound["jitterBufferDelay"] as? NSNumber)?.doubleValue ?? 0
        let jitterMilliseconds = emitted > 0 ? jitter * 1_000 / emitted : 0
        Self.mediaLogger.info(
          "receiver framesDecoded=\((inbound["framesDecoded"] as? NSNumber)?.intValue ?? 0) framesDropped=\((inbound["framesDropped"] as? NSNumber)?.intValue ?? 0) packetsLost=\((inbound["packetsLost"] as? NSNumber)?.intValue ?? 0) jitterBufferMs=\(jitterMilliseconds, format: .fixed(precision: 1)) rttMs=\(((candidate["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? 0) * 1_000, format: .fixed(precision: 1))"
        )
      }
    }
  }

  private func fail(_ error: Error) {
    fail(message: DieterRPCFailure.message(for: error))
  }

  private func fail(message: String) {
    errorMessage = message
    phase = .failed(message)
    disconnect()
  }

  private func rememberSignalingReceiveFailure(_ message: String) {
    signalingReceiveFailure = message
  }

  private func createOffer(_ peer: RTCPeerConnection, constraints: RTCMediaConstraints) async throws
    -> RTCSessionDescription
  {
    try await withCheckedThrowingContinuation { continuation in
      peer.offer(for: constraints) { description, error in
        if let description {
          continuation.resume(returning: description)
        } else {
          continuation.resume(throwing: error ?? CancellationError())
        }
      }
    }
  }

  private func setLocalDescription(_ description: RTCSessionDescription, on peer: RTCPeerConnection)
    async throws
  {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setLocalDescription(description) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private func setRemoteDescription(
    _ description: RTCSessionDescription, on peer: RTCPeerConnection
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setRemoteDescription(description) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
    guard let peerConnection else { throw CancellationError() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peerConnection.add(candidate) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }
}

private final class RemoteDesktopPeerDelegate: NSObject, RTCPeerConnectionDelegate,
  @unchecked Sendable
{
  weak var owner: RemoteDesktopController?

  func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
  ) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
    guard let track = stream.videoTracks.first else { return }
    Task { @MainActor [weak owner] in owner?.received(track: track) }
  }
  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
  func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
  ) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState)
  {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
    Task { @MainActor [weak owner] in owner?.generated(candidate: candidate) }
  }
  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate])
  {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
  func peerConnection(
    _ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState
  ) {
    Task { @MainActor [weak owner] in owner?.connectionStateChanged(newState) }
  }
  func peerConnection(
    _ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
    streams: [RTCMediaStream]
  ) {
    guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
    Task { @MainActor [weak owner] in owner?.received(track: track) }
  }
}

private final class RemoteDesktopDataChannelDelegate: NSObject, RTCDataChannelDelegate,
  @unchecked Sendable
{
  weak var owner: RemoteDesktopController?

  init(owner: RemoteDesktopController) { self.owner = owner }

  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    guard dataChannel.readyState == .closed else { return }
    Task { @MainActor [weak owner] in owner?.releaseAllInput() }
  }

  func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
