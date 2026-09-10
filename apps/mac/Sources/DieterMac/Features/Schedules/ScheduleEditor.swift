import DieterAPI
import SwiftUI

struct ScheduleEditor: View {
    @Bindable var model: SchedulesModel
    let context: ScheduleEditorContext
    @Environment(\.dismiss) private var dismiss
    let schedule: Dieter_V1_Schedule?
    @State private var draft: Dieter_V1_ScheduleDraft
    @State private var preview: [String] = []
    @State private var previewError = ""
    @State private var cadence: ScheduleCadence
    @State private var runTime: Date
    @State private var weekday: Int
    @State private var selectedLabelIDs: Set<String>
    @State private var saving = false
    @FocusState private var templateField: TemplateField?

    private enum TemplateField { case title, prompt }

    init(model: SchedulesModel, context: ScheduleEditorContext, schedule: Dieter_V1_Schedule?) {
        self.model = model
        self.context = context
        self.schedule = schedule
        let draft = ScheduleEditorDraft.make(from: schedule)
        let timing = ScheduleTiming.parse(draft.cron)
        _draft = State(initialValue: draft)
        _cadence = State(initialValue: timing.cadence)
        _runTime = State(initialValue: timing.time)
        _weekday = State(initialValue: timing.weekday)
        _selectedLabelIDs = State(initialValue: Set(schedule?.labelIds ?? []))
    }

    private var projectBoards: [Dieter_V1_Board] {
        context.boards
    }

    private var selectedBoard: Dieter_V1_Board? {
        projectBoards.first { $0.id == draft.boardID }
    }

    private var cron: String {
        ScheduleTiming.cron(cadence: cadence, time: runTime, weekday: weekday, custom: draft.cron)
    }

    private var previewKey: String { "\(cron)|\(draft.timezone)" }

    private var canSave: Bool {
        !saving && !draft.boardID.isEmpty
            && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.workspaceMode.isEmpty
            && !draft.titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.timezone.isEmpty
    }

