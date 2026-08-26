import CoreMedia
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

private let streamMagic = Data("DTH1".utf8)

private struct CaptureOptions {
  var displayID = "primary"
  var fps = 30
  var bitrateKbps = 4_000
  var maxWidth = 1_920
  var maxHeight = 1_080

  static func parse() throws -> CaptureOptions {
    var value = CaptureOptions()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let name = arguments.removeFirst()
      guard !arguments.isEmpty else { throw CaptureError.invalidArgument(name) }
      let raw = arguments.removeFirst()
      switch name {
      case "--display-id": value.displayID = raw
      case "--fps": value.fps = try integer(raw, name: name, range: 1...120)
      case "--bitrate-kbps": value.bitrateKbps = try integer(raw, name: name, range: 100...100_000)
      case "--max-width": value.maxWidth = try integer(raw, name: name, range: 320...16_384)
      case "--max-height": value.maxHeight = try integer(raw, name: name, range: 180...16_384)
      default: throw CaptureError.invalidArgument(name)
      }
    }
    return value
  }

  private static func integer(_ raw: String, name: String, range: ClosedRange<Int>) throws -> Int {
    guard let value = Int(raw), range.contains(value) else {
      throw CaptureError.invalidArgument(name)
    }
    return value
  }
}

private enum CaptureError: LocalizedError {
  case invalidArgument(String)
  case noDisplay
  case encoder(OSStatus)
  case invalidFrame

  var errorDescription: String? {
    switch self {
    case .invalidArgument(let name): "Invalid or missing value for \(name)"
    case .noDisplay: "The selected display is not available"
    case .encoder(let status): "VideoToolbox failed with status \(status)"
    case .invalidFrame: "ScreenCaptureKit produced an invalid frame"
    }
  }
}

private final class InputInjector: @unchecked Sendable {
  private let displayBounds: CGRect
  private let source = CGEventSource(stateID: .privateState)
  private var position: CGPoint
  private var heldButtons = Set<Int32>()
  private var heldKeys = Set<UInt16>()
  private var currentModifiers: UInt32 = 0

  init(displayID: CGDirectDisplayID) {
    displayBounds = CGDisplayBounds(displayID)
    position = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
  }

  func handle(_ value: [String: Any]) {
    guard let kind = value["kind"] as? String else { return }
    switch kind {
    case "pointer_move":
      guard let point = point(value) else { return }
      position = point
      let type: CGEventType
      let dragButton: Int32
      if heldButtons.contains(1) { type = .leftMouseDragged; dragButton = 1 }
      else if heldButtons.contains(2) { type = .rightMouseDragged; dragButton = 2 }
      else if let button = heldButtons.first { type = .otherMouseDragged; dragButton = button }
      else { type = .mouseMoved; dragButton = 1 }
      postMouse(type: type, button: dragButton, point: point, clickCount: 0, modifiers: currentModifiers)
    case "pointer_button":
      guard let point = point(value), let button = value["button"] as? Int,
        (1...5).contains(button), let down = value["down"] as? Bool
      else { return }
      position = point
      currentModifiers = UInt32(clamping: value["modifiers"] as? Int ?? 0)
      if down { heldButtons.insert(Int32(button)) } else { heldButtons.remove(Int32(button)) }
      let type: CGEventType
      switch (button, down) {
      case (1, true): type = .leftMouseDown
      case (1, false): type = .leftMouseUp
      case (2, true): type = .rightMouseDown
      case (2, false): type = .rightMouseUp
      case (_, true): type = .otherMouseDown
      default: type = .otherMouseUp
      }
      postMouse(
        type: type, button: Int32(button), point: point,
        clickCount: value["click_count"] as? Int ?? 1,
        modifiers: currentModifiers)
    case "scroll":
      let dx = Int32(clamping: value["delta_x"] as? Int ?? 0)
      let dy = Int32(clamping: value["delta_y"] as? Int ?? 0)
      guard let event = CGEvent(
        scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
        wheel1: dy, wheel2: dx, wheel3: 0) else { return }
      currentModifiers = UInt32(clamping: value["modifiers"] as? Int ?? 0)
      event.flags = flags(currentModifiers)
      event.post(tap: .cgSessionEventTap)
    case "key":
      guard let raw = value["key_code"] as? Int, (0...255).contains(raw),
        let down = value["down"] as? Bool else { return }
      let key = CGKeyCode(raw)
      currentModifiers = UInt32(clamping: value["modifiers"] as? Int ?? 0)
      if down { heldKeys.insert(key) } else { heldKeys.remove(key) }
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
        return
      }
      event.flags = flags(currentModifiers)
      event.post(tap: .cgSessionEventTap)
    case "release_all": releaseAll()
    default: break
    }
  }

  func releaseAll() {
    for key in heldKeys {
      CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(
        tap: .cgSessionEventTap)
    }
    heldKeys.removeAll()
    for button in heldButtons {
      let type: CGEventType = button == 1 ? .leftMouseUp : (button == 2 ? .rightMouseUp : .otherMouseUp)
      postMouse(type: type, button: button, point: position, clickCount: 1, modifiers: 0)
    }
    heldButtons.removeAll()
    currentModifiers = 0
  }

  private func point(_ value: [String: Any]) -> CGPoint? {
    guard let x = value["x"] as? Int, let y = value["y"] as? Int,
      (0...1_000_000).contains(x), (0...1_000_000).contains(y) else { return nil }
    return CGPoint(
      x: displayBounds.minX + displayBounds.width * CGFloat(x) / 1_000_000,
      y: displayBounds.minY + displayBounds.height * CGFloat(y) / 1_000_000)
  }

  private func postMouse(
    type: CGEventType, button: Int32, point: CGPoint, clickCount: Int, modifiers: UInt32
  ) {
    guard let cgButton = CGMouseButton(rawValue: UInt32(max(0, button - 1))),
      let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
        mouseButton: cgButton) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: Int64(max(0, min(3, clickCount))))
    event.flags = flags(modifiers)
    event.post(tap: .cgSessionEventTap)
  }

  private func flags(_ raw: UInt32) -> CGEventFlags {
    var value: CGEventFlags = []
    if raw & 1 != 0 { value.insert(.maskShift) }
    if raw & 2 != 0 { value.insert(.maskControl) }
    if raw & 4 != 0 { value.insert(.maskAlternate) }
    if raw & 8 != 0 { value.insert(.maskCommand) }
    if raw & 16 != 0 { value.insert(.maskAlphaShift) }
    if raw & 32 != 0 { value.insert(.maskSecondaryFn) }
    return value
  }
}

