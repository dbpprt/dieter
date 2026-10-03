import DieterAPI
import DieterShared
import SwiftUI

extension ClientScheduleEditorOptions {
    /// The schedule screens' fixed choices and wording, from the shared core.
    static let shared = ClientScheduleEditorOptions(rules: SharedRules.shared.scheduleEditorOptions())
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
            ForEach(ClientScheduleEditorOptions.shared.variables, id: \.key) { variable in
                Button(variable.title) { insert(variable.key) }
                    .buttonStyle(.bordered).controlSize(.mini).font(.system(size: 10, design: .monospaced))
                    .help(variable.detail)
            }
        }
    }
}

/// Formats schedule times in the schedule's own time zone.
enum ScheduleDateFormatting {
    static func compact(_ value: String, timezone: String) -> String {
        format(value, timezone: timezone, pattern: "EEE, MMM d · HH:mm")
    }

    static func full(_ value: String, timezone: String) -> String {
        format(value, timezone: timezone, pattern: "EEEE, MMM d 'at' HH:mm")
    }

    /// The "yyyy-MM-dd" day of `value` (else now) in `timezone`, for template examples.
    static func day(_ value: String?, timezone: String) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        let date = value.flatMap { Date(epochMillis: SharedRules.shared.epochMillis(value: $0)) }
        return formatter.string(from: date ?? Date())
    }

    private static func format(_ value: String, timezone: String, pattern: String) -> String {
        guard let date = Date(epochMillis: SharedRules.shared.epochMillis(value: value)) else { return value }
        let formatter = DateFormatter(); formatter.dateFormat = pattern
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        return formatter.string(from: date)
    }
}