    private var sampleVariables: [String: String] {
        ScheduleTemplateRenderer.variables(
            scheduledAt: preview.first,
            timezone: draft.timezone,
            project: context.projectName,
            board: selectedBoard?.name ?? "Board",
            schedule: draft.name.ifBlank("Schedule")
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                    .frame(width: 42, height: 42).background(
                        DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(schedule == nil ? "NEW AUTOMATION" : "EDIT AUTOMATION")
                        .font(DieterFont.sectionLabel).tracking(1.2).foregroundStyle(DieterTheme.tertiary)
                    Text(schedule == nil ? "Create schedule" : draft.name.ifBlank("Edit schedule"))
                        .font(.system(size: 21, weight: .bold))
                    Text("Runs on the project daemon · all times use \(draft.timezone)")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Toggle("Enabled", isOn: $draft.enabled).toggleStyle(.switch).controlSize(.small)
                Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                Button(saving ? "Saving…" : "Save schedule") { Task { await save() } }
                    .buttonStyle(DieterPrimaryButtonStyle()).disabled(!canSave)
                    .accessibilityIdentifier("schedule-editor.save")
            }
            .padding(.horizontal, 22).padding(.vertical, 17).background(DieterTheme.sidebar)

            Divider().overlay(DieterTheme.border)

            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        ScheduleEditorSection(
                            title: "Schedule", subtitle: "Name this automation so its runs are easy to identify",
                            symbol: "text.badge.plus"
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Schedule name", text: $draft.name, prompt: Text("Morning project check"))
                                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("schedule-editor.name")
                                TextField(
                                    "Description", text: $draft.description_p,
                                    prompt: Text("What this automation is responsible for"), axis: .vertical
                                )
                                .textFieldStyle(.roundedBorder).lineLimit(2...4)
                            }
                        }

                        ScheduleEditorSection(
                            title: "Timing",
                            subtitle: "Choose a recurring pattern or enter cron only when needed",
                            symbol: "clock"
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Repeats", selection: $cadence) {
                                    ForEach(ScheduleCadence.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented).labelsHidden()

                                if cadence == .weekly {
                                    Picker("Day", selection: $weekday) {
                                        ForEach(ScheduleTiming.weekdays) { Text($0.short).tag($0.value) }
                                    }
                                    .pickerStyle(.segmented).labelsHidden()
                                }

                                if cadence == .custom {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("CRON EXPRESSION").font(DieterFont.sectionLabel).foregroundStyle(
                                            DieterTheme.tertiary)
                                        TextField("0 9 * * 1-5", text: $draft.cron)
                                            .textFieldStyle(.roundedBorder).font(.body.monospaced())
                                            .accessibilityIdentifier("schedule-editor.cron")
                                        Text("Five fields: minute, hour, day of month, month, day of week.")
                                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                                    }
                                } else {
                                    HStack {
                                        Text("Run at").font(.system(size: 12, weight: .semibold))
                                        Spacer()
                                        DatePicker("Run at", selection: $runTime, displayedComponents: .hourAndMinute)
                                            .labelsHidden().datePickerStyle(.field)
                                            .accessibilityIdentifier("schedule-editor.time")
                                    }
                                }

                                HStack {
                                    Text("Timezone").font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Picker("Timezone", selection: $draft.timezone) {
                                        ForEach(ScheduleTiming.timezoneOptions(including: draft.timezone), id: \.self) {
                                            Text($0).tag($0)
                                        }
                                    }
                                    .labelsHidden().frame(maxWidth: 230)
                                }

                                Divider().overlay(DieterTheme.border)
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(ScheduleTiming.summary(cron: cron, timezone: draft.timezone)).font(
                                            .system(size: 12, weight: .semibold))
                                        Text(cron).font(.caption.monospaced()).foregroundStyle(DieterTheme.tertiary)
                                    }
                                    Spacer()
                                    if preview.isEmpty { ProgressView().controlSize(.small) }
                                }
                                if !previewError.isEmpty {
                                    Label(previewError, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(DieterTheme.coral)
                                } else {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("NEXT RUNS").font(DieterFont.sectionLabel).foregroundStyle(
                                            DieterTheme.tertiary)
                                        ForEach(preview.prefix(5), id: \.self) { value in
                                            HStack(spacing: 7) {
                                                Image(systemName: "arrow.forward.circle.fill").foregroundStyle(
                                                    DieterTheme.shell)
                                                Text(ScheduleDateFormatting.full(value, timezone: draft.timezone))
                                            }.font(.system(size: 11, weight: .medium))
                                        }
                                    }
                                }
                            }
                        }

                        ScheduleEditorSection(
                            title: "Destination",
                            subtitle: "Choose the board and whether work waits in Todo or starts immediately",
                            symbol: "rectangle.stack"
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Board", selection: $draft.boardID) {
                                    ForEach(projectBoards, id: \.id) { Text($0.name).tag($0.id) }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: draft.boardID) { _, _ in
                                    selectedLabelIDs.formIntersection(Set(selectedBoard?.labels.map(\.id) ?? []))
                                }
                                Picker("Placement", selection: $draft.action) {
                                    Text("Todo").tag("draft")
                                    Text("Running").tag("run")
                                }
                                .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier(
                                    "schedule-editor.placement")
                                Picker("Workspace", selection: $draft.workspaceMode) {
                                    Text("New worktree").tag("worktree")
                                    Text("Project directory").tag("project")
                                }
                                .pickerStyle(.segmented)
                                .accessibilityIdentifier("schedule-editor.workspace")
                                Label(
                                    draft.action == "run"
                                        ? "Creates the card and asks the daemon to start its agent turn. If the project is busy, it follows the policy below."
                                        : "Creates a draft card in Todo. Its agent will not start until you start the card.",
                                    systemImage: draft.action == "run" ? "bolt.fill" : "tray.full.fill"
                                )
                                .font(.caption).foregroundStyle(DieterTheme.tertiary)

                                if let labels = selectedBoard?.labels, !labels.isEmpty {
                                    Text("LABELS").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
                                    HStack(spacing: 6) {
                                        ForEach(labels, id: \.id) { label in
                                            Button(label.name) {
                                                if selectedLabelIDs.contains(label.id) {
                                                    selectedLabelIDs.remove(label.id)
                                                } else {
                                                    selectedLabelIDs.insert(label.id)
                                                }
                                            }
                                            .buttonStyle(.bordered).controlSize(.small)
                                            .tint(
                                                selectedLabelIDs.contains(label.id)
                                                    ? DieterTheme.shell : DieterTheme.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 390)

                    VStack(spacing: 18) {
                        ScheduleEditorSection(
                            title: "Card templates",
                            subtitle: "Variables are rendered by the daemon for every occurrence",
                            symbol: "curlybraces"
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("CARD TITLE").font(DieterFont.sectionLabel).foregroundStyle(
                                        DieterTheme.tertiary)
                                    TextField("Daily update · {{date}}", text: $draft.titleTemplate)
                                        .textFieldStyle(.roundedBorder).focused($templateField, equals: .title)
                                        .accessibilityIdentifier("schedule-editor.title-template")
                                    TemplateVariableButtons { variable in insert(variable, into: .title) }
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("AGENT TASK").font(DieterFont.sectionLabel).foregroundStyle(
                                        DieterTheme.tertiary)
                                    ZStack(alignment: .topLeading) {
                                        TextEditor(text: $draft.promptTemplate)
                                            .font(.system(size: 12)).scrollContentBackground(.hidden)
                                            .padding(7).frame(minHeight: 155)
                                            .focused($templateField, equals: .prompt)
                                        if draft.promptTemplate.isEmpty {
                                            Text("Review {{project}} for {{date}} and summarize what needs attention.")
                                                .font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                                                .padding(.horizontal, 12).padding(.vertical, 15).allowsHitTesting(false)
                                        }
                                    }
                                    .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(DieterTheme.strongBorder))
                                    .accessibilityIdentifier("schedule-editor.prompt-template")
                                    TemplateVariableButtons { variable in insert(variable, into: .prompt) }
                                }

                                VStack(alignment: .leading, spacing: 7) {
                                    Text("EXAMPLE OUTPUT").font(DieterFont.sectionLabel).foregroundStyle(
                                        DieterTheme.tertiary)
                                    Text(
                                        ScheduleTemplateRenderer.render(draft.titleTemplate, variables: sampleVariables)
                                            .ifBlank("Card title preview")
                                    )
                                    .font(.system(size: 13, weight: .semibold))
                                    Text(
                                        ScheduleTemplateRenderer.render(
                                            draft.promptTemplate, variables: sampleVariables
                                        ).ifBlank("Agent task preview")
                                    )
                                    .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle).lineLimit(5)
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 9))
                            }
                        }

                        ScheduleEditorSection(
                            title: "Agent",
                            subtitle: "Choose the harness saved on every card this schedule creates",
                            symbol: "cpu"
                        ) {
                            HarnessFields(
                                catalog: context.harnessCatalog, provider: $draft.provider, model: $draft.model,
                                effort: $draft.effort, providerOptions: $draft.providerOptions)
                        }

                        ScheduleEditorSection(
                            title: "Delivery & safety", subtitle: "Control duplicate work and project admission",
                            symbol: "checkmark.shield"
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker(
                                    "When a prior scheduled card is still open", selection: $draft.openCardPolicy
                                ) {
                                    Text("Skip this occurrence").tag("skip_if_open")
                                    Text("Always create another card").tag("always")
                                }
                                Picker("When the project is busy", selection: $draft.busyPolicy) {
                                    Text("Queue until available").tag("queue")
                                    Text("Skip this occurrence").tag("skip")
                                }
                                Text("Missed occurrences are collapsed to the latest one after the daemon returns.")
                                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(22)
            }
        }
        .frame(minWidth: 920, idealWidth: 980, minHeight: 760, idealHeight: 820)
        .background(DieterTheme.background)
        .task {
            draft.projectID = context.target.projectID
            if !projectBoards.contains(where: { $0.id == draft.boardID }) {
                draft.boardID =
                    projectBoards.first(where: { $0.id == context.selectedBoardID })?.id ?? projectBoards
                    .first?.id
                    ?? ""
            }
            if draft.provider.isEmpty, let harness = context.harnessCatalog.harnesses.first {
                draft.provider = harness.id
                draft.model = harness.defaultModel
                draft.effort =
                    harness.models.first(where: { $0.id == harness.defaultModel })?.defaultEffort ?? ""
                draft.providerOptions = ProviderOptionValues.defaults(for: harness, model: draft.model)
            }
        }
        .task(id: previewKey) {
            guard await ScheduleEditorPreviewDebounce.wait() else { return }
            await previewRuns()
        }
    }

    private func previewRuns() async {
        guard !cron.isEmpty, !draft.timezone.isEmpty else { return }
        let key = previewKey
        guard context.target == model.target else { return }
        do {
            let result = try await model.previewSchedule(cron: cron, timezone: draft.timezone) ?? []
            guard !Task.isCancelled, key == previewKey, context.target == model.target else { return }
            preview = result
            previewError = ""
        } catch {
            guard !Task.isCancelled, key == previewKey, context.target == model.target else { return }
            preview = []
            previewError = error.localizedDescription
        }
    }

    private func insert(_ variable: String, into field: TemplateField) {
        let token = "{{\(variable)}}"
        switch field {
        case .title:
            draft.titleTemplate = ScheduleTemplateRenderer.appending(token, to: draft.titleTemplate)
        case .prompt:
            draft.promptTemplate = ScheduleTemplateRenderer.appending(token, to: draft.promptTemplate)
        }
        templateField = field
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        draft.projectID = context.target.projectID
        draft.cron = cron
        draft.labelIds = Array(selectedLabelIDs).sorted()
        draft.misfirePolicy = "latest"
        let saved = await model.saveSchedule(
            id: schedule?.id, draft: draft, expectedTarget: context.target)
        saving = false
        if saved {
            dismiss()
        } else {
            previewError =
                model.errorMessage ?? "This project is no longer connected. Close the editor and reconnect."
        }
    }
}