private final class FrameContext {
  let capturedAtNanoseconds: Int64
  let encodeStartedAt: UInt64

  init(capturedAtNanoseconds: Int64, encodeStartedAt: UInt64) {
    self.capturedAtNanoseconds = capturedAtNanoseconds
    self.encodeStartedAt = encodeStartedAt
  }
}

private struct CapturedFrame {
  let sampleBuffer: CMSampleBuffer
  let capturedAtNanoseconds: Int64
}

private final class CaptureRunner: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let options: CaptureOptions
  private let stateQueue = DispatchQueue(
    label: "com.dbpprt.dieter.capture.state", qos: .userInteractive)
  private let outputQueue = DispatchQueue(
    label: "com.dbpprt.dieter.capture.output", qos: .userInteractive)
  private let stopSemaphore = DispatchSemaphore(value: 0)
  private let stopLock = NSLock()

  private var stream: SCStream?
  private var encoder: VTCompressionSession?
  private var encoding = false
  private var pendingFrame: CapturedFrame?
  private var forceKeyFrame = true
  private var stopped = false
  private var frameDurationNanoseconds: UInt64
  private var inputInjector: InputInjector?

  init(options: CaptureOptions) {
    self.options = options
    self.frameDurationNanoseconds = UInt64(1_000_000_000 / max(1, options.fps))
  }

  func start() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = selectedDisplay(content.displays) else { throw CaptureError.noDisplay }
    inputInjector = InputInjector(displayID: display.displayID)
    let outputSize = scaledSize(width: display.width, height: display.height)
    try createEncoder(width: outputSize.width, height: outputSize.height)

    let configuration = SCStreamConfiguration()
    configuration.width = outputSize.width
    configuration.height = outputSize.height
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
    configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    configuration.queueDepth = 3
    configuration.showsCursor = true
    configuration.capturesAudio = false
    configuration.scalesToFit = true

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: stateQueue)
    self.stream = stream
    try await stream.startCapture()
    outputQueue.sync { FileHandle.standardOutput.write(streamMagic) }
    startControlReader()
  }

  func wait() { stopSemaphore.wait() }

  func stop() {
    stopLock.lock()
    if stopped {
      stopLock.unlock()
      return
    }
    stopped = true
    stopLock.unlock()
    DispatchQueue.main.async { [weak self] in self?.inputInjector?.releaseAll() }
    stateQueue.async { [weak self] in
      guard let self else { return }
      if let encoder = self.encoder {
        VTCompressionSessionInvalidate(encoder)
        self.encoder = nil
      }
      let stream = self.stream
      self.stream = nil
      Task {
        try? await stream?.stopCapture()
        self.stopSemaphore.signal()
      }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    writeDiagnostic("capture stopped: \(error.localizedDescription)")
    stop()
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer),
      CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    else { return }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let rawStatus = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: rawStatus), status != .complete && status != .started
    {
      return
    }

    let frame = CapturedFrame(
      sampleBuffer: sampleBuffer,
      capturedAtNanoseconds: Int64(Date().timeIntervalSince1970 * 1_000_000_000))
    if encoding {
      pendingFrame = frame
      return
    }
    encode(frame)
  }

  private func selectedDisplay(_ displays: [SCDisplay]) -> SCDisplay? {
    if options.displayID == "" || options.displayID == "primary" {
      return displays.first(where: { CGDisplayIsMain($0.displayID) != 0 }) ?? displays.first
    }
    guard let displayID = CGDirectDisplayID(options.displayID) else { return nil }
    return displays.first(where: { $0.displayID == displayID })
  }

  private func scaledSize(width: Int, height: Int) -> (width: Int, height: Int) {
    let scale = min(
      1.0, min(Double(options.maxWidth) / Double(width), Double(options.maxHeight) / Double(height))
    )
    let scaledWidth = max(2, Int(Double(width) * scale)) & ~1
    let scaledHeight = max(2, Int(Double(height) * scale)) & ~1
    return (scaledWidth, scaledHeight)
  }

  private func createEncoder(width: Int, height: Int) throws {
    var session: VTCompressionSession?
    let specification =
      [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
      ] as CFDictionary
    let attributes =
      [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
      ] as CFDictionary
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: specification,
      imageBufferAttributes: attributes,
      compressedDataAllocator: nil,
      outputCallback: { refcon, sourceFrameRefcon, status, flags, sampleBuffer in
        guard let refcon else { return }
        let runner = Unmanaged<CaptureRunner>.fromOpaque(refcon).takeUnretainedValue()
        runner.encoded(
          sourceFrameRefcon: sourceFrameRefcon, status: status, flags: flags,
          sampleBuffer: sampleBuffer)
      },
      refcon: Unmanaged.passUnretained(self).toOpaque(),
      compressionSessionOut: &session
    )
    guard status == noErr, let session else { throw CaptureError.encoder(status) }
    encoder = session

    try set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    try set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    try set(
      session, kVTCompressionPropertyKey_ProfileLevel,
      kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
    try set(session, kVTCompressionPropertyKey_ExpectedFrameRate, options.fps as CFNumber)
    try set(
      session, kVTCompressionPropertyKey_AverageBitRate, (options.bitrateKbps * 1_000) as CFNumber)
    try set(
      session, kVTCompressionPropertyKey_DataRateLimits, [options.bitrateKbps * 125, 1] as CFArray)
    try set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (options.fps * 2) as CFNumber)
    try set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
    guard prepareStatus == noErr else { throw CaptureError.encoder(prepareStatus) }
  }

  private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
    let status = VTSessionSetProperty(session, key: key, value: value)
    guard status == noErr else { throw CaptureError.encoder(status) }
  }

  private func encode(_ frame: CapturedFrame) {
    guard let encoder, let imageBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
      return
    }
    encoding = true
    let context = FrameContext(
      capturedAtNanoseconds: frame.capturedAtNanoseconds,
      encodeStartedAt: DispatchTime.now().uptimeNanoseconds
    )
    var properties: CFDictionary?
    if forceKeyFrame {
      properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
      forceKeyFrame = false
    }
    let status = VTCompressionSessionEncodeFrame(
      encoder,
      imageBuffer: imageBuffer,
      presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer),
      duration: CMTime(value: 1, timescale: CMTimeScale(options.fps)),
      frameProperties: properties,
      sourceFrameRefcon: Unmanaged.passRetained(context).toOpaque(),
      infoFlagsOut: nil
    )
    if status != noErr {
      Unmanaged<FrameContext>.fromOpaque(Unmanaged.passUnretained(context).toOpaque()).release()
      encodingCompleted()
      writeDiagnostic("encode failed: \(status)")
    }
  }

  private func encoded(
    sourceFrameRefcon: UnsafeMutableRawPointer?,
    status: OSStatus,
    flags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
  ) {
    let context = sourceFrameRefcon.map {
      Unmanaged<FrameContext>.fromOpaque($0).takeRetainedValue()
    }
    defer { stateQueue.async { [weak self] in self?.encodingCompleted() } }
    guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer, let context else {
      if status != noErr { writeDiagnostic("encode callback failed: \(status)") }
      return
    }
    do {
      let keyFrame = isKeyFrame(sampleBuffer)
      let accessUnit = try annexB(sampleBuffer, includeParameterSets: keyFrame)
      let encodeDuration = DispatchTime.now().uptimeNanoseconds - context.encodeStartedAt
      writeFrame(
        accessUnit,
        keyFrame: keyFrame,
        captureNanoseconds: context.capturedAtNanoseconds,
        encodeNanoseconds: encodeDuration
      )
    } catch {
      writeDiagnostic("encode output failed: \(error.localizedDescription)")
    }
  }

  private func encodingCompleted() {
    encoding = false
    guard let next = pendingFrame else { return }
    pendingFrame = nil
    encode(next)
  }

  private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
      let first = attachments.first
    else { return false }
    return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
  }

  private func annexB(_ sampleBuffer: CMSampleBuffer, includeParameterSets: Bool) throws -> Data {
    var output = Data()
    let startCode: [UInt8] = [0, 0, 0, 1]
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      throw CaptureError.invalidFrame
    }
    var count = 0
    var headerLength: Int32 = 0
    let queryStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      format, parameterSetIndex: 0, parameterSetPointerOut: nil,
      parameterSetSizeOut: nil, parameterSetCountOut: &count,
      nalUnitHeaderLengthOut: &headerLength
    )
    guard queryStatus == noErr else { throw CaptureError.encoder(queryStatus) }
    guard (1...4).contains(headerLength) else { throw CaptureError.invalidFrame }
    if includeParameterSets {
      for index in 0..<count {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let parameterStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
          parameterSetSizeOut: &size, parameterSetCountOut: nil,
          nalUnitHeaderLengthOut: nil
        )
        guard parameterStatus == noErr, let pointer else {
          throw CaptureError.encoder(parameterStatus)
        }
        output.append(contentsOf: startCode)
        output.append(pointer, count: size)
      }
    }

    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw CaptureError.invalidFrame
    }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let dataStatus = CMBlockBufferGetDataPointer(
      block, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength, dataPointerOut: &dataPointer
    )
    guard dataStatus == kCMBlockBufferNoErr, let dataPointer else {
      throw CaptureError.encoder(dataStatus)
    }
    let bytes = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
    var offset = 0
    let lengthBytes = Int(headerLength)
    while offset + lengthBytes <= totalLength {
      var length = 0
      for index in 0..<lengthBytes { length = length << 8 | Int(bytes[offset + index]) }
      offset += lengthBytes
      guard length > 0, offset + length <= totalLength else { throw CaptureError.invalidFrame }
      output.append(contentsOf: startCode)
      output.append(bytes + offset, count: length)
      offset += length
    }
    guard offset == totalLength else { throw CaptureError.invalidFrame }
    return output
  }

  private func writeFrame(
    _ payload: Data,
    keyFrame: Bool,
    captureNanoseconds: Int64,
    encodeNanoseconds: UInt64
  ) {
    var header = Data()
    header.appendBigEndian(UInt32(payload.count))
    header.appendBigEndian(UInt32(keyFrame ? 1 : 0))
    header.appendBigEndian(frameDurationNanoseconds)
    header.appendBigEndian(UInt64(bitPattern: captureNanoseconds))
    header.appendBigEndian(encodeNanoseconds)
    outputQueue.sync {
      FileHandle.standardOutput.write(header)
      FileHandle.standardOutput.write(payload)
    }
  }

  private func startControlReader() {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      while let line = readLine() { self?.handleControl(line) }
      self?.stop()
    }
  }

  private func handleControl(_ line: String) {
    guard let data = line.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    if let input = value["input"] as? [String: Any] {
      DispatchQueue.main.async { [weak self] in self?.inputInjector?.handle(input) }
      return
    }
    stateQueue.async { [weak self] in
      guard let self else { return }
      if value["keyframe"] as? Bool == true { self.forceKeyFrame = true }
      if let bitrate = value["bitrate_kbps"] as? Int, let encoder = self.encoder,
        (100...100_000).contains(bitrate)
      {
        let status = VTSessionSetProperty(
          encoder, key: kVTCompressionPropertyKey_AverageBitRate,
          value: (bitrate * 1_000) as CFNumber
        )
        if status == noErr {
          _ = VTSessionSetProperty(
            encoder, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [bitrate * 125, 1] as CFArray
          )
        }
      }
    }
  }
}

extension Data {
  fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    var encoded = value.bigEndian
    Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
  }
}

private func writeDiagnostic(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main
private struct DieterCapture {
  static func main() async {
    do {
      if CommandLine.arguments.dropFirst().contains("--check-control") {
        guard CGPreflightPostEventAccess() else {
          throw NSError(domain: "DieterCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Accessibility event-posting permission is denied"])
        }
        return
      }
      if CommandLine.arguments.dropFirst().contains("--request-control") {
        guard CGRequestPostEventAccess() else {
          throw NSError(domain: "DieterCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Accessibility event-posting permission was not granted"])
        }
        return
      }
      let runner = CaptureRunner(options: try CaptureOptions.parse())
      try await runner.start()
      await Task.detached { runner.wait() }.value
    } catch {
      writeDiagnostic(error.localizedDescription)
      Foundation.exit(1)
    }
  }
}
