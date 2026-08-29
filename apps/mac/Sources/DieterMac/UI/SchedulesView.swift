import DieterAPI
import SwiftUI

enum SchedulesPresentationState: Equatable {
    case loading
    case empty
    case loaded

    static func resolve(isLoaded: Bool, isLoading: Bool, hasSchedules: Bool) -> Self {
        if !isLoaded || (isLoading && !hasSchedules) { return .loading }
        return hasSchedules ? .loaded : .empty
    }
}

struct SchedulesView: View {
    @Environment(DieterStore.self) private var store
    @State private var editorPresentation: ScheduleEditorPresentation?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                FluidPaneChrome(background: DieterTheme.sidebar) {
                    HStack(spacing: 8) {
                        PaneTitleBlock(
                            title: "Schedules",
                            subtitle: store.schedulesAreLoaded
                                ? "\(store.schedules.count) automation\(store.schedules.count == 1 ? "" : "s")"
                                : "Loading automations…",
                            symbol: "calendar.badge.clock",
                            prominent: true
                        )
                        Button { Task { await store.loadSchedules() } } label: {
                            if store.schedulesLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(DieterIconButtonStyle())
                        .disabled(store.schedulesLoading)
                        Button { editorPresentation = ScheduleEditorPresentation(schedule: nil) } label: { Label("New", systemImage: "plus") }
                            .buttonStyle(DieterPrimaryButtonStyle()).accessibilityIdentifier("schedules.new")
                    }
                }
                switch SchedulesPresentationState.resolve(
                    isLoaded: store.schedulesAreLoaded,
                    isLoading: store.schedulesLoading,
                    hasSchedules: !store.schedules.isEmpty
                ) {
                case .loading:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading schedules…")
                            .font(DieterFont.meta)
                            .foregroundStyle(DieterTheme.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Loading schedules")
                    .accessibilityIdentifier("schedules.loading")
                case .empty:
                    ContentUnavailableView("No schedules", systemImage: "calendar.badge.plus", description: Text("Automate cards and chats with cron schedules."))
                        .accessibilityIdentifier("schedules.empty")
                case .loaded:
                    ScrollView {
                        LazyVStack(spacing: 7) {
                        ForEach(store.schedules, id: \.id) { schedule in
                            Button {
                                Task { await store.selectSchedule(schedule.id) }
                            } label: {
                                ScheduleRow(schedule: schedule, selected: store.selectedScheduleID == schedule.id)
                            }
                            .buttonStyle(.plain)
                        }
                        }
                        .padding(10)
                    }
                    .accessibilityIdentifier("schedules.list")
                }
            }.frame(minWidth: 280, idealWidth: 350, maxWidth: 440, maxHeight: .infinity, alignment: .top).background(DieterTheme.sidebar)

            if let schedule = store.selectedSchedule {
                ScheduleDetail(schedule: schedule, edit: { editorPresentation = ScheduleEditorPresentation(schedule: schedule) })
            } else {
                VStack(spacing: 0) {
                    FluidPaneChrome {
                        PaneTitleBlock(title: "Schedule details", subtitle: "Select an automation to inspect its timing and run history", symbol: "calendar.badge.clock")
                    }
                    ContentUnavailableView("Select a schedule", systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await store.loadSchedules() }
        .sheet(item: $editorPresentation) { presentation in
            ScheduleEditor(schedule: presentation.schedule).environment(store)
        }
    }
}

struct ScheduleEditorPresentation: Identifiable {
    let id = UUID()
    let schedule: Dieter_V1_Schedule?
}

struct ScheduleRow: View {
    let schedule: Dieter_V1_Schedule
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Circle().fill(schedule.enabled ? DieterTheme.eyes : DieterTheme.subtle).frame(width: 6, height: 6); Text(schedule.name).font(.system(size: 13, weight: .semibold)); Spacer(); if !schedule.enabled { Text("Paused").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary) } }
            Text(ScheduleTiming.summary(cron: schedule.cron, timezone: schedule.timezone))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.shell)
            HStack { Text(ScheduleActionPresentation.title(schedule.action)); Spacer(); Text(schedule.nextRunAt.isEmpty ? "No next run" : ScheduleDateFormatting.compact(schedule.nextRunAt, timezone: schedule.timezone)) }.font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? DieterTheme.selection : DieterTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous).stroke(selected ? .clear : DieterTheme.border))
        .contentShape(RoundedRectangle(cornerRadius: DieterMetrics.cardRadius))
    }
}

