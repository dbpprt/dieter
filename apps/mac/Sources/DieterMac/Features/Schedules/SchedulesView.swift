import DieterAPI
import SwiftUI

enum SchedulesPresentationState: Equatable {
    case loading
    case empty
    case loaded
    case failed(String)

    static func resolve(isLoaded: Bool, isLoading: Bool, hasSchedules: Bool, error: String? = nil) -> Self {
        if let error, !hasSchedules, !isLoading { return .failed(error) }
        if !isLoaded || (isLoading && !hasSchedules) { return .loading }
        return hasSchedules ? .loaded : .empty
    }
}

struct SchedulesView: View {
    @Bindable var model: SchedulesModel
    let context: ScheduleEditorContext
    let prepare: @MainActor () async -> Bool
    let openCard: (String) -> Void
    @State private var editorPresentation: ScheduleEditorPresentation?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                FluidPaneChrome(background: DieterTheme.sidebar) {
                    HStack(spacing: 8) {
                        PaneTitleBlock(
                            title: "Schedules",
                            subtitle: model.schedulesAreLoaded
                                ? "\(model.schedulesTotalCount) automation\(model.schedulesTotalCount == 1 ? "" : "s")"
                                : (model.schedulesError == nil ? "Loading automations…" : "Automations unavailable"),
                            symbol: "calendar.badge.clock",
                            prominent: true
                        )
                        Button {
                            Task { await model.loadSchedules() }
                        } label: {
                            if model.schedulesLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(DieterIconButtonStyle())
                        .disabled(model.schedulesLoading)
                        Button {
                            editorPresentation = ScheduleEditorPresentation(schedule: nil, context: context)
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                        .buttonStyle(DieterPrimaryButtonStyle()).accessibilityIdentifier("schedules.new").disabled(
                            !model.isLive)
                    }
                }
                switch SchedulesPresentationState.resolve(
                    isLoaded: model.schedulesAreLoaded,
                    isLoading: model.schedulesLoading,
                    hasSchedules: !model.schedules.isEmpty,
                    error: model.schedulesError
                ) {
                case .loading:
                    LoadFeedback(title: "Loading schedules…")
                        .accessibilityIdentifier("schedules.loading")
                case .failed(let error):
                    LoadFeedback(title: "Schedules", error: error, retry: { Task { await model.loadSchedules() } })
                        .accessibilityIdentifier("schedules.error")
                case .empty:
                    ContentUnavailableView(
                        "No schedules", systemImage: "calendar.badge.plus",
                        description: Text("Automate cards and chats with cron schedules.")
                    )
                    .accessibilityIdentifier("schedules.empty")
                case .loaded:
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(model.schedules, id: \.id) { schedule in
                                Button {
                                    Task { await model.selectSchedule(schedule.id) }
                                } label: {
                                    ScheduleRow(schedule: schedule, selected: model.selectedScheduleID == schedule.id)
                                }
                                .buttonStyle(.plain)
                            }
                            if !model.schedulesNextPageToken.isEmpty {
                                Button {
                                    Task { await model.loadMoreSchedules() }
                                } label: {
                                    HStack(spacing: 8) {
                                        if model.schedulesLoadingMore { ProgressView().controlSize(.small) }
                                        Text(model.schedulesLoadingMore ? "Loading…" : "Load more schedules")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(DieterSecondaryButtonStyle())
                                .disabled(model.schedulesLoadingMore)
                                .accessibilityIdentifier("schedules.load-more")
                            }
                        }
                        .padding(10)
                    }
                    .accessibilityIdentifier("schedules.list")
                }
            }.frame(minWidth: 280, idealWidth: 350, maxWidth: 440, maxHeight: .infinity, alignment: .top).background(
                DieterTheme.sidebar)

            if let schedule = model.selectedSchedule {
                ScheduleDetail(
                    model: model, schedule: schedule, openCard: openCard,
                    edit: { editorPresentation = ScheduleEditorPresentation(schedule: schedule, context: context) })
            } else {
                VStack(spacing: 0) {
                    FluidPaneChrome {
                        PaneTitleBlock(
                            title: "Schedule details",
                            subtitle: "Select an automation to inspect its timing and run history",
                            symbol: "calendar.badge.clock")
                    }
                    ContentUnavailableView("Select a schedule", systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: model.connectionGeneration) {
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
                ScheduleEditor(model: model, context: presentation.context, schedule: presentation.schedule)
            }
    }
}

struct ScheduleEditorPresentation: Identifiable {
    let id = UUID()
    let schedule: Dieter_V1_Schedule?
    let context: ScheduleEditorContext
}

struct ScheduleRow: View {
    let schedule: Dieter_V1_Schedule
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(schedule.enabled ? DieterTheme.eyes : DieterTheme.subtle).frame(width: 6, height: 6);
                Text(schedule.name).font(.system(size: 13, weight: .semibold)); Spacer();
                if !schedule.enabled { Text("Paused").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary) }
            }
            Text(ScheduleTiming.summary(cron: schedule.cron, timezone: schedule.timezone))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.shell)
            HStack {
                Text(ScheduleActionPresentation.title(schedule.action)); Spacer();
                Text(
                    schedule.nextRunAt.isEmpty
                        ? "No next run"
                        : ScheduleDateFormatting.compact(schedule.nextRunAt, timezone: schedule.timezone))
            }.font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? DieterTheme.selection : DieterTheme.surface.opacity(0.5),
            in: RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous).stroke(
                selected ? .clear : DieterTheme.border)
        )
        .contentShape(RoundedRectangle(cornerRadius: DieterMetrics.cardRadius))
    }
}

