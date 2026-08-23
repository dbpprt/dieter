import DieterAPI
import SwiftUI

struct SchedulesView: View {
    @Environment(DieterStore.self) private var store
    @State private var editorPresented = false
    @State private var editing: Dieter_V1_Schedule?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                FluidPaneChrome(background: DieterTheme.sidebar) {
                    HStack(spacing: 8) {
                        PaneTitleBlock(
                            title: "Schedules",
                            subtitle: "\(store.schedules.count) automation\(store.schedules.count == 1 ? "" : "s")",
                            symbol: "calendar.badge.clock",
                            prominent: true
                        )
                        Button { Task { await store.loadSchedules() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(DieterIconButtonStyle())
                        Button { editing = nil; editorPresented = true } label: { Label("New", systemImage: "plus") }
                            .buttonStyle(DieterPrimaryButtonStyle()).accessibilityIdentifier("schedules.new")
                    }
                }
                if store.schedules.isEmpty {
                    ContentUnavailableView("No schedules", systemImage: "calendar.badge.plus", description: Text("Automate cards and chats with cron schedules."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 7) {
                        ForEach(store.schedules, id: \.id) { schedule in
                            Button {
                                store.selectedScheduleID = schedule.id
                                Task { await store.loadSchedules() }
                            } label: {
                                ScheduleRow(schedule: schedule, selected: store.selectedScheduleID == schedule.id)
                            }
                            .buttonStyle(.plain)
                        }
                        }
                        .padding(10)
                    }
                }
            }.frame(minWidth: 280, idealWidth: 350, maxWidth: 440, maxHeight: .infinity, alignment: .top).background(DieterTheme.sidebar)

            if let schedule = store.selectedSchedule {
                ScheduleDetail(schedule: schedule, edit: { editing = schedule; editorPresented = true })
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
        .sheet(isPresented: $editorPresented) { ScheduleEditor(schedule: editing).environment(store) }
    }
}

struct ScheduleRow: View {
    let schedule: Dieter_V1_Schedule
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Circle().fill(schedule.enabled ? DieterTheme.eyes : DieterTheme.subtle).frame(width: 6, height: 6); Text(schedule.name).font(.system(size: 13, weight: .semibold)); Spacer(); if !schedule.enabled { Text("Paused").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary) } }
            Text(schedule.cron).font(.system(size: 11).monospaced()).foregroundStyle(DieterTheme.shell)
            HStack { Text(schedule.action.capitalized); Spacer(); Text(schedule.nextRunAt.isEmpty ? "No next run" : schedule.nextRunAt) }.font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
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
                    ScheduleMetric(title: "Action", value: schedule.action, symbol: "bolt")
                    ScheduleMetric(title: "Next run", value: schedule.nextRunAt.isEmpty ? "—" : schedule.nextRunAt, symbol: "forward")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("TEMPLATES").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                    Text(schedule.titleTemplate).font(.system(size: 13, weight: .semibold))
                    Text(schedule.promptTemplate).font(.system(size: 12)).foregroundStyle(DieterTheme.subtle).textSelection(.enabled)
                    HStack { StatusPill(text: schedule.provider); StatusPill(text: schedule.model); StatusPill(text: schedule.effort) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14).dieterSurface(radius: 10)
                HStack { Text("Recent runs").font(.system(size: 13, weight: .semibold)); Spacer(); Button("Delete schedule", role: .destructive) { Task { await store.deleteSchedule(schedule) } } }
                if store.scheduleRuns.isEmpty { Text("No occurrences yet.").foregroundStyle(.secondary) }
                ForEach(store.scheduleRuns, id: \.id) { run in
                    HStack { StatusPill(text: run.status, color: runtimeColor(run.status)); VStack(alignment: .leading) { Text(run.scheduledFor); if !run.message.isEmpty { Text(run.message).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Text(run.manual ? "Manual" : "Scheduled").font(.caption).foregroundStyle(.secondary); if !run.cardID.isEmpty { Button("Open card") { store.section = .board; Task { await store.openConversation(cardID: run.cardID) } } } }
                        .padding(10).dieterSurface(radius: 8)
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

    init(schedule: Dieter_V1_Schedule?) {
        self.schedule = schedule
        var draft = Dieter_V1_ScheduleDraft()
        draft.projectID = schedule?.projectID ?? ""
        draft.boardID = schedule?.boardID ?? ""
        draft.name = schedule?.name ?? ""
        draft.description_p = schedule?.description_p ?? ""
        draft.cron = schedule?.cron ?? "0 9 * * 1-5"
        draft.timezone = schedule?.timezone ?? TimeZone.current.identifier
        draft.enabled = schedule?.enabled ?? true
        draft.action = schedule?.action ?? "create_card"
        draft.titleTemplate = schedule?.titleTemplate ?? "Scheduled task"
        draft.promptTemplate = schedule?.promptTemplate ?? ""
        draft.provider = schedule?.provider ?? ""
        draft.model = schedule?.model ?? ""
        draft.effort = schedule?.effort ?? ""
        draft.openCardPolicy = schedule?.openCardPolicy ?? "allow"
        draft.misfirePolicy = schedule?.misfirePolicy ?? "skip"
        draft.busyPolicy = schedule?.busyPolicy ?? "queue"
        _draft = State(initialValue: draft)
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section("Schedule") {
                    TextField("Name", text: $draft.name)
                    TextField("Description", text: $draft.description_p)
                    Picker("Action", selection: $draft.action) { Text("Create card").tag("create_card"); Text("Create chat").tag("create_chat"); Text("Send message").tag("send_message") }
                    Picker("Board", selection: $draft.boardID) { ForEach(store.state.boards.filter { $0.projectID == store.selectedProjectID }, id: \.id) { Text($0.name).tag($0.id) } }
                }
                Section("Timing") {
                    TextField("Cron", text: $draft.cron).font(.body.monospaced())
                    TextField("Timezone", text: $draft.timezone)
                    Toggle("Enabled", isOn: $draft.enabled)
                    Button("Preview next runs") { Task { await previewRuns() } }
                    ForEach(preview, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
                Section("Agent task") {
                    TextField("Card title", text: $draft.titleTemplate)
                    TextEditor(text: $draft.promptTemplate).frame(height: 120)
                    HarnessFields(provider: $draft.provider, model: $draft.model, effort: $draft.effort, providerOptions: $draft.providerOptions)
                }
                Section("Admission") {
                    Picker("Open-card policy", selection: $draft.openCardPolicy) { Text("Allow").tag("allow"); Text("Skip").tag("skip") }
                    Picker("Misfire policy", selection: $draft.misfirePolicy) { Text("Skip").tag("skip"); Text("Run once").tag("run_once") }
                    Picker("Busy policy", selection: $draft.busyPolicy) { Text("Queue").tag("queue"); Text("Skip").tag("skip") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(schedule == nil ? "New schedule" : "Edit schedule")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { draft.projectID = store.selectedProjectID; Task { await store.saveSchedule(id: schedule?.id, draft: draft); dismiss() } }.disabled(draft.name.isEmpty || draft.cron.isEmpty || draft.promptTemplate.isEmpty) } }
        }.frame(width: 620, height: 700)
    }

    private func previewRuns() async {
        guard let rpc = store.rpc else { return }
        var request = Dieter_V1_PreviewScheduleRequest(); request.cron = draft.cron; request.timezone = draft.timezone; request.count = 5
        do { preview = try await rpc.previewSchedule(request).times } catch { store.show(error) }
    }
}