struct ScheduleDetail: View {
    @Environment(DieterStore.self) private var store
    let schedule: Dieter_V1_Schedule
    let edit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FluidPaneChrome(background: DieterTheme.sidebar, spacing: 8) {
                HStack(spacing: 10) {
                    PaneTitleBlock(
                        title: schedule.name,
                        subtitle: schedule.description_p.isEmpty ? "Scheduled \(schedule.action.replacingOccurrences(of: "_", with: " "))" : schedule.description_p,
                        symbol: "calendar.badge.clock"
                    )
                    Toggle("Enabled", isOn: Binding(get: { schedule.enabled }, set: { _ in Task { await store.toggleSchedule(schedule) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Button("Edit", action: edit).buttonStyle(DieterSecondaryButtonStyle())
                    Button("Run now") { Task { await store.runSchedule(schedule) } }.buttonStyle(DieterPrimaryButtonStyle())
                }
            } secondary: {
                HStack(spacing: 8) {
                    Text(schedule.cron).font(.system(size: 11, design: .monospaced))
                    Text("·")
                    Text(schedule.timezone)
                    Spacer()
                    StatusPill(text: schedule.enabled ? "Enabled" : "Paused", color: schedule.enabled ? DieterTheme.eyes : DieterTheme.subtle)
                }
                .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    ScheduleMetric(title: "Cron", value: schedule.cron, symbol: "clock")
                    ScheduleMetric(title: "Timezone", value: schedule.timezone, symbol: "globe")
                    ScheduleMetric(title: "Placement", value: ScheduleActionPresentation.title(schedule.action), symbol: "rectangle.stack")
                    ScheduleMetric(title: "Next run", value: schedule.nextRunAt.isEmpty ? "—" : ScheduleDateFormatting.compact(schedule.nextRunAt, timezone: schedule.timezone), symbol: "forward")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("TEMPLATES").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                    Text(schedule.titleTemplate).font(.system(size: 13, weight: .semibold))
                    Text(schedule.promptTemplate).font(.system(size: 12)).foregroundStyle(DieterTheme.subtle).textSelection(.enabled)
                    HStack { StatusPill(text: schedule.provider); StatusPill(text: schedule.model); StatusPill(text: schedule.effort) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14).dieterSurface(radius: 10)
                HStack { Text("Recent runs").font(.system(size: 13, weight: .semibold)); Spacer(); Button("Delete schedule", role: .destructive) { Task { await store.deleteSchedule(schedule) } } }
                if store.scheduleRunsLoading && store.scheduleRuns.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading occurrences…")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    if store.scheduleRuns.isEmpty { Text("No occurrences yet.").foregroundStyle(.secondary) }
                    ForEach(store.scheduleRuns, id: \.id) { run in
                        HStack { StatusPill(text: run.status, color: runtimeColor(run.status)); VStack(alignment: .leading) { Text(run.scheduledFor); if !run.message.isEmpty { Text(run.message).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Text(run.manual ? "Manual" : "Scheduled").font(.caption).foregroundStyle(.secondary); if !run.cardID.isEmpty { Button("Open card") { store.section = .board; Task { await store.openConversation(cardID: run.cardID) } } } }
                            .padding(10).dieterSurface(radius: 8)
                    }
                }
                }.padding(20)
            }
        }
    }
}

struct ScheduleMetric: View {
    let title: String, value: String, symbol: String
    var body: some View { VStack(alignment: .leading, spacing: 6) { Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary); Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(2) }.padding(12).frame(maxWidth: .infinity, alignment: .leading).dieterSurface(radius: 10) }
}

struct ScheduleEditor: View {
    @Environment(DieterStore.self) private var store
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

    init(schedule: Dieter_V1_Schedule?) {
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
        store.state.boards.filter { $0.projectID == store.selectedProjectID }
    }

    private var selectedBoard: Dieter_V1_Board? {
        projectBoards.first { $0.id == draft.boardID }
    }

    private var cron: String {
        ScheduleTiming.cron(cadence: cadence, time: runTime, weekday: weekday, custom: draft.cron)
    }

    private var previewKey: String { "\(cron)|\(draft.timezone)" }

    private var canSave: Bool {
        !saving && !draft.boardID.isEmpty && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !draft.workspaceMode.isEmpty &&
            !draft.titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !draft.promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.timezone.isEmpty
    }

