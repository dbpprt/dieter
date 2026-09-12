import DieterAPI
import DieterCore
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class ConversationFileTreeModel {
    struct Row: Identifiable {
        let entry: Dieter_V1_FileEntry
        let depth: Int
        var id: String { entry.path }
    }
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    private(set) var folders: [String: [Dieter_V1_FileEntry]] = [:]
    private(set) var expanded: Set<String> = [""]
    private(set) var loading: Set<String> = []
    var error: String?
    var showHidden = false
    @ObservationIgnored private var client: (any FilesRPC)?
    @ObservationIgnored private var generation = 0

    var rows: [Row] {
        var result: [Row] = []
        func append(_ path: String, depth: Int) {
            guard depth < 40 else { return }
            for entry in folders[path] ?? [] {
                guard result.count < 10_000 else { return }
                result.append(Row(entry: entry, depth: depth))
                if entry.kind == "directory", expanded.contains(entry.path) { append(entry.path, depth: depth + 1) }
            }
        }
        append("", depth: 0)
        return result
    }

    func bind(target: WorkspaceTarget, client: any FilesRPC) {
        guard self.target != target || self.client !== client else { return }
        generation &+= 1
        self.target = target; self.client = client
        folders = [:]; expanded = [""]; loading = []; error = nil
    }

    func load(_ path: String = "", force: Bool = false) async {
        guard let client, !loading.contains(path), force || folders[path] == nil else { return }
        let token = generation
        var request = Dieter_V1_ListFilesRequest()
        request.projectID = target.projectID; request.cardID = target.conversationID
        request.path = path; request.showHidden = showHidden
        loading.insert(path)
        defer { if token == generation { loading.remove(path) } }
        do {
            let value = try await client.listFiles(request)
            guard token == generation, !Task.isCancelled else { return }
            folders[path] = value.entries.sorted { a, b in
                if (a.kind == "directory") != (b.kind == "directory") { return a.kind == "directory" }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            error = nil
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            if !DieterRPCFailure.isCancellation(error) { self.error = DieterRPCFailure.message(for: error) }
        }
    }

    func toggle(_ path: String) async {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path); await load(path) }
    }

    func reveal(_ path: String) async {
        await load()
        let parts = path.split(separator: "/").dropLast()
        var parent = ""
        for component in parts {
            parent = parent.isEmpty ? String(component) : parent + "/" + component
            expanded.insert(parent)
            await load(parent)
        }
    }

    func refresh() async {
        generation &+= 1
        folders = [:]; loading = []
        for path in expanded.sorted() { await load(path) }
    }
}

struct ConversationFileNavigator: View {
    @Bindable var tab: ConversationContentTab
    let open: (String) -> Void
    @State private var filter = ""

    private var selectedPath: String {
        if case .file(let path, _) = tab.selection { return path }
        return ""
    }
    private var rows: [ConversationFileTreeModel.Row] {
        tab.tree.rows.filter { filter.isEmpty || $0.entry.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Menu {
                    Toggle(
                        "Show hidden files",
                        isOn: Binding(
                            get: { tab.tree.showHidden }, set: { tab.tree.showHidden = $0 }))
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("File options")
                Button {
                    Task { await tab.tree.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless).help("Refresh files")
                .accessibilityIdentifier("conversation.content.files.refresh")
                .smokeTarget("conversation.content.files.refresh")
            }
            .padding(.horizontal, 10).frame(height: 36)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Filter files", text: $filter).textFieldStyle(.plain)
                    .accessibilityIdentifier("conversation.content.files.filter")
                    .smokeTarget("conversation.content.files.filter")
            }
            .font(.system(size: 11)).padding(7)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8).padding(.bottom, 8)
            Divider()
            if tab.tree.folders.isEmpty, tab.tree.loading.contains("") {
                ProgressView().controlSize(.small).padding(14)
            }
            if let error = tab.tree.error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { row in
                            fileRow(row).id(row.id)
                        }
                        if rows.isEmpty, tab.tree.loading.isEmpty, tab.tree.error == nil {
                            Text(filter.isEmpty ? "No files" : "No matching files")
                                .font(.caption).foregroundStyle(.secondary).padding(16)
                        }
                    }.padding(6)
                }
                .onChange(of: selectedPath) { _, path in proxy.scrollTo(path) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(
                    tab.scope?.card?.workspace.branch.isEmpty == false
                        ? tab.scope!.card!.workspace.branch : "Conversation workspace"
                )
                .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DieterTheme.sidebar.opacity(0.65))
        .accessibilityIdentifier("conversation.content.files.navigator")
        .smokeTarget("conversation.content.files.navigator")
        .task(id: tab.transportRevision) { await tab.tree.reveal(selectedPath) }
        .onChange(of: tab.tree.showHidden) { _, _ in Task { await tab.tree.refresh() } }
    }

    private func fileRow(_ row: ConversationFileTreeModel.Row) -> some View {
        let directory = row.entry.kind == "directory"
        return Button {
            if directory { Task { await tab.tree.toggle(row.entry.path) } } else { open(row.entry.path) }
        } label: {
            HStack(spacing: 5) {
                Image(
                    systemName: directory ? (tab.tree.expanded.contains(row.id) ? "chevron.down" : "chevron.right") : ""
                )
                .font(.system(size: 8, weight: .semibold)).frame(width: 9)
                Image(systemName: directory ? "folder" : fileSymbol(row.entry.name))
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                Text(row.entry.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if tab.tree.loading.contains(row.id) { ProgressView().controlSize(.mini) }
            }
            .padding(.leading, CGFloat(row.depth * 12 + 4)).padding(.trailing, 5)
            .frame(height: 27)
            .contentShape(Rectangle())
            .background(selectedPath == row.id ? DieterTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.entry.name)
        .accessibilityIdentifier("conversation.content.files.row.\(row.id)")
        .smokeTarget("conversation.content.files.row.\(row.id)")
        .smokeTarget("conversation.content.files.\(tab.id.uuidString).row.\(row.id)")
    }

    private func fileSymbol(_ name: String) -> String {
        switch ProjectFileLanguage.detect(filename: name) {
        case .markdown: "doc.richtext"
        default: "doc.text"
        }
    }
}
