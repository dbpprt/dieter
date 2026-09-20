#if os(iOS)
    import DieterAPI
    import SwiftUI

    struct IOSStatusBadge: View {
        let state: String

        private var tint: Color {
            switch state.lowercased() {
            case "running", "starting", "resuming", "connected": .green
            case "failed", "error", "offline": .orange
            case "waiting", "queued", "pending": .blue
            default: .secondary
            }
        }

        var body: some View {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(state.isEmpty ? "Idle" : state.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    struct IOSTaskRow: View {
        let card: Dieter_V1_Card
        var projectName: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.title.isEmpty ? "Untitled task" : card.title)
                    .font(.headline)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                if let projectName, !projectName.isEmpty {
                    Text(projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    IOSStatusBadge(state: card.runtime)
                    if !card.lane.isEmpty {
                        Text(card.lane.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if card.commentCount > 0 {
                        Label("\(card.commentCount)", systemImage: "text.bubble")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
    }

    struct IOSMessageText: View {
        let text: String

        private var formatted: AttributedString {
            (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        }

        var body: some View {
            Text(formatted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    struct IOSConnectionBanner: View {
        let title: String
        var detail: String = ""
        var retry: (() -> Void)?

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium))
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if let retry { Button("Retry", action: retry).font(.subheadline.weight(.semibold)) }
            }
            .padding(12)
            .background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios.connection.banner")
        }
    }

    enum IOSWorkspaceDestination: Hashable {
        case machine
        case allTasks
        case chats
        case screens
        case project(String)
        case board(String)
    }

    struct IOSFileScope: Identifiable {
        let machineID: String
        let projectID: String
        let cardID: String
        let title: String
        var id: String { machineID + ":" + projectID + ":" + cardID }
    }
#endif