    private var sampleVariables: [String: String] {
        ScheduleTemplateRenderer.variables(
            scheduledAt: preview.first,
            timezone: draft.timezone,
            project: store.selectedProject?.name ?? "Project",
            board: selectedBoard?.name ?? "Board",
            schedule: draft.name.ifBlank("Schedule")
        )
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                    .frame(width: 42, height: 42).background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 11))
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
                        ScheduleEditorSection(title: "Schedule", subtitle: "Name this automation so its runs are easy to identify", symbol: "text.badge.plus") {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Schedule name", text: $draft.name, prompt: Text("Morning project check"))
                                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("schedule-editor.name")
                                TextField("Description", text: $draft.description_p, prompt: Text("What this automation is responsible for"), axis: .vertical)
                                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                            }
                        }

                        ScheduleEditorSection(title: "Timing", subtitle: "Choose a recurring pattern or enter cron only when needed", symbol: "clock") {
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
                                        Text("CRON EXPRESSION").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
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
                                        ForEach(ScheduleTiming.timezoneOptions(including: draft.timezone), id: \.self) { Text($0).tag($0) }
                                    }
                                    .labelsHidden().frame(maxWidth: 230)
                                }

                                Divider().overlay(DieterTheme.border)
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(ScheduleTiming.summary(cron: cron, timezone: draft.timezone)).font(.system(size: 12, weight: .semibold))
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
                                        Text("NEXT RUNS").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
                                        ForEach(preview.prefix(5), id: \.self) { value in
                                            HStack(spacing: 7) {
                                                Image(systemName: "arrow.forward.circle.fill").foregroundStyle(DieterTheme.shell)
                                                Text(ScheduleDateFormatting.full(value, timezone: draft.timezone))
                                            }.font(.system(size: 11, weight: .medium))
                                        }
                                    }
                                }
                            }
                        }

                        ScheduleEditorSection(title: "Destination", subtitle: "Choose the board and whether work waits in Todo or starts immediately", symbol: "rectangle.stack") {
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
                                .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("schedule-editor.placement")
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
                                                if selectedLabelIDs.contains(label.id) { selectedLabelIDs.remove(label.id) }
                                                else { selectedLabelIDs.insert(label.id) }
                                            }
                                            .buttonStyle(.bordered).controlSize(.small)
                                            .tint(selectedLabelIDs.contains(label.id) ? DieterTheme.shell : DieterTheme.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 390)

                    VStack(spacing: 18) {
                        ScheduleEditorSection(title: "Card templates", subtitle: "Variables are rendered by the daemon for every occurrence", symbol: "curlybraces") {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("CARD TITLE").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
                                    TextField("Daily update · {{date}}", text: $draft.titleTemplate)
                                        .textFieldStyle(.roundedBorder).focused($templateField, equals: .title)
                                        .accessibilityIdentifier("schedule-editor.title-template")
                                    TemplateVariableButtons { variable in insert(variable, into: .title) }
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("AGENT TASK").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
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
                                    Text("EXAMPLE OUTPUT").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
                                    Text(ScheduleTemplateRenderer.render(draft.titleTemplate, variables: sampleVariables).ifBlank("Card title preview"))
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(ScheduleTemplateRenderer.render(draft.promptTemplate, variables: sampleVariables).ifBlank("Agent task preview"))
                                        .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle).lineLimit(5)
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 9))
                            }
                        }

                        ScheduleEditorSection(title: "Agent", subtitle: "Choose the harness saved on every card this schedule creates", symbol: "cpu") {
                            HarnessFields(provider: $draft.provider, model: $draft.model, effort: $draft.effort, providerOptions: $draft.providerOptions)
                        }

                        ScheduleEditorSection(title: "Delivery & safety", subtitle: "Control duplicate work and project admission", symbol: "checkmark.shield") {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker("When a prior scheduled card is still open", selection: $draft.openCardPolicy) {
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
            draft.projectID = store.selectedProjectID
            if !projectBoards.contains(where: { $0.id == draft.boardID }) {
                draft.boardID = projectBoards.first(where: { $0.id == store.selectedBoardID })?.id ?? projectBoards.first?.id ?? ""
            }
            if draft.provider.isEmpty, let harness = store.harnessCatalog.harnesses.first {
                draft.provider = harness.id
                draft.model = harness.defaultModel
                draft.effort = harness.models.first(where: { $0.id == harness.defaultModel })?.defaultEffort ?? ""
                draft.providerOptions = ProviderOptionValues.defaults(for: harness)
            }
        }
        .task(id: previewKey) {
            guard await ScheduleEditorPreviewDebounce.wait() else { return }
            await previewRuns()
        }
    }

    private func previewRuns() async {
        guard let rpc = store.rpc, !cron.isEmpty, !draft.timezone.isEmpty else { return }
        var request = Dieter_V1_PreviewScheduleRequest(); request.cron = cron; request.timezone = draft.timezone; request.count = 5
        do {
            preview = try await rpc.previewSchedule(request).times
            previewError = ""
        } catch {
            preview = []
            previewError = error.localizedDescription
        }
    }

    private func insert(_ variable: String, into field: TemplateField) {
        let token = "{{\(variable)}}"
        switch field {
        case .title: draft.titleTemplate = ScheduleTemplateRenderer.appending(token, to: draft.titleTemplate)
        case .prompt: draft.promptTemplate = ScheduleTemplateRenderer.appending(token, to: draft.promptTemplate)
        }
        templateField = field
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        draft.projectID = store.selectedProjectID
        draft.cron = cron
        draft.labelIds = Array(selectedLabelIDs).sorted()
        draft.misfirePolicy = "latest"
        let saved = await store.saveSchedule(id: schedule?.id, draft: draft)
        saving = false
        if saved { dismiss() }
    }
}

