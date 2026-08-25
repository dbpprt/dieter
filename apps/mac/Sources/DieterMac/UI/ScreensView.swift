import AppKit
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
            prominent: true
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
        Label("View only", systemImage: "eye")
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
        RemoteDesktopVideoSurface(renderer: controller.renderer)
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
        detail: reason.isEmpty ? "Enable view-only sharing on this machine to continue." : reason,
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
            ? "Connect for an authenticated, view-only stream from \(machine.name)."
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
    guard let selectedMachine else { return "View-only remote desktop" }
    return "\(selectedMachine.name) · authenticated view-only session"
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
  let renderer: RTCMTLNSVideoView

  func makeNSView(context: Context) -> RTCMTLNSVideoView { renderer }
  func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {}
}
