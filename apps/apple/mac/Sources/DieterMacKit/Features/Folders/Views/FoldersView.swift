import AppKit
import DieterAPI
import DieterClientAPI
import SwiftUI

/// Synced folders: the account's folders on the left, the selected folder's members, trash and
/// settings beside them. A folder is on this Mac only through the daemon running here ("This
/// Mac"); the app manages folders and reveals that copy in Finder but syncs nothing itself.
struct FoldersView: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let model = store.foldersModel
        ChatPaneSplit(layout: .folders) {
            FolderListPane(model: model)
                .environment(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("folders.list-pane")
                .e2eTarget("folders.list-pane")
        } detail: {
            FolderDetailPane(model: model)
                .environment(store)
        }
        .defaultAppStorage(store.environment.defaults)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Which members are this Mac: the daemon running here, as the session found it on loopback.
extension AppSession {
    /// The daemon on this Mac, when it is enrolled and reachable.
    var localFolderDaemonID: String? { localMachine?.daemonID }

    func isThisMac(daemonID: String) -> Bool {
        !daemonID.isEmpty && (localDaemonIDs.contains(daemonID) || localMachine?.daemonID == daemonID)
    }

    /// The machine a folder daemon option names, for browsing its directories.
    func machine(forFolderDaemon daemonID: String) -> MachineEndpoint? {
        machines.first { $0.daemonID == daemonID }
    }
}

// MARK: - List

private struct FolderListPane: View {
    @Environment(DieterStore.self) private var store
    let model: FoldersModel
    @State private var creating = false

    var body: some View {
        let list = model.list
        VStack(spacing: 0) {
            DieterPaneTopBar {
                DieterTitleCapsule(
                    title: "Folders", count: model.attention > 0 ? model.attention : nil, symbol: "folder")
            } trailing: {
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle))
                .help("New folder")
                .accessibilityLabel("New folder")
                .accessibilityIdentifier("folders.new")
                .e2eTarget("folders.new")
            }
            if !list.notice.isEmpty {
                Text(list.notice).font(.caption2).foregroundStyle(DieterTheme.amber)
                    .padding(.horizontal, 16).padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if list.folders.isEmpty {
                if list.loading {
                    LoadFeedback(title: "Reading folders…")
                } else {
                    FoldersEmptyState(title: list.emptyTitle, detail: list.emptyDetail) { creating = true }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(list.folders, id: \.id) { row in
                            FolderListRow(row: row, selected: model.selectedID == row.id) {
                                model.select(row.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
            }
        }
        .sheet(isPresented: $creating) {
            NewFolderSheet(model: model).environment(store)
        }
    }
}

private struct FolderListRow: View {
    let row: ClientFolderRow
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: row.attention ? "folder.badge.questionmark" : "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(row.attention ? DieterTheme.amber : DieterTheme.shell)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(DieterTheme.text).lineLimit(1)
                    HStack(spacing: 5) {
                        DieterStatusDot(color: row.tone.color, size: 6)
                        Text(row.status).font(.system(size: 10.5)).foregroundStyle(DieterTheme.subtle).lineLimit(1)
                    }
                    if !row.members.isEmpty {
                        Text(row.members).font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if row.conflicts > 0 { DieterCountBadge(count: Int(row.conflicts), tint: DieterTheme.coral) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                    .fill(selected ? DieterTheme.tileSelected : (hovering ? DieterTheme.tileHover : .clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                    .strokeBorder(selected ? DieterTheme.tileRim : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(row.name), \(row.status)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("folders.row.\(row.id)")
        .e2eTarget("folders.row.\(row.id)", text: row.name)
    }
}

private struct FoldersEmptyState: View {
    let title: String
    let detail: String
    let create: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DieterTheme.shell)
                .frame(width: 60, height: 60)
                .background(DieterTheme.shell.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            Text(title.isEmpty ? "No folders yet" : title)
                .font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
                .multilineTextAlignment(.center).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("New folder", action: create).buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folders.empty")
        .e2eTarget("folders.empty", text: title)
    }
}

// MARK: - Detail

private struct FolderDetailPane: View {
    @Environment(DieterStore.self) private var store
    let model: FoldersModel

    var body: some View {
        if let slice = model.detail, slice.found {
            FolderDetail(model: model, slice: slice).id(slice.id)
        } else if model.selectedID != nil {
            LoadFeedback(title: model.detail == nil ? "Reading the folder…" : "This folder is not known yet.")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 30, weight: .light)).foregroundStyle(DieterTheme.shell)
                Text("Files on every machine").font(.system(size: 18, weight: .semibold))
                Text(
                    "Choose a folder to see which machines and phones keep it, what they deleted recently, and its settings."
                )
                .font(.system(size: 12.5)).foregroundStyle(DieterTheme.subtle).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("folders.empty-detail")
        }
    }
}

/// What the sheets of the detail act on.
private enum FolderDetailSheet: Identifiable {
    case settings
    case attach(FolderAttachTarget)

    var id: String {
        switch self {
        case .settings: "settings"
        case .attach(let target): "attach-\(target.daemonID)"
        }
    }
}

private struct FolderDetail: View {
    @Environment(DieterStore.self) private var store
    let model: FoldersModel
    let slice: ClientFolderSlice
    @State private var sheet: FolderDetailSheet?
    @State private var confirmArchive = false
    @State private var detaching: ClientFolderMemberRow?

    private var localDaemonID: String? { store.localFolderDaemonID }
    private var localMember: ClientFolderMemberRow? {
        slice.members.first { $0.daemon && store.isThisMac(daemonID: $0.memberID) }
    }
    private var localPath: String? {
        guard let member = localMember else { return nil }
        let path = model.member(folderID: slice.id, daemonID: member.memberID)?.path ?? ""
        return path.isEmpty ? nil : path
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DieterTheme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let error = model.errorMessage ?? (slice.actionError.isEmpty ? nil : slice.actionError)
                    if let error { DieterCallout(text: error, tint: DieterTheme.coral) }
                    thisMac
                    membersSection
                    if slice.hasPendingDeletions { deletionsSection(slice.pendingDeletions) }
                    if !slice.conflicts.isEmpty { conflictsSection }
                    FolderTrashSection(model: model, slice: slice)
                    settingsSection
                    if !slice.errors.isEmpty || !slice.unsyncable.isEmpty { problemsSection }
                }
                .padding(18)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folders.detail")
        .e2eTarget("folders.detail", text: slice.name)
        .task(id: localMember?.memberID) {
            // Only the daemon itself knows where it keeps the folder.
            guard let member = localMember else { return }
            _ = try? await model.readMember(folderID: slice.id, daemonID: member.memberID)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .settings: FolderSettingsSheet(model: model, slice: slice).environment(store)
            case .attach(let target):
                AttachMemberSheet(model: model, folderID: slice.id, folderName: slice.name, target: target)
                    .environment(store)
            }
        }
        .confirmationDialog("Archive \(slice.name)?", isPresented: $confirmArchive) {
            Button("Archive", role: .destructive) { Task { await model.archive(folderID: slice.id) } }
        } message: {
            Text("Every machine and phone stops syncing it. Their files stay where they are.")
        }
        .confirmationDialog(
            "Stop syncing on \(detaching?.name ?? "this machine")?",
            isPresented: Binding(get: { detaching != nil }, set: { if !$0 { detaching = nil } })
        ) {
            Button("Stop syncing", role: .destructive) {
                guard let member = detaching else { return }
                Task { await model.detachDaemon(folderID: slice.id, daemonID: member.memberID) }
            }
        } message: {
            Text("The files stay on that machine; only syncing stops.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(slice.name).font(DieterFont.paneTitle).lineLimit(1)
                HStack(spacing: 6) {
                    DieterStatusDot(color: slice.tone.color)
                    Text(slice.status).font(DieterFont.subtitle).foregroundStyle(DieterTheme.subtle).lineLimit(1)
                        .accessibilityIdentifier("folders.status")
                    if !slice.projectName.isEmpty {
                        Text("· \(slice.projectName)").font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            if let path = localPath, let url = FileExternalActions.localDirectory(verifiedLocal: true, path: path) {
                Button("Reveal in Finder", systemImage: "folder") { FileExternalActions.reveal(url) }
                    .buttonStyle(DieterBarButtonStyle(size: 28))
                    .accessibilityIdentifier("folders.reveal")
            }
            addMenu
            Menu {
                Button("Folder settings…", systemImage: "slider.horizontal.3") { sheet = .settings }
                Divider()
                Button("Archive folder…", systemImage: "archivebox", role: .destructive) { confirmArchive = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
            .fixedSize()
            .help("More")
            .accessibilityIdentifier("folders.more")
        }
        .padding(.horizontal, 18).padding(.top, DieterMetrics.titleBandTop + 6).padding(.bottom, 12)
    }

    /// Add this Mac (through its daemon) or another machine that is not a member yet.
    @ViewBuilder private var addMenu: some View {
        let addable = slice.addableDaemons
        let local = localDaemonID.flatMap { id in addable.first { $0.daemonID == id } }
        if !addable.isEmpty {
            Menu {
                if let local {
                    Button("Add this Mac…", systemImage: "laptopcomputer") {
                        sheet = .attach(FolderAttachTarget(daemonID: local.daemonID, name: local.name, thisMac: true))
                    }
                    Divider()
                }
                ForEach(addable.filter { $0.daemonID != local?.daemonID }, id: \.daemonID) { option in
                    Button(option.online ? option.name : "\(option.name) (offline)") {
                        sheet = .attach(
                            FolderAttachTarget(daemonID: option.daemonID, name: option.name, thisMac: false))
                    }
                    .disabled(!option.online)
                }
            } label: {
                Label("Add a machine", systemImage: "plus")
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(DieterBarButtonStyle(size: 28))
            .fixedSize()
            .accessibilityIdentifier("folders.add-machine")
        }
    }

    /// Whether this Mac keeps a copy, through the daemon running here.
    @ViewBuilder private var thisMac: some View {
        if localDaemonID == nil {
            DieterCallout(
                text: "Install the Dieter daemon on this Mac to keep a copy of your folders here.",
                tint: DieterTheme.subtle, symbol: "laptopcomputer")
        } else if localMember != nil {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(DieterTheme.shell)
                Text(localPath.map { "This Mac keeps a copy in \($0)" } ?? "This Mac keeps a copy.")
                    .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle).lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        } else if let local = localDaemonID.flatMap({ id in slice.addableDaemons.first { $0.daemonID == id } }) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(DieterTheme.tertiary)
                Text("This Mac keeps no copy of this folder.").font(.system(size: 12))
                    .foregroundStyle(DieterTheme.subtle)
                Spacer(minLength: 0)
                Button("Add this Mac…") {
                    sheet = .attach(FolderAttachTarget(daemonID: local.daemonID, name: local.name, thisMac: true))
                }
                .buttonStyle(DieterBarButtonStyle(size: 26))
                .accessibilityIdentifier("folders.add-this-mac")
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DieterSectionHeader(title: "Machines and phones")
            if slice.members.isEmpty {
                Text("No machine keeps this folder yet. Add one to start syncing.")
                    .font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
            }
            ForEach(slice.members, id: \.memberID) { member in
                let path = member.daemon ? model.member(folderID: slice.id, daemonID: member.memberID)?.path : nil
                FolderMemberRowView(
                    member: member, thisMac: member.daemon && store.isThisMac(daemonID: member.memberID),
                    path: path, model: model, folderID: slice.id,
                    browse: {
                        // That machine's daemon serves its copy as the root of Files.
                        Task {
                            await store.openFolderFiles(
                                folderID: slice.id, folderName: slice.name, daemonID: member.memberID,
                                machineName: member.name, path: path ?? "")
                        }
                    }
                ) {
                    detaching = member
                }
            }
        }
    }

    private func deletionsSection(_ held: ClientFolderDeletionsRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DieterCallout(text: held.title, tint: DieterTheme.amber, symbol: "trash")
            Text(held.detail).font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
            ForEach(held.sample.prefix(8), id: \.self) { path in
                Text(path).font(DieterFont.mono).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
            }
            HStack {
                Button("Restore files") {
                    Task { await model.resolveDeletions(folderID: slice.id, daemonID: "", apply: false) }
                }
                Button("Apply deletions", role: .destructive) {
                    Task { await model.resolveDeletions(folderID: slice.id, daemonID: "", apply: true) }
                }
            }
            .buttonStyle(DieterBarButtonStyle(size: 26))
        }
    }

    private var conflictsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DieterSectionHeader(title: "Conflicts")
            ForEach(slice.conflicts, id: \.path) { conflict in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conflict.path).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(conflict.detail).font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DieterSectionHeader(title: "Folder settings") {
                Button("Edit…") { sheet = .settings }
                    .buttonStyle(DieterBarButtonStyle(size: 24))
                    .accessibilityIdentifier("folders.settings")
            }
            SettingsValueRow(title: "Recently deleted kept", value: slice.trashLabel)
            SettingsValueRow(title: "Deletion guard", value: slice.deleteGuardLabel)
            SettingsValueRow(title: "Linked project", value: slice.projectName.isEmpty ? "None" : slice.projectName)
            SettingsValueRow(
                title: "Ignore rules", value: slice.rules.isEmpty ? "None" : "\(slice.rules.count) rules")
            if !slice.conflictFields.isEmpty {
                Text("Edited on two devices at once: \(slice.conflictFields.joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(DieterTheme.amber)
            }
        }
    }

    private var problemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DieterSectionHeader(title: "Problems")
            ForEach(Array((slice.errors + slice.unsyncable).prefix(20).enumerated()), id: \.offset) { _, problem in
                VStack(alignment: .leading, spacing: 1) {
                    Text(problem.path).font(DieterFont.mono).lineLimit(1)
                    Text(problem.message).font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                }
            }
        }
    }
}

/// One member: a daemon (this Mac's or another machine's) or a phone, with what a daemon member
/// can change from here.
private struct FolderMemberRowView: View {
    let member: ClientFolderMemberRow
    let thisMac: Bool
    let path: String?
    let model: FoldersModel
    let folderID: String
    /// Opens this daemon member's copy in Files.
    let browse: () -> Void
    let detach: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: member.daemon ? (thisMac ? "laptopcomputer" : "desktopcomputer") : "iphone")
                .font(.system(size: 14)).foregroundStyle(member.online ? DieterTheme.shell : DieterTheme.tertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if thisMac { FolderBadge("This Mac") }
                    if member.thisDevice { FolderBadge("This device") }
                    if !member.online {
                        Text("offline").font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                HStack(spacing: 5) {
                    DieterStatusDot(color: member.tone.color, size: 6)
                    Text(member.status).font(.system(size: 11)).foregroundStyle(DieterTheme.subtle).lineLimit(1)
                }
                Text(
                    [
                        member.modeLabel, member.lastSync.isEmpty ? "" : "last sync \(member.lastSync)",
                        member.home.isEmpty ? "" : "via \(member.home)",
                    ]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                )
                .font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                if let path, !path.isEmpty {
                    Text(path).font(DieterFont.monoSmall).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                        .truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 6)
            if member.daemon {
                Button(action: browse) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 24))
                .disabled(!member.online)
                .help("Browse files on \(member.name)")
                .accessibilityLabel("Browse files on \(member.name)")
                .accessibilityIdentifier("folders.member-browse.\(member.memberID)")
                .e2eTarget("folders.member-browse.\(member.memberID)")
                actions
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dieterTile(radius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folders.member.\(member.memberID)")
        .e2eTarget("folders.member.\(member.memberID)", text: member.name)
    }

    private var actions: some View {
        Menu {
            Picker(
                "Direction",
                selection: Binding(
                    get: { member.mode },
                    set: { mode in
                        Task {
                            await model.updateDaemon(folderID: folderID, daemonID: member.memberID) { $0.mode = mode }
                        }
                    })
            ) {
                Text("Two-way").tag(Dieter_V1_FolderMode.twoWay)
                Text("Upload only").tag(Dieter_V1_FolderMode.sendOnly)
                Text("Download only").tag(Dieter_V1_FolderMode.receiveOnly)
            }
            Button(member.paused ? "Resume syncing" : "Pause syncing") {
                let paused = !member.paused
                Task { await model.updateDaemon(folderID: folderID, daemonID: member.memberID) { $0.paused = paused } }
            }
            Button("Browse files", action: browse).disabled(!member.online)
            Button("Scan for changes now") {
                Task { await model.rescanDaemon(folderID: folderID, daemonID: member.memberID) }
            }
            .disabled(!member.online)
            if member.state == .attention {
                Divider()
                Button("Restore held files") {
                    Task { await model.resolveDeletions(folderID: folderID, daemonID: member.memberID, apply: false) }
                }
                Button("Apply held deletions", role: .destructive) {
                    Task { await model.resolveDeletions(folderID: folderID, daemonID: member.memberID, apply: true) }
                }
            }
            if thisMac, let path, let url = FileExternalActions.localDirectory(verifiedLocal: true, path: path) {
                Divider()
                Button("Reveal in Finder") { FileExternalActions.reveal(url) }
            }
            Divider()
            Button("Stop syncing here…", role: .destructive, action: detach)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 24))
        .fixedSize()
        .help("Change \(member.name)")
        .accessibilityIdentifier("folders.member-actions.\(member.memberID)")
    }
}

/// A small tinted label beside a member's name.
private struct FolderBadge: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.shell)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(DieterTheme.shell.opacity(0.12), in: Capsule())
    }
}