enum ScheduleEditorPreviewDebounce {
    static func wait() async -> Bool {
        do {
            try await DieterTaskSleep.milliseconds(300)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

enum ScheduleEditorDraft {
    static func make(from schedule: Dieter_V1_Schedule?) -> Dieter_V1_ScheduleDraft {
        var draft = Dieter_V1_ScheduleDraft()
        draft.projectID = schedule?.projectID ?? ""
        draft.boardID = schedule?.boardID ?? ""
        draft.name = schedule?.name ?? ""
        draft.description_p = schedule?.description_p ?? ""
        draft.cron = schedule?.cron ?? "0 9 * * 1-5"
        draft.timezone = schedule?.timezone ?? TimeZone.current.identifier
        draft.enabled = schedule?.enabled ?? true
        draft.action = schedule?.action == "run" ? "run" : "draft"
        draft.titleTemplate = schedule?.titleTemplate ?? "Scheduled work · {{date}}"
        draft.promptTemplate = schedule?.promptTemplate ?? ""
        draft.provider = schedule?.provider ?? ""
        draft.model = schedule?.model ?? ""
        draft.effort = schedule?.effort ?? ""
        draft.labelIds = schedule?.labelIds ?? []
        draft.openCardPolicy = schedule?.openCardPolicy == "always" ? "always" : "skip_if_open"
        if let misfirePolicy = schedule?.misfirePolicy, !misfirePolicy.isEmpty {
            draft.misfirePolicy = misfirePolicy
        } else {
            draft.misfirePolicy = "latest"
        }
        draft.busyPolicy = schedule?.busyPolicy == "skip" ? "skip" : "queue"
        draft.providerOptions = schedule?.providerOptions ?? [:]
        draft.workspaceMode = schedule.map { ConversationWorkspaceMode.selectable($0.workspaceMode).rawValue } ?? "worktree"
        return draft
    }
}

private struct ScheduleEditorSection<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(DieterTheme.shell).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.caption).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading).dieterSurface(radius: 12)
    }
}

private struct TemplateVariableButtons: View {
    let insert: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(ScheduleTemplateRenderer.variableNames, id: \.self) { variable in
                Button("{{\(variable)}}") { insert(variable) }
                    .buttonStyle(.bordered).controlSize(.mini).font(.system(size: 10, design: .monospaced))
                    .help(ScheduleTemplateRenderer.variableHelp[variable, default: variable])
            }
        }
    }
}

enum ScheduleCadence: String, CaseIterable, Identifiable {
    case weekdays, daily, weekly, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ScheduleActionPresentation {
    static func title(_ action: String) -> String { action == "run" ? "Running" : "Todo" }
}

struct ScheduleWeekday: Identifiable {
    let value: Int
    let short: String
    let full: String
    var id: Int { value }
}

enum ScheduleTiming {
    static let weekdays: [ScheduleWeekday] = [
        .init(value: 1, short: "Mon", full: "Monday"), .init(value: 2, short: "Tue", full: "Tuesday"),
        .init(value: 3, short: "Wed", full: "Wednesday"), .init(value: 4, short: "Thu", full: "Thursday"),
        .init(value: 5, short: "Fri", full: "Friday"), .init(value: 6, short: "Sat", full: "Saturday"),
        .init(value: 0, short: "Sun", full: "Sunday"),
    ]

