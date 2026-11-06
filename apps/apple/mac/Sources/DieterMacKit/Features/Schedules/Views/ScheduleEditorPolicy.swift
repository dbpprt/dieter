import DieterClientAPI
import DieterCore
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
        .padding(15).frame(maxWidth: .infinity, alignment: .leading).dieterTile(radius: 12)
    }
}

struct TemplateVariableButtons: View {
    let insert: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(ClientScheduleEditorOptions.shared.variables, id: \.key) { variable in
                Button {
                    insert(variable.key)
                } label: {
                    Text(variable.title).font(.system(size: 10, design: .monospaced))
                }
                .buttonStyle(DieterBarButtonStyle(size: 22))
                .help(variable.detail)
            }
        }
    }
}

/// Formats schedule times in the schedule's own time zone.
@MainActor
enum ScheduleDateFormatting {
    static func compact(_ value: String, timezone: String) -> String {
        format(value, timezone: timezone, pattern: "EEE, MMM d · HH:mm")
    }

    static func full(_ value: String, timezone: String) -> String {
        format(value, timezone: timezone, pattern: "EEEE, MMM d 'at' HH:mm")
    }

    /// The "yyyy-MM-dd" day of `value` (else now) in `timezone`, for template examples.
    static func day(_ value: String?, timezone: String) -> String {
        let date = value.flatMap { Date(epochMillis: SharedRules.shared.epochMillis(value: $0)) }
        return formatter(pattern: "yyyy-MM-dd", timezone: timezone).string(from: date ?? Date())
    }

    private static func format(_ value: String, timezone: String, pattern: String) -> String {
        guard let date = Date(epochMillis: SharedRules.shared.epochMillis(value: value)) else { return value }
        return formatter(pattern: pattern, timezone: timezone).string(from: date)
    }

    /// Formatters by pattern and time zone: lists format every row on each
    /// redraw, and creating a formatter costs far more than using one.
    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(pattern: String, timezone: String) -> DateFormatter {
        let key = pattern + "|" + timezone
        if let formatter = formatters[key] { return formatter }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = pattern
        formatter.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        formatters[key] = formatter
        return formatter
    }
}
