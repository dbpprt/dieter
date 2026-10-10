import DieterAPI
import DieterShared
import SwiftUI

struct ScheduleEditor: View {
    @Bindable var model: SchedulesModel
    let context: ScheduleEditorContext
    @Environment(\.dismiss) private var dismiss
    /// The schedule being edited; nil creates one.
    let scheduleID: String?
    @State private var draft: Dieter_V1_ScheduleDraft
    @State private var cadence: ClientScheduleCadence
    @State private var timezones: [String]
    @State private var saveError = ""
    @State private var saving = false
    @FocusState private var templateField: TemplateField?

    private enum TemplateField { case title, prompt }
    private var options: ClientScheduleEditorOptions { .shared }

    /// Opens on `draft`, which the core prepared for the schedule or a new one.
    init(model: SchedulesModel, context: ScheduleEditorContext, scheduleID: String?, draft: Dieter_V1_ScheduleDraft) {
        self.model = model
        self.context = context
        self.scheduleID = scheduleID
        _draft = State(initialValue: draft)
        _cadence = State(
            initialValue: ClientScheduleCadence(rules: SharedRules.shared.scheduleCadence(cron: draft.cron)))
        _timezones = State(
            initialValue: SharedRules.shared.scheduleTimezones(
                selected: draft.timezone, device: TimeZone.current.identifier, all: TimeZone.knownTimeZoneIdentifiers))
    }

    private var projectBoards: [Dieter_V1_Board] {
        context.boards
    }

    private var selectedBoard: Dieter_V1_Board? {
        projectBoards.first { $0.id == draft.boardID }
    }

    private var title: String {
        guard scheduleID != nil else { return options.newTitle }
        return draft.name.isEmpty ? options.editTitle : draft.name
    }

    private var previewKey: String { "\(cadence.cron)|\(draft.timezone)" }
    private var preview: [String] { context.target.projectID == model.target.projectID ? model.schedulePreview : [] }
    private var previewError: String { saveError.isEmpty ? model.schedulePreviewError ?? "" : saveError }

    private var canSave: Bool {
        !saving
            && SharedRules.shared.scheduleCanSave(
                name: draft.name, titleTemplate: draft.titleTemplate, promptTemplate: draft.promptTemplate,
                cron: cadence.cron, timezone: draft.timezone, boardId: draft.boardID,
                workspaceMode: draft.workspaceMode)
    }

    /// The agent fields of the draft as one selection.
    private var agent: Binding<Dieter_V1_HarnessSelection> {
        Binding(
            get: {
                .with {
                    $0.provider = draft.provider
                    $0.model = draft.model
                    $0.effort = draft.effort
                    $0.providerOptions = draft.providerOptions
                }
            },
            set: {
                draft.provider = $0.provider
                draft.model = $0.model
                draft.effort = $0.effort
                draft.providerOptions = $0.providerOptions
            })
    }