    static func parse(_ cron: String) -> (cadence: ScheduleCadence, time: Date, weekday: Int) {
        let parts = cron.split(whereSeparator: \Character.isWhitespace).map(String.init)
        let minute = Int(parts[safe: 0] ?? "")
        let hour = Int(parts[safe: 1] ?? "")
        let ordinaryDayAndMonth = parts[safe: 2] == "*" && parts[safe: 3] == "*"
        let dayOfWeek = parts[safe: 4]
        let cadence: ScheduleCadence
        let weekday: Int
        if minute != nil, hour != nil, ordinaryDayAndMonth, dayOfWeek == "1-5" {
            cadence = .weekdays; weekday = 1
        } else if minute != nil, hour != nil, ordinaryDayAndMonth, dayOfWeek == "*" {
            cadence = .daily; weekday = 1
        } else if let value = Int(dayOfWeek ?? ""), minute != nil, hour != nil, ordinaryDayAndMonth, 0...6 ~= value {
            cadence = .weekly; weekday = value
        } else {
            cadence = .custom; weekday = 1
        }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour ?? 9; components.minute = minute ?? 0; components.second = 0
        return (cadence, Calendar.current.date(from: components) ?? Date(), weekday)
    }

    static func cron(cadence: ScheduleCadence, time: Date, weekday: Int, custom: String) -> String {
        guard cadence != .custom else { return custom.trimmingCharacters(in: .whitespacesAndNewlines) }
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let day = switch cadence {
        case .weekdays: "1-5"
        case .daily: "*"
        case .weekly: String(weekday)
        case .custom: "*"
        }
        return "\(components.minute ?? 0) \(components.hour ?? 9) * * \(day)"
    }

    static func summary(cron: String, timezone: String) -> String {
        let parsed = parse(cron)
        guard parsed.cadence != .custom else { return "Custom schedule · \(timezone)" }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: parsed.time)
        let prefix = switch parsed.cadence {
        case .weekdays: "Weekdays"
        case .daily: "Every day"
        case .weekly: "Every \(weekdays.first { $0.value == parsed.weekday }?.full ?? "week")"
        case .custom: "Custom schedule"
        }
        return "\(prefix) at \(time) · \(timezone)"
    }

    static func timezoneOptions(including selected: String) -> [String] {
        let preferred = [TimeZone.current.identifier, "UTC", "Europe/Berlin", "Europe/London", "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "Asia/Tokyo", "Asia/Shanghai", "Asia/Kolkata", "Australia/Sydney"]
        return Array(Set([selected] + preferred).filter { !$0.isEmpty }).sorted { left, right in
            if left == TimeZone.current.identifier { return true }
            if right == TimeZone.current.identifier { return false }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }
}

enum ScheduleDateFormatting {
    static func compact(_ value: String, timezone: String) -> String {
        format(value, timezone: timezone, pattern: "EEE, MMM d · HH:mm")
    }

    static func full(_ value: String, timezone: String) -> String {
        format(value, timezone: timezone, pattern: "EEEE, MMM d 'at' HH:mm")
    }

    private static func format(_ value: String, timezone: String, pattern: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        let formatter = DateFormatter(); formatter.dateFormat = pattern
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        return formatter.string(from: date)
    }
}

enum ScheduleTemplateRenderer {
    static let variableNames = ["date", "scheduled_at", "project", "board", "schedule"]
    static let variableHelp = [
        "date": "Occurrence date in the schedule timezone",
        "scheduled_at": "Exact scheduled timestamp",
        "project": "Project name", "board": "Board name", "schedule": "Schedule name",
    ]

    static func render(_ template: String, variables: [String: String]) -> String {
        variables.reduce(template) { result, pair in result.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value) }
    }

    static func variables(scheduledAt: String?, timezone: String, project: String, board: String, schedule: String) -> [String: String] {
        let instant = scheduledAt.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyy-MM-dd"; dateFormatter.timeZone = TimeZone(identifier: timezone) ?? .current
        let exact = scheduledAt ?? ISO8601DateFormatter().string(from: instant)
        return ["date": dateFormatter.string(from: instant), "scheduled_at": exact, "project": project, "board": board, "schedule": schedule]
    }

    static func appending(_ token: String, to value: String) -> String {
        if value.isEmpty { return token }
        return value.last?.isWhitespace == true ? value + token : value + " " + token
    }
}

private extension String {
    func ifBlank(_ fallback: String) -> String { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
