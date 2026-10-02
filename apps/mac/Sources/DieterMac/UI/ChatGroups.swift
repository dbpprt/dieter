import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

/// A project's section of the chats pane, as the core lays it out: a
/// preview of its newest chats, or every one while it shows all.
struct ChatProjectGroup: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    /// The projects the pane shows, in order, for drops between them.
    let projectIDs: [String]
    let section: ClientChatProjectSection
    let chats: [Dieter_V1_Card]
    let showArchived: Bool
    let toggleExpanded: () -> Void
    let toggleCollapsed: () -> Void
    let moveProject: (String, String?) -> Void
    @State private var pageIndex = 0
    @State private var dropTargeted = false

    private var collapsed: Bool { !section.showChats }

    private var headerAccessibilityLabel: String {
        collapsed ? "Expand \(project.name) chats" : "Collapse \(project.name) chats"
    }

    private var displayed: [Dieter_V1_Card] {
        guard section.showAll else { return chats }
        return Array(chats[page.lowerBound..<page.upperBound])
    }

    private var page: LaneCardPage {
        LaneCardPage.resolve(total: chats.count, requestedPage: pageIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Button(action: toggleCollapsed) {
                    HStack(spacing: 7) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(
                            .system(size: 8, weight: .bold)
                        ).foregroundStyle(DieterTheme.tertiary)
                        Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(
                            DieterTheme.tertiary)
                        Text(project.name.uppercased()).font(DieterFont.sectionLabel).tracking(0.8).lineLimit(1)
                            .foregroundStyle(DieterTheme.subtle)
                        Text("· \(section.total)").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                        Spacer(minLength: 4)

                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand \(project.name) chats" : "Collapse \(project.name) chats")
                .accessibilityLabel(headerAccessibilityLabel)
                .accessibilityIdentifier("chats.project.\(project.id).toggle")
                .smokeTarget("chats.project.\(project.id).toggle")
                if !showArchived {
                    Button {
                        store.beginStandaloneChat(projectID: project.id)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain).help("New chat in \(project.name)")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                dropTargeted ? DieterTheme.shellDeep.opacity(0.16) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
            .draggable(SidebarProjectDragPayload(projectID: project.id).encoded) {
                SidebarProjectDragPreview(project: project)
            }
            .dropDestination(for: String.self) { values, location in
                guard let value = values.first, let payload = SidebarProjectDragPayload(value),
                    payload.projectID != project.id
                else { return false }
                let targetIndex = projectIDs.firstIndex(of: project.id) ?? 0
                let beforeProjectID: String?
                if location.y < 12 {
                    beforeProjectID = project.id
                } else if projectIDs.indices.contains(targetIndex + 1) {
                    beforeProjectID = projectIDs[targetIndex + 1]
                } else {
                    beforeProjectID = nil
                }
                moveProject(payload.projectID, beforeProjectID)
                return true
            } isTargeted: {
                dropTargeted = $0
            }
            .animation(.easeOut(duration: 0.12), value: dropTargeted)

            if !collapsed {
                if chats.isEmpty {
                    Text(showArchived ? "No archived chats" : "No chats").font(.caption).foregroundStyle(
                        .tertiary
                    )
                    .padding(.leading, 36).padding(.vertical, 2)
                } else {
                    ChatGroupCard(chats: displayed) {
                        if section.hidden > 0 {
                            ChatRowSeparator()
                            if section.showAll {
                                VStack(spacing: 4) {
                                    if page.pageCount > 1 {
                                        ChatPageControls(
                                            page: page,
                                            previous: { pageIndex = max(0, page.page - 1) },
                                            next: { pageIndex = min(page.pageCount - 1, page.page + 1) }
                                        )
                                    }
                                    Button {
                                        pageIndex = 0
                                        toggleExpanded()
                                    } label: {
                                        Label("Show fewer", systemImage: "chevron.up")
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(DieterTheme.subtle)
                                            .padding(.leading, 24).padding(.vertical, 5)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                Button(action: toggleExpanded) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                                        Text("Show \(section.hidden) more")
                                    }
                                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                                    .padding(.leading, 27).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
        .onChange(of: chats.count) { _, _ in pageIndex = page.page }
    }
}

struct ChatNavigationFolderGroup: View {
    let folder: ClientChatFolderSection
    let chats: [Dieter_V1_Card]
    let toggleExpanded: () -> Void
    let moveChatHere: (String) -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var dropTargeted = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(folder.showChats ? 90 : 0))
                        Image(systemName: dropTargeted ? "folder.fill.badge.plus" : "folder.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(dropTargeted ? DieterTheme.shell : DieterTheme.subtle)
                        Text(folder.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        Text("\(chats.count)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(DieterTheme.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(DieterTheme.surface, in: Capsule())
                        Spacer(minLength: 0)
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
                        Image(systemName: "ellipsis").frame(width: 18, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Folder options")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .foregroundStyle(DieterTheme.subtle)
            .background(
                dropTargeted
                    ? DieterTheme.shellDeep.opacity(0.18)
                    : (hovering ? DieterTheme.surface.opacity(0.72) : DieterTheme.surface.opacity(0.42)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(dropTargeted ? DieterTheme.shell.opacity(0.55) : DieterTheme.border.opacity(0.6))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let payload = PinnedChatDragPayload(value) else { return false }
                moveChatHere(payload.chatID)
                return true
            } isTargeted: {
                dropTargeted = $0
            }
            .contextMenu {
                Button("Rename folder…", systemImage: "pencil", action: rename)
                Button("Delete folder", systemImage: "trash", role: .destructive, action: delete)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(folder.name), \(chats.count) chats")
            .accessibilityIdentifier("chats.folder.\(folder.folderID)")
            .smokeTarget("chats.folder.\(folder.folderID)")

            if folder.showChats {
                if chats.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.to.line.compact")
                        Text("Drop chats here")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DieterTheme.tertiary)
                    .padding(.leading, 28).padding(.vertical, 6)
                } else {
                    ChatGroupCard(chats: chats).padding(.leading, 14)
                }
            }
        }
        .animation(.snappy(duration: 0.18), value: folder.showChats)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }
}

struct ChatPageControls: View {
    let page: LaneCardPage
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: previous) { Image(systemName: "chevron.left") }
                .disabled(!page.canGoBackward)
                .accessibilityLabel("Previous chats")
            Text(page.rangeLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DieterTheme.tertiary)
                .frame(maxWidth: .infinity)
            Button(action: next) { Image(systemName: "chevron.right") }
                .disabled(!page.canGoForward)
                .accessibilityLabel("Next chats")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

/// Inset container that gives a project's conversations one bounded surface,
/// with hairline separators between rows for legible scanning.
struct ChatGroupCard<Footer: View>: View {
    let chats: [Dieter_V1_Card]
    let footer: Footer
    let movePinnedChat: ((String, String) -> Void)?

    init(chats: [Dieter_V1_Card], @ViewBuilder footer: () -> Footer) {
        self.chats = chats
        self.footer = footer()
        movePinnedChat = nil
    }

    init(chats: [Dieter_V1_Card]) where Footer == EmptyView {
        self.chats = chats
        footer = EmptyView()
        movePinnedChat = nil
    }

    init(chats: [Dieter_V1_Card], movePinnedChat: @escaping (String, String) -> Void)
    where Footer == EmptyView {
        self.chats = chats
        footer = EmptyView()
        self.movePinnedChat = movePinnedChat
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                if index > 0 { ChatRowSeparator() }
                if let movePinnedChat {
                    PinnedChatRow(card: chat) { draggedChatID in
                        movePinnedChat(draggedChatID, chat.id)
                    }
                } else {
                    ChatRow(card: chat)
                }
            }
            footer
        }
        .padding(3)
        .dieterSurface(radius: DieterMetrics.cardRadius)
    }
}

struct ChatRowSeparator: View {
    var body: some View {
        Rectangle().fill(DieterTheme.border).frame(height: 1).padding(.leading, 27).padding(
            .trailing, 4)
    }
}
