import DieterClientAPI
import SwiftUI

struct SidebarProjectFolderGroup<Content: View>: View {
    let folder: ClientNavigationFolder
    let visibleCount: Int
    let toggleExpanded: () -> Void
    let moveProjectHere: (String) -> Void
    let rename: () -> Void
    let delete: () -> Void
    @ViewBuilder let content: Content
    @State private var dropTargeted = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DieterTheme.tertiary)
                            .rotationEffect(.degrees(folder.expanded ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: dropTargeted ? "folder.fill.badge.plus" : "folder")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(dropTargeted ? DieterTheme.shell : DieterTheme.subtle)
                        Text(folder.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DieterTheme.text.opacity(0.88))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if !hovering {
                            Text("\(visibleCount)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if hovering {
                    Menu {
                        Button("Rename folder…", systemImage: "pencil", action: rename)
                        Divider()
                        Button("Delete folder", systemImage: "trash", role: .destructive, action: delete)
                    } label: {
                        DieterMenuLabel(symbol: "ellipsis", size: 24)
                    }
                    .dieterMenuChrome(.circle)
                    .help("Folder options")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: DieterMetrics.rowHeight)
            .background(
                dropTargeted ? DieterTheme.tileSelected : (hovering ? DieterTheme.tileHover : .clear),
                in: RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                    .strokeBorder(dropTargeted ? DieterTheme.shell.opacity(0.55) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let payload = SidebarProjectDragPayload(value) else { return false }
                moveProjectHere(payload.projectID)
                return true
            } isTargeted: {
                dropTargeted = $0
            }
            .contextMenu {
                Button("Rename folder…", systemImage: "pencil", action: rename)
                Button("Delete folder", systemImage: "trash", role: .destructive, action: delete)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(folder.name), \(visibleCount) projects")
            .accessibilityIdentifier("sidebar.project-folder.\(folder.id)")
            .e2eTarget("sidebar.project-folder.\(folder.id)")

            if folder.expanded {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.leading, 10)
            }
        }
        .padding(.vertical, 1)
        .animation(.snappy(duration: 0.18), value: folder.expanded)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }
}

/// Drops a project above `beforeProjectID`, else at the end of the list.
struct SidebarProjectInsertionTarget: View {
    @Environment(DieterStore.self) private var store
    let beforeProjectID: String?
    @State private var targeted = false

    var body: some View {
        ZStack {
            Color.clear
            if targeted {
                HStack(spacing: 5) {
                    Circle().fill(DieterTheme.shell).frame(width: 5, height: 5)
                    Capsule().fill(DieterTheme.shell).frame(height: 2)
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let payload = SidebarProjectDragPayload(value),
                payload.projectID != beforeProjectID
            else { return false }
            store.moveProject(payload.projectID, before: beforeProjectID, ungrouped: false)
            return true
        } isTargeted: {
            targeted = $0
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

struct SidebarProjectDragPreview: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(DieterTheme.shell)
            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(width: 190, height: 38, alignment: .leading)
        .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DieterTheme.shell.opacity(0.4)))
        .shadow(color: Color.black.opacity(0.4), radius: 14, y: 7)
    }
}

struct SidebarProjectDragPayload: Equatable {
    private static let prefix = "dieter:sidebar-project:"
    let projectID: String

    init(projectID: String) {
        self.projectID = projectID
    }

    init?(_ encoded: String) {
        guard encoded.hasPrefix(Self.prefix) else { return nil }
        let projectID = String(encoded.dropFirst(Self.prefix.count))
        guard !projectID.isEmpty else { return nil }
        self.projectID = projectID
    }

    var encoded: String { Self.prefix + projectID }
}