/// Recently deleted: a daemon member's trash, read on demand, with restore and purge.
private struct FolderTrashSection: View {
    let model: FoldersModel
    let slice: ClientFolderSlice
    @State private var daemonID = ""
    @State private var confirmPurge = false

    private var daemons: [ClientFolderMemberRow] { slice.members.filter(\.daemon) }

    var body: some View {
        let trash = slice.hasTrash ? slice.trash : nil
        let shown = trash.map { $0.daemonID == chosen } ?? false
        VStack(alignment: .leading, spacing: 6) {
            DieterSectionHeader(title: "Recently deleted") {
                if daemons.count > 1 {
                    Picker("Machine", selection: $daemonID) {
                        ForEach(daemons, id: \.memberID) { Text($0.name).tag($0.memberID) }
                    }
                    .labelsHidden().fixedSize()
                }
                Button(shown ? "Refresh" : "Show") { Task { await model.listTrash(daemonID: chosen) } }
                    .buttonStyle(DieterBarButtonStyle(size: 24))
                    .disabled(daemons.isEmpty || trash?.loading == true)
                    .accessibilityIdentifier("folders.trash.show")
            }
            if daemons.isEmpty {
                Text("Deleted and replaced files are kept on the folder's machines.")
                    .font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
            } else if let trash, shown {
                if !trash.error.isEmpty {
                    Text(trash.error).font(.caption).foregroundStyle(DieterTheme.coral)
                } else if trash.rows.isEmpty, !trash.loading {
                    Text("Nothing was deleted recently on \(trash.daemonName).")
                        .font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                }
                ForEach(trash.rows, id: \.id) { row in
                    HStack(spacing: 8) {
                        Image(systemName: "doc").foregroundStyle(DieterTheme.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Text([row.sizeLabel, row.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Button("Restore") { Task { await model.restoreTrash(daemonID: trash.daemonID, ids: [row.id]) } }
                            .buttonStyle(DieterBarButtonStyle(size: 24))
                    }
                }
                HStack {
                    if !trash.next.isEmpty {
                        Button("Show more") {
                            Task { await model.listTrash(daemonID: trash.daemonID, after: trash.next) }
                        }
                    }
                    Spacer()
                    if !trash.rows.isEmpty {
                        Button("Empty…", role: .destructive) { confirmPurge = true }
                    }
                }
                .buttonStyle(DieterBarButtonStyle(size: 24))
                if trash.loading { ProgressView().controlSize(.small) }
            }
        }
        .onAppear { if daemonID.isEmpty { daemonID = daemons.first?.memberID ?? "" } }
        .confirmationDialog(
            "Empty recently deleted on \(trash?.daemonName ?? "this machine")?", isPresented: $confirmPurge
        ) {
            Button("Empty", role: .destructive) { Task { await model.purgeTrash(daemonID: chosen, ids: []) } }
        } message: {
            Text("The old versions on that machine are deleted for good.")
        }
    }

    private var chosen: String { daemonID.isEmpty ? (daemons.first?.memberID ?? "") : daemonID }
}
