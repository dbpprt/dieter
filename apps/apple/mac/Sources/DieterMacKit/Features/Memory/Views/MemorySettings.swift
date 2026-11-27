import DieterClientAPI
import SwiftUI

/// Settings › Agent memory: the account's one memory setting, which decides
/// whether and how dreams keep projects' saved memories tidy. Projects turn
/// memory on in their own settings. The core words and checks it; the
/// pickers show the catalog of the machine the form reads and saves on.
struct MemorySettings: View {
    @Environment(DieterStore.self) private var store

    /// The machine the form edits, as the core picks it from the session's machines.
    private var machine: String? {
        MemoryRules.machine(store.machines.compactMap { store.machineEntry($0) })
    }

    var body: some View {
        SettingsPage { MemorySettingsForm(machine: machine) }
            .accessibilityIdentifier("memory-settings")
            .e2eTarget("memory-settings")
            .task(id: machine) { await store.memoryModel.load(daemonID: machine) }
            // The dreaming agent's account picker judges the account's provider accounts.
            .onAppear { store.providersModel.observe() }
            .onDisappear { store.providersModel.release() }
    }
}

/// The page's panels: dreaming, the dreamer, how changes apply, the
/// schedule, the limits, extra instructions, and Save.
struct MemorySettingsForm: View {
    @Environment(DieterStore.self) private var store
    let machine: String?
    @State private var controls = MemoryControlsMemo()

    private var model: MemoryModel { store.memoryModel }
    private var entries: [ClientMachineEntry] { store.machines.compactMap { store.machineEntry($0) } }

