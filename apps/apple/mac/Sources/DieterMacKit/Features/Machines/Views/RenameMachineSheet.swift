import SwiftUI

struct RenameMachineSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let machine: MachineEndpoint
    @State private var name = ""
    @State private var saving = false

    private var normalized: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename machine").font(.title2.weight(.bold))
            Text("This display name is stored on the gateway and appears on every signed-in client.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Machine name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle())
                Button("Rename") { save() }.buttonStyle(DieterBarButtonStyle(prominent: true))
                    .disabled(saving || normalized.isEmpty || normalized == machine.name)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { name = machine.name }
    }

    private func save() {
        guard !normalized.isEmpty else { return }
        saving = true
        Task {
            await store.renameMachine(machine, name: normalized)
            saving = false
            dismiss()
        }
    }
}
