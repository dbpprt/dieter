import SwiftUI

struct ConnectionOverlay: View {
    @Environment(DieterStore.self) private var store
    @State private var address = ""

    var body: some View {
        ZStack {
            Color.black.opacity(DieterTheme.usesTransparency ? 0.38 : 0.55).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 17) {
                    DieterBrandIcon(size: 62)
                    VStack(spacing: 6) {
                        Text("Connect Dieter").font(.title2.weight(.bold))
                        Text(
                            "Choose the gateway that knows your account. Dieter automatically combines projects and conversations from every enrolled machine."
                        )
                        .font(.system(size: 13)).foregroundStyle(DieterTheme.subtle)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        OnboardingConnectionConcept(
                            symbol: "point.3.connected.trianglepath.dotted", title: "Gateway",
                            detail: "Sign-in, machine discovery, encrypted relay")
                        Image(systemName: "arrow.right").foregroundStyle(DieterTheme.tertiary)
                        OnboardingConnectionConcept(
                            symbol: "desktopcomputer", title: "All machines",
                            detail: "One combined workspace with automatic routing")
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text("1  CHOOSE A GATEWAY").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(
                            DieterTheme.tertiary)
                        ForEach(store.gateways) { gateway in
                            Button {
                                Task { await store.chooseGateway(gateway) }
                            } label: {
                                OnboardingGatewayRow(
                                    gateway: gateway,
                                    active: gateway.credentialID == store.activeGateway.credentialID
                                )
                            }.buttonStyle(.plain)
                        }
                        Text(
                            "The primary gateway is the normal choice. Add another only for a separate self-hosted or organizational deployment; its session and machines are separate."
                        )
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary).fixedSize(
                            horizontal: false, vertical: true)
                    }

                    if store.phase == .authenticationRequired {
                        VStack(spacing: 8) {
                            Text("Sign in to \(store.activeGateway.name) to discover its enrolled machines.")
                                .font(.caption).foregroundStyle(DieterTheme.subtle)
                            Button("Sign in with GitHub") { Task { await store.signIn() } }
                                .buttonStyle(DieterBarButtonStyle(prominent: true))
                        }
                    }

                    if !store.machines.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("MACHINES INCLUDED THROUGH \(store.activeGateway.name.uppercased())")
                                .font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                            ForEach(store.machines) { machine in
                                OnboardingMachineRow(machine: machine)
                            }
                        }
                    }

                    DisclosureGroup("Use another gateway address") {
                        HStack {
                            TextField("https://dieter.example.com", text: $address).textFieldStyle(.roundedBorder)
                            Button("Save and discover") {
                                if let gateway = MachineEndpoint(address: address, name: "Custom gateway") {
                                    Task { await store.saveEndpoint(gateway) }
                                    address = ""
                                }
                            }
                            .buttonStyle(DieterBarButtonStyle(size: 28))
                            .disabled(MachineEndpoint(address: address, name: "") == nil)
                        }.padding(.top, 8)
                    }
                    .font(.caption)

                    if case .connecting = store.phase {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small); Text("Contacting \(store.activeGateway.name)…")
                        }
                        .font(.caption).foregroundStyle(DieterTheme.subtle)
                    }
                    if case let .failed(message) = store.phase {
                        Text(message).font(.caption).foregroundStyle(DieterTheme.coral).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            .frame(width: 570)
            .frame(maxHeight: 720)
            .dieterOverlayChrome(cornerRadius: 22)
        }
    }
}

private struct OnboardingConnectionConcept: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary).lineLimit(2)
            }
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .dieterInset(radius: 10)
    }
}

private struct OnboardingGatewayRow: View {
    let gateway: MachineEndpoint
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network").foregroundStyle(DieterTheme.shell).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(gateway.name).font(.system(size: 12, weight: .semibold))
                    if gateway.isPrimaryGateway {
                        Text("PRIMARY").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.eyes)
                    }
                }
                Text(gateway.address).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            Spacer()
            Image(systemName: active ? "checkmark.circle.fill" : "arrow.right")
                .foregroundStyle(active ? DieterTheme.running : DieterTheme.tertiary)
        }
        .padding(11).dieterTile(active ? .selected : .rest, radius: 10)
    }
}

private struct OnboardingMachineRow: View {
    @Environment(DieterStore.self) private var store
    let machine: MachineEndpoint

    private var detail: String { store.machineStatusLine(machine) }
    private var compatible: Bool { store.machineEntry(machine)?.compatible ?? true }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(machine.online ? DieterTheme.running : DieterTheme.tertiary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(machine.name).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            Spacer()
            Text(!compatible ? "Update daemon" : (machine.online ? "Included automatically" : "Offline"))
                .font(.caption2).foregroundStyle(storeColor)
        }
        .padding(11).dieterTile(radius: 10)
    }

    private var storeColor: Color {
        !compatible ? DieterTheme.coral : (machine.online ? DieterTheme.shell : DieterTheme.tertiary)
    }
}