    var body: some View {
        VStack(spacing: 14) {
            Text(
                "Turn memory on for a project in its settings. Dreams keep its saved memories tidy: an agent "
                    + "merges duplicates, retires outdated ones and adds what recent conversations settled. "
                    + "One setting for all your machines."
            )
            .font(.caption).foregroundStyle(DieterTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let problem = model.problem {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(problem)
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await model.load(daemonID: machine) } }
                        .buttonStyle(DieterBarButtonStyle(size: 24))
                        .disabled(model.loading)
                }
                .accessibilityIdentifier("memory-error")
                .e2eTarget("memory-error", text: problem)
            }
            if let draft = model.draft {
                form(draft)
            } else if model.problem == nil {
                SettingsPanel(title: "Dreams", subtitle: "Reading the memory setting…") {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func form(_ draft: MemoryDraft) -> some View {
        let catalog = store.harnessCatalog(forDaemon: model.daemonID ?? "")
        let providers = store.providersModel.slice
        SettingsPanel(title: "Dreams", subtitle: "On the schedule below; you can always start one from a project.") {
            // The E2E target covers the switch only: a click on the label
            // would not toggle it.
            LabeledContent("Dream automatically") {
                Toggle("Dream automatically", isOn: field(\.dreaming))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("memory-dreaming")
                    .e2eTarget("memory-dreaming")
            }
        }
        SettingsPanel(title: "Dreamer", subtitle: draft.status(catalog: catalog)) {
            if catalog.harnesses.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading agents…").font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
            } else {
                AgentPickerFields(
                    controls: controls.controls(draft, catalog: catalog, providers: providers),
                    offersDefaultAccount: true
                ) { choice in
                    guard let current = model.draft else { return }
                    model.draft = current.choosing(choice, catalog: catalog, providers: providers)
                }
                .frame(maxWidth: 380, alignment: .leading)
                .accessibilityIdentifier("memory-agent")
            }
            Picker("Run on", selection: field(\.runOn)) {
                ForEach(MemoryRules.runOnIDs(entries, runOn: draft.runOn), id: \.self) { id in
                    Text(MemoryRules.runOnTitle(entries, runOn: id)).tag(id)
                }
            }
            .frame(maxWidth: 380, alignment: .leading)
            .accessibilityIdentifier("memory-run-on")
            Text(
                [MemoryRules.runOnDetail(draft.runOn), draft.configured ? "" : MemoryRules.defaultsLabel]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            )
            .font(.caption).foregroundStyle(DieterTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        SettingsPanel(title: "Changes") {
            DieterSegmentedPicker(title: "Changes", selection: apply(draft), options: MemoryRules.applyModes) {
                Text(MemoryRules.applyTitle($0)).e2eTarget("memory-apply-\($0)")
            }
            .fixedSize()
            .accessibilityIdentifier("memory-apply")
            Text(MemoryRules.applyDetail(draft.apply))
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SettingsPanel(title: "Schedule") {
            limit("Hours between dreams", value: draft.minHours, range: MemoryRules.hours, identifier: "memory-hours") {
                $0.minHours = $1
            }
            Divider().overlay(DieterTheme.border)
            limit(
                "Finished conversations", value: draft.minNewTasks, range: MemoryRules.newTasks,
                identifier: "memory-tasks"
            ) { $0.minNewTasks = $1 }
            Divider().overlay(DieterTheme.border)
            HStack {
                Text("Start window")
                Spacer()
                TextField("Start window", text: field(\.window), prompt: Text("Any time"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .accessibilityIdentifier("memory-window")
                    .e2eTarget("memory-window")
            }
            .font(.system(size: 12))
            if let problem = MemoryRules.windowProblem(draft.window) {
                Text(problem).font(.caption).foregroundStyle(DieterTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Local time on the dreaming machine, e.g. \(MemoryRules.defaultWindow). Empty: any time.")
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
            }
        }
        SettingsPanel(title: "Limits") {
            limit(
                "Changes per dream", value: draft.maxOperations, range: MemoryRules.operations,
                identifier: "memory-changes"
            ) { $0.maxOperations = $1 }
            Divider().overlay(DieterTheme.border)
            limit(
                "Retired at most (%)", value: draft.maxRetirePercent, range: MemoryRules.retirePercent,
                identifier: "memory-retire"
            ) { $0.maxRetirePercent = $1 }
            Text("Dieter refuses a dream that goes beyond them.")
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
        }
        SettingsPanel(title: "Extra instructions", subtitle: "Added to every dream.") {
            TextEditor(text: field(\.instructions))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(9)
                .frame(minHeight: 90)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                .overlay(alignment: .topLeading) {
                    if draft.instructions.isEmpty {
                        Text("What every dream should keep in mind")
                            .font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Extra instructions")
                .accessibilityIdentifier("memory-instructions")
                .e2eTarget("memory-instructions")
        }
        HStack(spacing: 10) {
            if let problem = model.draftProblem {
                Text(problem).font(.caption).foregroundStyle(DieterTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.showsSaved {
                Text("Saved").font(.caption).foregroundStyle(DieterTheme.tertiary)
                    .accessibilityIdentifier("memory-saved")
                    .e2eTarget("memory-saved")
            }
            Spacer(minLength: 8)
            if model.saving { ProgressView().controlSize(.small) }
            Button("Save") { Task { await model.save() } }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                .disabled(!model.canSave)
                .accessibilityIdentifier("memory-save")
                .e2eTarget("memory-save")
        }
    }

    /// A draft field, read from and written to the model's draft.
    private func field<Value>(_ path: WritableKeyPath<MemoryDraft, Value>) -> Binding<Value> where Value: Equatable {
        Binding(
            get: { model.draft?[keyPath: path] ?? MemoryDraft()[keyPath: path] },
            set: { model.draft?[keyPath: path] = $0 })
    }

    /// The draft's apply mode; an empty one shows as the first, the auto default.
    private func apply(_ draft: MemoryDraft) -> Binding<String> {
        Binding(
            get: { draft.apply.isEmpty ? MemoryRules.applyModes.first ?? "" : draft.apply },
            set: { model.draft?.apply = $0 })
    }

    /// A whole number within `range`, stepped down and up.
    private func limit(
        _ title: String, value: Int, range: ClosedRange<Int>, identifier: String,
        set: @escaping (inout MemoryDraft, Int) -> Void
    ) -> some View {
        let shown = min(max(value, range.lowerBound), range.upperBound)
        return Stepper(
            value: Binding(
                get: { shown },
                set: { next in
                    guard var draft = model.draft else { return }
                    set(&draft, next)
                    model.draft = draft
                }),
            in: range
        ) {
            HStack {
                Text(title)
                Spacer()
                Text("\(shown)").monospacedDigit().font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("\(identifier)-value")
            }
        }
        .font(.system(size: 12))
        .accessibilityIdentifier(identifier)
    }
}
