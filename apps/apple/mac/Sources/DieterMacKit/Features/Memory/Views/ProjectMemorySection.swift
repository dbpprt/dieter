import DieterClientAPI
import SwiftUI

/// A project's agent memory in its settings: the switch, and while memory is
/// on, its state as the machine that dreams for it reports it and a dream
/// started now, which opens as the conversation it is.
struct ProjectMemorySection: View {
    let projectID: String
    /// The project has memory on, as last saved.
    let enabled: Bool
    @Binding var draft: Bool
    let openDream: (String) -> Void

    var body: some View {
        Section("Agent memory") {
            // The E2E target covers the switch only: a click on the row's
            // label would not toggle it.
            LabeledContent("Agent memory") {
                Toggle("Agent memory", isOn: $draft)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("project.memory")
                    .e2eTarget("project.memory")
            }
            Text("Agents recall what earlier conversations found and save what they learn.")
                .font(.caption).foregroundStyle(.secondary)
            if enabled {
                ProjectMemoryStatus(projectID: projectID, openDream: openDream)
            } else {
                Text("New conversations of the project use memory once it is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The project's memory as it stands and "Start a dream now".
struct ProjectMemoryStatus: View {
    @Environment(DieterStore.self) private var store
    let projectID: String
    let openDream: (String) -> Void

    private var model: MemoryModel { store.memoryModel }
    private var memory: ProjectMemory { model.projects[projectID] ?? ProjectMemory() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = memory.status {
                let entries = store.machines.compactMap { store.machineEntry($0) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.summary)
                    Text(status.dreams(now: Date(), machines: entries))
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("project.memory.status")
                .e2eTarget("project.memory.status", text: status.summary)
            } else if memory.problem == nil {
                ProgressView().controlSize(.small)
            }
            if let problem = memory.problem {
                Text(problem).font(.caption).foregroundStyle(DieterTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("project.memory.error")
            }
            if let dream = memory.started, !dream.error.isEmpty {
                Text("\(dream.title): \(dream.error)").font(.caption).foregroundStyle(DieterTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Start a dream now", systemImage: "moon") {
                    Task { await model.startDream(projectID) }
                }
                .buttonStyle(DieterBarButtonStyle(size: 26))
                .disabled(memory.starting)
                .accessibilityIdentifier("project.memory.dream")
                .e2eTarget("project.memory.dream")
                if let dream = memory.started, !dream.cardID.isEmpty {
                    Button("Open the dream") { openDream(dream.cardID) }
                        .buttonStyle(DieterBarButtonStyle(size: 26))
                        .accessibilityIdentifier("project.memory.open-dream")
                        .e2eTarget("project.memory.open-dream")
                }
                if memory.starting { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: projectID) { await model.loadProject(projectID) }
    }
}