struct ScheduleDetail: View {
    @Bindable var model: SchedulesModel
    let schedule: Dieter_V1_Schedule
    let openCard: (String) -> Void
    let edit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FluidPaneChrome(background: DieterTheme.sidebar, spacing: 8) {
                HStack(spacing: 10) {
                    PaneTitleBlock(
                        title: schedule.name,
                        subtitle: schedule.description_p.isEmpty
                            ? "Scheduled \(schedule.action.replacingOccurrences(of: "_", with: " "))"
                            : schedule.description_p,
                        symbol: "calendar.badge.clock"
                    )
                    Group {
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { schedule.enabled }, set: { _ in Task { await model.toggleSchedule(schedule) } })
                        )
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Button("Edit", action: edit).buttonStyle(DieterSecondaryButtonStyle())
                        Button("Run now") { Task { await model.runSchedule(schedule) } }.buttonStyle(
                            DieterPrimaryButtonStyle())
                    }.disabled(!model.isLive)
                }
            } secondary: {
                HStack(spacing: 8) {
                    Text(schedule.cron).font(.system(size: 11, design: .monospaced))
                    Text("·")
                    Text(schedule.timezone)
                    Spacer()
                    StatusPill(
                        text: schedule.enabled ? "Enabled" : "Paused",
                        color: schedule.enabled ? DieterTheme.eyes : DieterTheme.subtle)
                }
                .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        ScheduleMetric(title: "Cron", value: schedule.cron, symbol: "clock")
                        ScheduleMetric(title: "Timezone", value: schedule.timezone, symbol: "globe")
                        ScheduleMetric(
                            title: "Placement", value: ScheduleActionPresentation.title(schedule.action),
                            symbol: "rectangle.stack")
                        ScheduleMetric(
                            title: "Next run",
                            value: schedule.nextRunAt.isEmpty
                                ? "—" : ScheduleDateFormatting.compact(schedule.nextRunAt, timezone: schedule.timezone),
                            symbol: "forward")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TEMPLATES").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(
                            DieterTheme.tertiary)
                        Text(schedule.titleTemplate).font(.system(size: 13, weight: .semibold))
                        Text(schedule.promptTemplate).font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
                            .textSelection(.enabled)
                        HStack {
                            StatusPill(text: schedule.provider); StatusPill(text: schedule.model);
                            StatusPill(text: schedule.effort)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).dieterSurface(radius: 10)
                    HStack {
                        Text("Recent runs").font(.system(size: 13, weight: .semibold)); Spacer();
                        Button("Delete schedule", role: .destructive) { Task { await model.deleteSchedule(schedule) } }
                            .disabled(!model.isLive)
                    }
                    if model.scheduleRunsLoading && model.scheduleRuns.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading occurrences…")
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        if model.scheduleRuns.isEmpty { Text("No occurrences yet.").foregroundStyle(.secondary) }
                        ForEach(model.scheduleRuns, id: \.id) { run in
                            HStack {
                                StatusPill(text: run.status, color: runtimeColor(run.status));
                                VStack(alignment: .leading) {
                                    Text(run.scheduledFor);
                                    if !run.message.isEmpty {
                                        Text(run.message).font(.caption).foregroundStyle(.secondary)
                                    }
                                }; Spacer();
                                Text(run.manual ? "Manual" : "Scheduled").font(.caption).foregroundStyle(.secondary);
                                if !run.cardID.isEmpty { Button("Open card") { openCard(run.cardID) } }
                            }
                            .padding(10).dieterSurface(radius: 8)
                        }
                        if !model.scheduleRunsNextPageToken.isEmpty {
                            Button {
                                Task { await model.loadMoreScheduleRuns() }
                            } label: {
                                HStack(spacing: 8) {
                                    if model.scheduleRunsLoadingMore { ProgressView().controlSize(.small) }
                                    Text(model.scheduleRunsLoadingMore ? "Loading older runs…" : "Load older runs")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(DieterSecondaryButtonStyle())
                            .disabled(model.scheduleRunsLoadingMore)
                            .accessibilityIdentifier("schedule-runs.load-more")
                        }
                    }
                }.padding(20)
            }
        }
    }
}

struct ScheduleMetric: View {
    let title: String, value: String, symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary);
            Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(2)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).dieterSurface(radius: 10)
    }
}
