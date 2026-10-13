import DieterClientAPI
import SwiftUI

/// Settings › Devices: this device's trust, adding a device by the code it
/// shows, devices waiting to join, the account's devices with removal, recent
/// changes, and starting over. Everything shown comes from the devices slice.
struct DevicesSettings: View {
    @Environment(DieterStore.self) private var store
    @State private var pendingRemoval: ClientDeviceEntry?
    @State private var confirmingReset = false

    private var devices: DevicesModel { store.devicesModel }
    private var slice: ClientDevicesSlice { devices.slice }

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                status
                if slice.trust == .trusted { addDevice }
                if !slice.requests.isEmpty { waiting }
                if !slice.devices.isEmpty { deviceList }
                if !slice.notices.isEmpty { notices }
                reset
            }
        }
        .onAppear { devices.observe() }
        .onDisappear { devices.release() }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "device")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { device in
            Button("Remove device", role: .destructive) { Task { await devices.revoke(device.deviceID) } }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text(
                device.thisDevice
                    ? "This device can no longer reach your machines until it is reset and added again."
                    : "\(device.name) can no longer reach your machines. To use it again, add it with a new code.")
        }
        .confirmationDialog("Reset this device?", isPresented: $confirmingReset) {
            Button("Reset this device", role: .destructive) { Task { await devices.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DevicesText.resetConfirmation)
        }
    }

    private var status: some View {
        SettingsPanel(title: slice.title.isEmpty ? "This device" : slice.title) {
            if !slice.detail.isEmpty {
                Text(DevicesText.inline(slice.detail))
                    .font(.caption).foregroundStyle(DieterTheme.subtle).fixedSize(horizontal: false, vertical: true)
            }
            if slice.trust == .pending, !slice.pairingCode.isEmpty {
                Text(slice.pairingCode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced)).tracking(1.5)
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code \(slice.pairingCode)")
                    .e2eTarget("devices.pairing-code", text: slice.pairingCode)
            }
            HStack(spacing: 8) {
                if slice.loading || devices.working { ProgressView().controlSize(.small) }
                if let problem = devices.failure ?? (slice.error.isEmpty ? nil : slice.error) {
                    Text(problem).font(.caption).foregroundStyle(DieterTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await devices.refresh() } }
                    .buttonStyle(DieterBarButtonStyle(size: 26))
                    .disabled(devices.working)
            }
        }
    }

    private var addDevice: some View {
        SettingsPanel(
            title: "Add a device",
            subtitle:
                "Type the code your own new device shows. An approved device gets full access to your machines."
        ) {
            HStack {
                TextField(
                    "ABCD-EFGH-JKMN-PQRS",
                    text: Binding(get: { devices.code }, set: { devices.type($0) })
                )
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await devices.approve() } }
                .accessibilityIdentifier("devices.code")
                .e2eTarget("devices.code")
                Button("Add device") { Task { await devices.approve() } }
                    .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                    .disabled(!devices.canApprove)
                    .accessibilityIdentifier("devices.approve")
                    .e2eTarget("devices.approve")
            }
        }
    }

    private var waiting: some View {
        SettingsPanel(title: "Waiting to join", subtitle: "Add one by typing the code it shows.") {
            ForEach(slice.requests, id: \.requestID) { request in
                HStack(spacing: 10) {
                    Image(systemName: symbol(platform: request.platform, kind: request.kindLabel))
                        .foregroundStyle(DieterTheme.tertiary).frame(width: 18)
                    Text(request.name).font(.system(size: 12, weight: .semibold))
                    Text(request.kindLabel).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    Spacer()
                }
                .e2eTarget("devices.waiting", text: request.name)
                if request.requestID != slice.requests.last?.requestID { Divider().overlay(DieterTheme.border) }
            }
        }
    }

    private var deviceList: some View {
        SettingsPanel(title: "Trusted devices") {
            ForEach(slice.devices, id: \.deviceID) { device in
                DeviceRow(device: device) { pendingRemoval = device }
                    .e2eTarget(device.thisDevice ? "devices.this-device" : "devices.device", text: device.name)
                if device.deviceID != slice.devices.last?.deviceID { Divider().overlay(DieterTheme.border) }
            }
        }
        .e2eTarget("devices.list")
    }

    private var notices: some View {
        SettingsPanel(title: "Recent changes") {
            ForEach(slice.notices, id: \.sequence) { notice in
                Text(notice.text).font(.caption).foregroundStyle(DieterTheme.subtle)
            }
        }
    }

    private var reset: some View {
        SettingsPanel(
            title: "Start over",
            subtitle: "Forget your trusted devices and this device's key, then pair it again with a new code."
        ) {
            Button("Reset this device", role: .destructive) { confirmingReset = true }
                .buttonStyle(DieterBarButtonStyle(destructive: true, size: 28))
                .disabled(devices.working)
                .accessibilityIdentifier("devices.reset")
        }
    }

    private func symbol(platform: String, kind: String) -> String {
        DeviceRow.symbol(platform: platform, kind: kind)
    }
}

private struct DeviceRow: View {
    let device: ClientDeviceEntry
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(platform: device.platform, kind: device.kindLabel))
                .foregroundStyle(device.revoked ? DieterTheme.tertiary : DieterTheme.shell).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).font(.system(size: 12, weight: .semibold))
                        .strikethrough(device.revoked)
                    if device.thisDevice {
                        Text("THIS DEVICE").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.eyes)
                    }
                    if device.revoked {
                        Text("REMOVED").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.coral)
                    }
                }
                Text(detail).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            Spacer()
            if device.revocable {
                Button("Remove", role: .destructive, action: remove)
                    .buttonStyle(DieterBarButtonStyle(destructive: true, size: 24))
                    .accessibilityLabel("Remove \(device.name)")
            }
        }
        .padding(.vertical, 3)
        .foregroundStyle(device.revoked ? DieterTheme.tertiary : DieterTheme.text)
    }

    private var detail: String {
        var parts = [device.kindLabel]
        if !device.platform.isEmpty { parts.append(device.platform) }
        if !device.addedBy.isEmpty { parts.append("added by \(device.addedBy)") }
        return parts.joined(separator: " · ")
    }

    static func symbol(platform: String, kind: String) -> String {
        if kind == "Recovery key" { return "key" }
        switch platform {
        case "ios": return "iphone"
        case "android": return "candybarphone"
        case "macos": return kind == "Machine" ? "desktopcomputer" : "laptopcomputer"
        case "linux": return "server.rack"
        default: return kind == "Machine" ? "desktopcomputer" : "app.badge"
        }
    }
}
