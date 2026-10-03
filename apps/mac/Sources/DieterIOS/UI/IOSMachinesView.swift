#if os(iOS)
    import DieterAPI
    import SharedCore
    import SwiftUI

    /// The account's machines as the core lists and describes them. Choosing
    /// an available machine attaches the workspace feed to it; a compatible
    /// machine's gauge opens its live state.
    struct IOSMachinesView: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSAppModel.self) private var app
        /// The machine whose live state is pushed.
        @State private var stateMachineID: String?

        var body: some View {
            let machines = app.session.machines
            TimelineView(.periodic(from: .now, by: 30)) { clock in
                List {
                    ForEach(machines, id: \.id) { machine in
                        HStack(spacing: 8) {
                            IOSMachineRow(
                                machine: machine, status: app.machineStatus(machine, now: clock.date),
                                attached: machine.id == app.session.attachedMachineID
                            ) {
                                Task { await app.attachMachine(machine.id) }
                            }
                            if machine.compatible {
                                Button {
                                    stateMachineID = machine.id
                                } label: {
                                    Image(systemName: "gauge.with.dots.needle.67percent")
                                        .font(.title3)
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Machine state")
                                .accessibilityHint(machine.displayName)
                                .accessibilityIdentifier("ios.machines.state.\(machine.id)")
                            }
                        }
                    }
                }
            }
            .overlay {
                if machines.isEmpty {
                    ContentUnavailableView(
                        "No machines", systemImage: "desktopcomputer",
                        description: Text("Enroll a machine with the Dieter daemon to work with it here."))
                }
            }
            .navigationDestination(item: $stateMachineID) { machineID in
                IOSMachineStateView(machineID: machineID)
            }
            .navigationTitle("Machines")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("ios.machines")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("ios.machines.done")
                }
            }
        }
    }

    private struct IOSMachineRow: View {
        let machine: ClientMachineEntry
        let status: String
        let attached: Bool
        let attach: () -> Void

        var body: some View {
            Button(action: attach) {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.title3)
                        .foregroundStyle(machine.available ? Color.accentColor : .secondary)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(machine.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(machine.tone.color)
                                .frame(width: 7, height: 7)
                            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if attached {
                        Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Attached")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!machine.available)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(attached ? .isSelected : [])
            .accessibilityHint(machine.unavailableMessage)
            .accessibilityIdentifier("ios.machines.machine.\(machine.id)")
        }
    }
#endif
