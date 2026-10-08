import DieterAPI
import SwiftUI

struct SchedulesView: View {
    @Bindable var model: SchedulesModel
    let context: ScheduleEditorContext
    let prepare: @MainActor () async -> Bool
    let openCard: (String) -> Void
    @State private var editorPresentation: ScheduleEditorPresentation?

    var body: some View {
        DieterSectionScaffold {
            DieterTitleCapsule(title: "Schedules", symbol: "calendar.badge.clock", detail: model.subtitle)
        } trailing: {
            Button {
                Task { await model.loadSchedules() }
            } label: {
                if model.schedulesLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12.5, weight: .medium))
                }
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle))
            .disabled(model.schedulesLoading)
            .help("Refresh schedules")
            ProjectCheckoutMenu(projectID: context.target.projectID)
            Button {
                Task { await openEditor(scheduleID: nil, owner: "") }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("New schedule")
                }
            }
            .buttonStyle(DieterBarButtonStyle())
            .accessibilityIdentifier("schedules.new").disabled(!model.isLive)
        } content: {
            HSplitView {
                VStack(spacing: 0) {
                    switch model.state {
                    case .failed:
                        LoadFeedback(
                            title: "Schedules", error: model.schedulesError,
                            retry: { Task { await model.loadSchedules() } }
                        )
                        .accessibilityIdentifier("schedules.error")
                    case .empty:
                        ContentUnavailableView(
                            options.emptyTitle, systemImage: "calendar.badge.plus",
                            description: Text(options.emptyDetail)
                        )
                        .accessibilityIdentifier("schedules.empty")
                    case .loaded:
                        ScrollView {
                            LazyVStack(spacing: 7) {
                                ForEach(model.schedules, id: \.id) { schedule in
                                    Button {
                                        Task { await model.selectSchedule(schedule.id) }
                                    } label: {
                                        ScheduleRow(
                                            schedule: schedule, row: model.rows[schedule.id] ?? ClientScheduleRow(),
                                            selected: model.selectedScheduleID == schedule.id)
                                    }
                                    .buttonStyle(.plain)
                                }
                                if !model.schedulesNextPageToken.isEmpty {
                                    Button {
                                        Task { await model.loadMoreSchedules() }
                                    } label: {
                                        HStack(spacing: 8) {
                                            if model.schedulesLoadingMore { ProgressView().controlSize(.small) }
                                            Text(model.schedulesLoadingMore ? options.loadingMore : options.loadMore)
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(DieterBarButtonStyle(size: 28))
                                    .disabled(model.schedulesLoadingMore)
                                    .accessibilityIdentifier("schedules.load-more")
                                }
                            }
                            .padding(10)
                        }
                        .accessibilityIdentifier("schedules.list")
                    default:
                        LoadFeedback(title: "Loading schedules…")
                            .accessibilityIdentifier("schedules.loading")
                    }
                }.frame(minWidth: 280, idealWidth: 350, maxWidth: 440, maxHeight: .infinity, alignment: .top)

                if let schedule = model.selectedSchedule {
                    ScheduleDetail(
                        model: model, schedule: schedule, row: model.rows[schedule.id] ?? ClientScheduleRow(),
                        openCard: openCard,
                        edit: { Task { await openEditor(scheduleID: schedule.id, owner: schedule.ownerDaemonID) } })
                } else {
                    ContentUnavailableView(
                        "Select a schedule", systemImage: "calendar.badge.clock",
                        description: Text("Inspect an automation's timing and run history.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.target.projectID) {
            let target = model.target
            guard await prepare(), !Task.isCancelled, model.target == target else { return }
            await model.loadSchedules()
        }
        .alert(
            "Schedules",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $editorPresentation) { presentation in
            ScheduleEditor(
                model: model, context: presentation.context, scheduleID: presentation.scheduleID,
                draft: presentation.draft)
        }
    }

    private var options: ClientScheduleEditorOptions { .shared }

    /// Opens the editor once the core prepared its draft.
    private func openEditor(scheduleID: String?, owner: String) async {
        guard let draft = await model.editorDraft(scheduleID: scheduleID, context: context) else { return }
        let prepared = await model.editorContext(owner: owner, draft: draft, base: context)
        editorPresentation = ScheduleEditorPresentation(scheduleID: scheduleID, draft: draft, context: prepared)
    }
}

struct ScheduleEditorPresentation: Identifiable {
    let id = UUID()
    let scheduleID: String?
    let draft: Dieter_V1_ScheduleDraft
    let context: ScheduleEditorContext
}

struct ScheduleRow: View {
    let schedule: Dieter_V1_Schedule
    let row: ClientScheduleRow
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(schedule.enabled ? DieterTheme.eyes : DieterTheme.subtle).frame(width: 6, height: 6);
                Text(schedule.name).font(.system(size: 13, weight: .semibold)); Spacer();
                if !schedule.enabled {
                    Text(row.status).font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            Text(row.timing)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.shell)
            HStack {
                Text(row.placement); Spacer();
                Text(nextRun(schedule, row))
            }.font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dieterTile(DieterTileState(selected: selected, hovering: hovering))
        .contentShape(RoundedRectangle(cornerRadius: DieterMetrics.cardRadius))
        .onHover { hovering = $0 }
    }
}

/// A schedule's next run in its own time zone, or the core's fallback.
private func nextRun(_ schedule: Dieter_V1_Schedule, _ row: ClientScheduleRow) -> String {
    row.nextRunFallback.isEmpty
        ? ScheduleDateFormatting.compact(schedule.nextRunAt, timezone: schedule.timezone) : row.nextRunFallback
}

struct ScheduleDetail: View {
    @Bindable var model: SchedulesModel
    let schedule: Dieter_V1_Schedule
    let row: ClientScheduleRow
    let openCard: (String) -> Void
    let edit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(schedule.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle).font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Group {
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { schedule.enabled }, set: { _ in Task { await model.toggleSchedule(schedule) } })
                        )
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Button("Edit", action: edit).buttonStyle(DieterBarButtonStyle(size: 28))
                        Button("Run now") { Task { await model.runSchedule(schedule) } }.buttonStyle(
                            DieterBarButtonStyle(prominent: true, size: 28))
                    }.disabled(!model.isLive)
                }
                HStack(spacing: 8) {
                    Text(schedule.cron).font(.system(size: 11, design: .monospaced))
                    Text("·")
                    Text(schedule.timezone)
                    Spacer()
                    StatusPill(text: row.status, color: schedule.enabled ? DieterTheme.eyes : DieterTheme.subtle)
                }
                .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
            }
            .padding(.horizontal, 16).padding(.top, DieterMetrics.headerTopPadding).padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        ScheduleMetric(title: "Cron", value: schedule.cron, symbol: "clock")
                        ScheduleMetric(title: "Timezone", value: schedule.timezone, symbol: "globe")
                        ScheduleMetric(title: "Placement", value: row.placement, symbol: "rectangle.stack")
                        ScheduleMetric(title: "Next run", value: nextRun(schedule, row), symbol: "forward")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TEMPLATES").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(
                            DieterTheme.tertiary)
                        Text(schedule.titleTemplate).font(.system(size: 13, weight: .semibold))
                        Text(schedule.promptTemplate).font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
                            .textSelection(.enabled)
                        HStack {
                            StatusPill(text: row.providerLabel); StatusPill(text: row.modelLabel);
                            StatusPill(text: row.effortLabel)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).dieterTile(radius: 10)
                    HStack {
                        Text("Recent runs").font(.system(size: 13, weight: .semibold)); Spacer();
                        Button("Delete schedule", role: .destructive) { Task { await model.deleteSchedule(schedule) } }
                            .buttonStyle(DieterBarButtonStyle(destructive: true, size: 28))
                            .disabled(!model.isLive)
                    }
                    if model.scheduleRunsLoading && model.runRows.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(options.runsLoading)
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        if model.runRows.isEmpty { Text(options.runsEmpty).foregroundStyle(.secondary) }
                        ForEach(model.runRows, id: \.id) { run in
                            HStack {
                                StatusPill(text: run.status, color: Self.color(run.tone));
                                VStack(alignment: .leading) {
                                    Text(ScheduleDateFormatting.compact(run.at, timezone: schedule.timezone));
                                    if !run.message.isEmpty {
                                        Text(run.message).font(.caption).foregroundStyle(.secondary)
                                    }
                                }; Spacer();
                                Text(run.trigger).font(.caption).foregroundStyle(.secondary);
                                if !run.cardID.isEmpty {
                                    Button("Open card") { openCard(run.cardID) }
                                        .buttonStyle(DieterBarButtonStyle(size: 24))
                                }
                            }
                            .padding(10).dieterTile(radius: 8)
                        }
                        if !model.scheduleRunsNextPageToken.isEmpty {
                            Button {
                                Task { await model.loadMoreScheduleRuns() }
                            } label: {
                                HStack(spacing: 8) {
                                    if model.scheduleRunsLoadingMore { ProgressView().controlSize(.small) }
                                    Text(
                                        model.scheduleRunsLoadingMore ? options.loadingOlderRuns : options.loadOlderRuns
                                    )
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(DieterBarButtonStyle(size: 28))
                            .disabled(model.scheduleRunsLoadingMore)
                            .accessibilityIdentifier("schedule-runs.load-more")
                        }
                    }
                }.padding(20)
            }
        }
    }
}

extension ScheduleDetail {
    private var options: ClientScheduleEditorOptions { .shared }

    static func color(_ tone: ClientScheduleRunRow.Tone) -> Color {
        switch tone {
        case .active: DieterTheme.primary
        case .success: DieterTheme.eyes
        case .failure: DieterTheme.coral
        default: DieterTheme.subtle
        }
    }
}

struct ScheduleMetric: View {
    let title: String, value: String, symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary);
            Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(2)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).dieterTile(radius: 10)
    }
}
