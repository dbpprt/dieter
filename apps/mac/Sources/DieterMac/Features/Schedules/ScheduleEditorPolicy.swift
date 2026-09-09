import DieterAPI
import SwiftUI

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
        draft.workspaceMode =
            schedule.map { ConversationWorkspaceMode.selectable($0.workspaceMode).rawValue } ?? "worktree"
        return draft
    }
}

struct ScheduleEditorSection<Content: View>: View {
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
                    Text(subtitle).font(.caption).foregroundStyle(DieterTheme.tertiary).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading).dieterSurface(radius: 12)
    }
}

struct TemplateVariableButtons: View {
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
        let day =
            switch cadence {
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
        let prefix =
            switch parsed.cadence {
            case .weekdays: "Weekdays"
            case .daily: "Every day"
            case .weekly: "Every \(weekdays.first { $0.value == parsed.weekday }?.full ?? "week")"
            case .custom: "Custom schedule"
            }
        return "\(prefix) at \(time) · \(timezone)"
    }

    static func timezoneOptions(including selected: String) -> [String] {
        let preferred = [
            TimeZone.current.identifier, "UTC", "Europe/Berlin", "Europe/London", "America/New_York", "America/Chicago",
            "America/Denver", "America/Los_Angeles", "Asia/Tokyo", "Asia/Shanghai", "Asia/Kolkata", "Australia/Sydney",
        ]
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
        guard let date = DieterTimestamp.date(from: value) else { return value }
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
        variables.reduce(template) { result, pair in
            result.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value)
        }
    }

    static func variables(scheduledAt: String?, timezone: String, project: String, board: String, schedule: String)
        -> [String: String]
    {
        let instant = scheduledAt.flatMap { DieterTimestamp.date(from: $0) } ?? Date()
        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyy-MM-dd";
        dateFormatter.timeZone = TimeZone(identifier: timezone) ?? .current
        let exact = scheduledAt ?? DieterTimestamp.string(from: instant)
        return [
            "date": dateFormatter.string(from: instant), "scheduled_at": exact, "project": project, "board": board,
            "schedule": schedule,
        ]
    }

    static func appending(_ token: String, to value: String) -> String {
        if value.isEmpty { return token }
        return value.last?.isWhitespace == true ? value + token : value + " " + token
    }
}

extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
