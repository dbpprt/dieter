import AppKit
import DieterClientAPI
import SwiftUI

/// What the window shows instead of machines while this device is not
/// trusted: the code to type on a trusted device, how to set up a first
/// machine, or how to start over after a removal or a conflict. The wording
/// comes from the core's devices slice.
struct PairingView: View {
    @Environment(DieterStore.self) private var store
    @State private var confirmingReset = false

    private var devices: DevicesModel { store.devicesModel }
    private var trust: ClientDeviceTrust { store.session.deviceTrust }
    /// The session knows the code first; the devices slice repeats it.
    private var code: String {
        devices.slice.pairingCode.isEmpty ? store.session.pairingCode : devices.slice.pairingCode
    }
    private var problem: String? {
        devices.failure ?? (devices.slice.error.isEmpty ? nil : devices.slice.error)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                DieterBrandIcon(size: 58)
                VStack(spacing: 7) {
                    Text(devices.slice.title).font(.title2.weight(.bold))
                    Text(DevicesText.inline(devices.slice.detail))
                        .font(.system(size: 13)).foregroundStyle(DieterTheme.subtle)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if trust == .pending, !code.isEmpty { pairingCode }
                if trust.needsReset {
                    Button("Reset this device", role: .destructive) { confirmingReset = true }
                        .buttonStyle(DieterBarButtonStyle(prominent: true, destructive: true, size: 30))
                        .disabled(devices.working)
                        .accessibilityIdentifier("pairing.reset")
                        .e2eTarget("pairing.reset")
                }
                if devices.slice.loading || devices.working { ProgressView().controlSize(.small) }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(DieterTheme.coral)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(30)
            .frame(maxWidth: 540)
            .dieterOverlayChrome(cornerRadius: 22)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DieterTheme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing.view")
        .e2eTarget("pairing.view")
        .onAppear { devices.observe() }
        .onDisappear { devices.release() }
        .confirmationDialog("Reset this device?", isPresented: $confirmingReset) {
            Button("Reset this device", role: .destructive) { Task { await devices.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DevicesText.resetConfirmation)
        }
    }

    private var pairingCode: some View {
        VStack(spacing: 11) {
            Text(code)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .tracking(2)
                .textSelection(.enabled)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .dieterInset(radius: 12)
                .accessibilityLabel("Pairing code \(code)")
                .accessibilityIdentifier("pairing.code")
                .e2eTarget("pairing.code", text: code)
            Button("Copy code", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
            .buttonStyle(DieterBarButtonStyle(size: 28))
            Text(DevicesText.inline("Or run `dieter device approve \(code)` on a machine you already trust."))
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

enum DevicesText {
    static let resetConfirmation =
        "This device forgets your trusted devices and its key, then shows a new code. Type it on a device you trust to use your machines again."

    /// The core's wording renders `code` spans in a monospaced font.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
