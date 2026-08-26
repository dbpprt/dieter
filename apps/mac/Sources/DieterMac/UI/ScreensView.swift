import AppKit
import DieterAPI
import SwiftUI
@preconcurrency import WebRTC

struct ScreensView: View {
  @Environment(DieterStore.self) private var store
  @State private var controller = RemoteDesktopController()
  @State private var selectedMachineID = ""

  private var selectedMachine: DieterEndpoint? {
    store.machines.first { $0.id == selectedMachineID }
  }

  var body: some View {
    VStack(spacing: 0) {
      FluidPaneChrome {
        HStack(spacing: 12) {
          PaneTitleBlock(
            title: "Screens",
            subtitle: subtitle,
            symbol: "rectangle.inset.filled.and.person.filled",
            prominent: true,
            annotation: "Experimental"
          )
          Spacer()
          Picker("Machine", selection: $selectedMachineID) {
            ForEach(store.machines) { machine in
              Text(machine.name).tag(machine.id)
            }
          }
          .labelsHidden()
          .frame(width: 190)
          .disabled(isSessionActive || store.machines.isEmpty)
          .accessibilityIdentifier("screens.machine")
          primaryAction
        }
      }

      Divider().overlay(DieterTheme.border)
      content
      Divider().overlay(DieterTheme.border)
      HStack(spacing: 8) {
        Circle().fill(statusColor).frame(width: 6, height: 6)
        Text(controller.phase.label)
        if !controller.routeLabel.isEmpty {
          Text("·")
          Text("\(controller.routeLabel) signaling")
        }
        Spacer()
        Label(
          controller.controlActive ? "Control active" : "View only",
          systemImage: controller.controlActive ? "cursorarrow.motionlines" : "eye"
        )
        if controller.controlActive {
          Text("·")
          Text("⌘⇧Esc releases input")
        } else if !controller.controlUnavailableReason.isEmpty {
          Text("·")
          Text(controller.controlUnavailableReason)
        }
        Text("·")
        Text("Peer-to-peer media")
      }
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(DieterTheme.tertiary)
      .padding(.horizontal, 12)
      .frame(height: 28)
      .background(DieterTheme.sidebar)
    }
    .background(DieterTheme.background)
    .onAppear {
      if selectedMachineID.isEmpty {
        selectedMachineID =
          store.endpoint.daemonID == nil ? (store.machines.first?.id ?? "") : store.endpoint.id
      }
    }
    .onChange(of: selectedMachineID) { _, _ in controller.disconnect() }
    .onDisappear { controller.disconnect() }
  }

  @ViewBuilder private var primaryAction: some View {
    switch controller.phase {
    case .streaming, .connecting, .reconnecting, .loading:
      Button("Disconnect") { controller.disconnect() }
        .buttonStyle(DieterSecondaryButtonStyle())
        .accessibilityIdentifier("screens.disconnect")
    case .disabled:
      Button("Enable & connect") { Task { await controller.enableAndConnect() } }
        .buttonStyle(DieterPrimaryButtonStyle())
        .accessibilityIdentifier("screens.enable")
    default:
      Button("Connect") {
        guard let selectedMachine else { return }
        Task { await controller.connect(store: store, machine: selectedMachine) }
      }
      .buttonStyle(DieterPrimaryButtonStyle())
      .disabled(selectedMachine?.online != true)
      .accessibilityIdentifier("screens.connect")
    }
  }

  @ViewBuilder private var content: some View {
    switch controller.phase {
    case .streaming, .connecting, .reconnecting:
      ZStack {
        Color.black
        RemoteDesktopVideoSurface(controller: controller)
          .padding(18)
        if controller.phase != .streaming {
          VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(controller.phase.label).font(.system(size: 12, weight: .semibold))
          }
          .padding(.horizontal, 18).padding(.vertical, 14)
          .background(
            .black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
          .foregroundStyle(.white)
        }
      }
      .accessibilityIdentifier("screens.video")
    case .loading:
      emptyState(
        title: "Checking \(selectedMachine?.name ?? "machine")",
        detail: "Dieter is checking capture permission and negotiating an authenticated route.",
        symbol: "ellipsis"
      ) { ProgressView().controlSize(.small) }
    case .disabled(let reason):
      emptyState(
        title: "Screen sharing is off",
        detail: reason.isEmpty ? "Enable remote desktop on this machine to continue." : reason,
        symbol: "rectangle.slash"
      ) { EmptyView() }
    case .failed(let message):
      emptyState(
        title: "Couldn’t connect",
        detail: message,
        symbol: "exclamationmark.triangle"
      ) { EmptyView() }
    case .idle:
      if let machine = selectedMachine {
        let detail =
          machine.online
          ? (machine.remoteDesktopReason.isEmpty
            ? "Connect for an authenticated remote session with \(machine.name)."
            : machine.remoteDesktopReason)
          : MachinePresenceText.lastSeen(machine.lastSeenAt)
        emptyState(
          title: machine.name, detail: detail, symbol: machine.online ? "display" : "wifi.slash"
        ) { EmptyView() }
      } else {
        emptyState(
          title: "No machine selected",
          detail: "Enroll an online Dieter machine to share its screen.", symbol: "display"
        ) { EmptyView() }
      }
    }
  }