    /// The run time as a date for the time picker.
    private var runTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: Int(cadence.hour), minute: Int(cadence.minute), second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let time = Calendar.current.dateComponents([.hour, .minute], from: date)
                update(hour: Int32(time.hour ?? 9), minute: Int32(time.minute ?? 0))
            })
    }

    private func example(_ template: String, empty: String) -> String {
        SharedRules.shared.scheduleTemplateExample(
            template: template, empty: empty,
            date: ScheduleDateFormatting.day(preview.first, timezone: draft.timezone),
            scheduledAt: preview.first ?? Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            project: context.projectName, board: selectedBoard?.name ?? "", schedule: draft.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                    .frame(width: 42, height: 42).dieterTile(radius: 11)
                VStack(alignment: .leading, spacing: 3) {
                    Text(scheduleID == nil ? "NEW AUTOMATION" : "EDIT AUTOMATION")
                        .font(DieterFont.sectionLabel).tracking(1.2).foregroundStyle(DieterTheme.tertiary)
                    Text(title)
                        .font(.system(size: 21, weight: .bold))
                    Text("Runs on the selected checkout’s machine · all times use \(draft.timezone)")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Toggle("Enabled", isOn: $draft.enabled).toggleStyle(.switch).controlSize(.small)
                Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle(size: 30))
                Button(saving ? "Saving…" : "Save schedule") { Task { await save() } }
                    .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30)).disabled(!canSave)
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
                            timing
                        }

                        ScheduleEditorSection(
                            title: "Destination",
                            subtitle: "Choose the board and whether work waits in Todo or starts immediately",
                            symbol: "rectangle.stack"
                        ) {
                            destination
                        }
                    }
                    .frame(maxWidth: 390)

                    VStack(spacing: 18) {
                        ScheduleEditorSection(
                            title: "Card templates",
                            subtitle: "Variables are rendered by the daemon for every occurrence",
                            symbol: "curlybraces"
                        ) {
                            templates
                        }

                        ScheduleEditorSection(
                            title: "Agent",
                            subtitle: "Choose the harness saved on every card this schedule creates",
                            symbol: "cpu"
                        ) {
                            AgentControlFields(catalog: context.harnessCatalog, selection: agent)
                        }

                        ScheduleEditorSection(
                            title: "Delivery & safety", subtitle: "Control duplicate work",
                            symbol: "checkmark.shield"
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker(
                                    "When a prior scheduled card is still open", selection: $draft.openCardPolicy
                                ) {
                                    ForEach(options.openPolicies, id: \.key) { Text($0.title).tag($0.key) }
                                }
                                Text(options.misfireNote)
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
        .onChange(of: previewKey, initial: true) {
            guard context.target.projectID == model.target.projectID else { return }
            model.previewSchedule(cron: cadence.cron, timezone: draft.timezone)
        }
        .onDisappear { model.closeEditor() }
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 12) {
            DieterSegmentedPicker(
                "Repeats", selection: Binding(get: { cadence.kind.rawValue }, set: { switchKind(to: $0) }),
                options: options.cadences.map { Int($0.key) ?? 0 }, fillsWidth: true,
                optionTitle: { kind in options.cadences.first { (Int($0.key) ?? 0) == kind }?.title ?? "" })

            if cadence.kind == .weekly {
                DieterSegmentedPicker(
                    "Day", selection: Binding(get: { cadence.weekday }, set: { update(weekday: $0) }),
                    options: options.weekdays.map { Int32($0.key) ?? 1 }, fillsWidth: true,
                    optionTitle: { day in options.weekdays.first { (Int32($0.key) ?? 1) == day }?.title ?? "" })
            }

            if cadence.kind == .custom {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CRON EXPRESSION").font(DieterFont.sectionLabel).foregroundStyle(
                        DieterTheme.tertiary)
                    TextField("0 9 * * 1-5", text: Binding(get: { cadence.custom }, set: { update(custom: $0) }))
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        .accessibilityIdentifier("schedule-editor.cron")
                    Text(options.cronHelp)
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
            } else {
                HStack {
                    Text("Run at").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    DatePicker("Run at", selection: runTime, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.field)
                        .accessibilityIdentifier("schedule-editor.time")
                }
            }

            HStack {
                Text("Timezone").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("Timezone", selection: $draft.timezone) {
                    ForEach(timezones, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 230)
            }

            Divider().overlay(DieterTheme.border)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(SharedRules.shared.scheduleTiming(cron: cadence.cron, timezone: draft.timezone))
                        .font(.system(size: 12, weight: .semibold))
                    Text(cadence.cron).font(.caption.monospaced()).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                if model.schedulePreviewLoading { ProgressView().controlSize(.small) }
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

    private var destination: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Board", selection: $draft.boardID) {
                ForEach(projectBoards, id: \.id) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
            .onChange(of: draft.boardID) { _, _ in
                let labels = Set(selectedBoard?.labels.map(\.id) ?? [])
                draft.labelIds.removeAll { !labels.contains($0) }
            }
            DieterSegmentedPicker(
                "Placement", selection: $draft.action, options: options.placements.map(\.key), fillsWidth: true,
                optionTitle: { action in options.placements.first { $0.key == action }?.title ?? action }
            )
            .accessibilityIdentifier("schedule-editor.placement")
            LabeledContent("Workspace") {
                DieterSegmentedPicker(
                    "Workspace", selection: $draft.workspaceMode, options: SharedRules.shared.workspaceModes(),
                    optionTitle: { SharedRules.shared.workspaceModeChoiceTitle(mode: $0) }
                )
                .accessibilityIdentifier("schedule-editor.workspace")
            }
            Toggle("Allow vault access", isOn: $draft.vaultAccess)
                .toggleStyle(.switch)
                .help("Cards this automation creates may use the account vault's passwords and TOTP codes.")
                .accessibilityIdentifier("schedule-editor.vault-access")
            Label(
                options.placements.first { $0.key == draft.action }?.detail ?? "",
                systemImage: draft.action == "run" ? "bolt.fill" : "tray.full.fill"
            )
            .font(.caption).foregroundStyle(DieterTheme.tertiary)

            if let labels = selectedBoard?.labels, !labels.isEmpty {
                Text("LABELS").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
                HStack(spacing: 6) {
                    ForEach(labels, id: \.id) { label in
                        Button(label.name) {
                            if draft.labelIds.contains(label.id) {
                                draft.labelIds.removeAll { $0 == label.id }
                            } else {
                                draft.labelIds.append(label.id)
                            }
                        }
                        .buttonStyle(
                            DieterBarButtonStyle(
                                prominent: draft.labelIds.contains(label.id), tint: DieterTheme.shell, size: 24))
                    }
                }
            }
        }
    }

    private var templates: some View {
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
                .dieterInset(radius: 7)
                .accessibilityIdentifier("schedule-editor.prompt-template")
                TemplateVariableButtons { variable in insert(variable, into: .prompt) }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("EXAMPLE OUTPUT").font(DieterFont.sectionLabel).foregroundStyle(
                    DieterTheme.tertiary)
                Text(example(draft.titleTemplate, empty: options.titlePlaceholder))
                    .font(.system(size: 13, weight: .semibold))
                Text(example(draft.promptTemplate, empty: options.promptPlaceholder))
                    .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle).lineLimit(5)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .dieterInset(radius: 9)
        }
    }

    private func update(
        hour: Int32? = nil, minute: Int32? = nil, weekday: Int32? = nil, custom: String? = nil
    ) {
        cadence = ClientScheduleCadence(
            rules: SharedRules.shared.scheduleCadenceOf(
                kind: Int32(cadence.kind.rawValue), hour: hour ?? cadence.hour, minute: minute ?? cadence.minute,
                weekday: weekday ?? cadence.weekday, custom: custom ?? cadence.custom))
    }

    private func switchKind(to kind: Int) {
        cadence = ClientScheduleCadence(
            rules: SharedRules.shared.scheduleCadenceSwitched(
                kind: Int32(cadence.kind.rawValue), hour: cadence.hour, minute: cadence.minute,
                weekday: cadence.weekday, custom: cadence.custom, toKind: Int32(kind)))
    }

    private func insert(_ variable: String, into field: TemplateField) {
        switch field {
        case .title:
            draft.titleTemplate = SharedRules.shared.scheduleInsertVariable(
                field: draft.titleTemplate, variable: variable)
        case .prompt:
            draft.promptTemplate = SharedRules.shared.scheduleInsertVariable(
                field: draft.promptTemplate, variable: variable)
        }
        templateField = field
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        draft.cron = cadence.cron
        let saved = await model.saveSchedule(id: scheduleID, draft: draft, expectedTarget: context.target)
        saving = false
        if saved {
            dismiss()
        } else {
            saveError = model.errorMessage ?? ""
        }
    }
}
