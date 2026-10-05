#if os(iOS)
    import DieterAPI
    import SharedCore
    import SwiftUI

    /// The account's machines as the core lists and describes them, each with
    /// how current its part of the workspace is. Every machine is streamed at
    /// once; a compatible machine's row opens its live state.
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
                        IOSMachineRow(machine: machine, status: app.machineStatus(machine, now: clock.date)) {
                            stateMachineID = machine.id
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
        let openState: () -> Void

        var body: some View {
            Button(action: openState) {
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
                    Text(machine.syncLabel).font(.caption).foregroundStyle(.secondary)
                    if machine.compatible {
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!machine.compatible)
            .accessibilityElement(children: .combine)
            .accessibilityHint(machine.compatible ? "Shows its live state" : machine.unavailableMessage)
            .accessibilityIdentifier("ios.machines.machine.\(machine.id)")
        }
    }
#endif