  private func emptyState<Accessory: View>(
    title: String, detail: String, symbol: String, @ViewBuilder accessory: () -> Accessory
  ) -> some View {
    VStack(spacing: 13) {
      ZStack {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(DieterTheme.selection)
          .frame(width: 62, height: 62)
        Image(systemName: symbol)
          .font(.system(size: 23, weight: .semibold))
          .foregroundStyle(DieterTheme.shell)
      }
      Text(title).font(.system(size: 15, weight: .semibold))
      Text(detail)
        .font(.system(size: 12))
        .foregroundStyle(DieterTheme.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      accessory()
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var subtitle: String {
    guard let selectedMachine else { return "Remote desktop" }
    return "\(selectedMachine.name) · authenticated remote session"
  }

  private var isSessionActive: Bool {
    switch controller.phase {
    case .loading, .connecting, .streaming, .reconnecting: true
    default: false
    }
  }

  private var statusColor: Color {
    switch controller.phase {
    case .streaming: DieterTheme.eyes
    case .loading, .connecting, .reconnecting: DieterTheme.amber
    case .failed: DieterTheme.coral
    default: DieterTheme.tertiary
    }
  }
}

private struct RemoteDesktopVideoSurface: NSViewRepresentable {
  let controller: RemoteDesktopController

  func makeNSView(context: Context) -> RemoteDesktopInputView {
    RemoteDesktopInputView(renderer: controller.renderer, controller: controller)
  }
  func updateNSView(_ nsView: RemoteDesktopInputView, context: Context) {
    nsView.controller = controller
  }
}

@MainActor
final class RemoteDesktopInputView: NSView, @preconcurrency RTCVideoViewDelegate {
  let renderer: RTCMTLNSVideoView
  weak var controller: RemoteDesktopController?
  private var videoSize = CGSize(width: 16, height: 9)
  private var trackingAreaReference: NSTrackingArea?

  init(renderer: RTCMTLNSVideoView, controller: RemoteDesktopController) {
    self.renderer = renderer
    self.controller = controller
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    renderer.delegate = self
    addSubview(renderer)
  }

  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  override func layout() {
    super.layout()
    renderer.frame = bounds
  }

  override func updateTrackingAreas() {
    if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
    let area = NSTrackingArea(
      rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    trackingAreaReference = area
    super.updateTrackingAreas()
  }

  func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
    videoSize = size.width > 0 && size.height > 0 ? size : videoSize
  }

  override func mouseMoved(with event: NSEvent) { sendMove(event) }
  override func mouseDragged(with event: NSEvent) { sendMove(event) }
  override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
  override func otherMouseDragged(with event: NSEvent) { sendMove(event) }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    sendButton(.left, down: true, event: event)
  }
  override func mouseUp(with event: NSEvent) { sendButton(.left, down: false, event: event) }
  override func rightMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    sendButton(.right, down: true, event: event)
  }
  override func rightMouseUp(with event: NSEvent) { sendButton(.right, down: false, event: event) }
  override func otherMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    sendButton(button(event.buttonNumber), down: true, event: event)
  }
  override func otherMouseUp(with event: NSEvent) {
    sendButton(button(event.buttonNumber), down: false, event: event)
  }

  override func scrollWheel(with event: NSEvent) {
    controller?.sendScroll(
      deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
      precise: event.hasPreciseScrollingDeltas, modifiers: event.modifierFlags)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 && event.modifierFlags.contains([.command, .shift]) {
      controller?.releaseAllInput()
      window?.makeFirstResponder(nil)
      return
    }
    controller?.sendKey(
      code: event.keyCode, down: true, repeat: event.isARepeat,
      modifiers: event.modifierFlags)
  }
  override func keyUp(with event: NSEvent) {
    controller?.sendKey(
      code: event.keyCode, down: false, repeat: false, modifiers: event.modifierFlags)
  }
  override func flagsChanged(with event: NSEvent) {
    let down = modifierIsDown(keyCode: event.keyCode, flags: event.modifierFlags)
    controller?.sendKey(
      code: event.keyCode, down: down, repeat: false, modifiers: event.modifierFlags)
  }
  override func resignFirstResponder() -> Bool {
    controller?.releaseAllInput()
    return super.resignFirstResponder()
  }

  private func sendMove(_ event: NSEvent) {
    guard let point = normalizedPoint(event) else { return }
    controller?.sendPointerMove(x: point.x, y: point.y)
  }

  private func sendButton(
    _ button: Dieter_V1_RemoteDesktopPointerButton.Button, down: Bool, event: NSEvent
  ) {
    guard let point = normalizedPoint(event) else { return }
    controller?.sendPointerMove(x: point.x, y: point.y)
    controller?.sendPointerButton(
      button, down: down, clickCount: event.clickCount, x: point.x, y: point.y,
      modifiers: event.modifierFlags)
  }

  private func normalizedPoint(_ event: NSEvent) -> CGPoint? {
    let point = convert(event.locationInWindow, from: nil)
    return RemoteDesktopInputGeometry.normalized(point: point, bounds: bounds, videoSize: videoSize)
  }

  private func button(_ number: Int) -> Dieter_V1_RemoteDesktopPointerButton.Button {
    switch number {
    case 2: .middle
    case 3: .back
    case 4: .forward
    default: .middle
    }
  }

  private func modifierIsDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
    switch keyCode {
    case 54, 55: flags.contains(.command)
    case 56, 60: flags.contains(.shift)
    case 57: flags.contains(.capsLock)
    case 58, 61: flags.contains(.option)
    case 59, 62: flags.contains(.control)
    case 63: flags.contains(.function)
    default: false
    }
  }
}

enum RemoteDesktopInputGeometry {
  static func normalized(point: CGPoint, bounds: CGRect, videoSize: CGSize) -> CGPoint? {
    guard bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else {
      return nil
    }
    let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
    let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    let content = CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height)
    guard content.contains(point) else { return nil }
    return CGPoint(
      x: max(0, min(1, (point.x - content.minX) / content.width)),
      y: max(0, min(1, 1 - (point.y - content.minY) / content.height)))
  }
}
