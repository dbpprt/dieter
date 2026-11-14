import AppKit
import DieterAPI
import DieterClientAPI
import SwiftUI

/// The machine a folder is being added to: this Mac's daemon or another machine's.
struct FolderAttachTarget: Equatable {
    let daemonID: String
    let name: String
    /// The daemon runs on this Mac, so a path picked here is valid for it.
    let thisMac: Bool
}

/// A sheet's title row with its close button.
private struct FolderSheetHeader: View {
    let caption: String
    let title: String
    var disabled = false
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(caption).font(DieterFont.sectionLabel).tracking(1.4).foregroundStyle(DieterTheme.tertiary)
                Text(title).font(.system(size: 20, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28)).help("Close").disabled(disabled)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 15)
    }
}

/// Picks a linked project: turns of that project on member machines learn the folder's path.
private struct FolderProjectPicker: View {
    @Environment(DieterStore.self) private var store
    @Binding var projectID: String

    var body: some View {
        Picker("Linked project", selection: $projectID) {
            Text("None").tag("")
            ForEach(store.projects.filter { !$0.archived }, id: \.id) { Text($0.name).tag($0.id) }
        }
    }
}

// MARK: - New folder

struct NewFolderSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let model: FoldersModel
    @State private var name = ""
    @State private var projectID = ""
    @State private var daemonID = ""
    @State private var submitting = false

    var body: some View {
        VStack(spacing: 0) {
            FolderSheetHeader(caption: "SYNCED FOLDER", title: "New folder", disabled: submitting) { dismiss() }
            Form {
                TextField("Name", text: $name, prompt: Text("Inbox"))
                    .accessibilityIdentifier("folders.new.name")
                FolderProjectPicker(projectID: $projectID)
                Picker("Record on", selection: $daemonID) {
                    Text("Any reachable machine").tag("")
                    ForEach(model.list.daemons.filter(\.online), id: \.daemonID) { Text($0.name).tag($0.daemonID) }
                }
                Text(
                    "A folder has no location of its own. Add machines to it next; each keeps a copy in a directory you choose."
                )
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(DieterTheme.coral)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle(size: 30))
                Button("Create") {
                    submitting = true
                    Task {
                        let created = await model.create(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines), projectID: projectID,
                            daemonID: daemonID)
                        submitting = false
                        if created != nil { dismiss() }
                    }
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
                .accessibilityIdentifier("folders.new.create")
            }
            .padding(16)
        }
        .frame(width: 480, height: 400)
        .background(DieterTheme.background)
    }
}

// MARK: - Folder settings

/// The shared definition: name, ignore rules, trash retention, deletion guard and project link.
struct FolderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: FoldersModel
    let slice: ClientFolderSlice
    @State private var name = ""
    @State private var rules = ""
    @State private var trashDays: Int32 = 30
    @State private var deleteGuard = Dieter_V1_FolderDeleteGuard.default
    @State private var projectID = ""
    @State private var submitting = false

    /// The trash choices; negative turns it off.
    private static let trashChoices: [(Int32, String)] = [(-1, "Off"), (7, "7 days"), (30, "30 days"), (90, "90 days")]

    private var ruleLines: [String] {
        rules.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            FolderSheetHeader(caption: "FOLDER SETTINGS", title: slice.name, disabled: submitting) { dismiss() }
            Form {
                TextField("Name", text: $name)
                FolderProjectPicker(projectID: $projectID)
                Picker("Keep deleted files", selection: $trashDays) {
                    ForEach(Self.trashChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Deletion guard", selection: $deleteGuard) {
                    Text("More than 100 files or 30%").tag(Dieter_V1_FolderDeleteGuard.default)
                    Text("Strict: more than 10 files or 10%").tag(Dieter_V1_FolderDeleteGuard.strict)
                    Text("Off").tag(Dieter_V1_FolderDeleteGuard.off)
                }
                Section("Ignore rules") {
                    TextEditor(text: $rules)
                        .font(DieterFont.mono)
                        .frame(minHeight: 110)
                    Text(
                        "One pattern per line: -PATTERN ignores, +PATTERN includes again; the last match wins. .git is always ignored."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(DieterTheme.coral)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle(size: 30))
                Button("Save") { save() }
                    .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
                    .accessibilityIdentifier("folders.settings.save")
            }
            .padding(16)
        }
        .frame(width: 540, height: 560)
        .background(DieterTheme.background)
        .onAppear {
            name = slice.name
            rules = slice.rules.joined(separator: "\n")
            trashDays = slice.trashDays <= 0 ? -1 : slice.trashDays
            deleteGuard = slice.deleteGuard == .unspecified ? .default : slice.deleteGuard
            projectID = slice.projectID
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTrash: Int32 = slice.trashDays <= 0 ? -1 : slice.trashDays
        let currentGuard = slice.deleteGuard == .unspecified ? .default : slice.deleteGuard
        submitting = true
        Task {
            let saved = await model.update(
                folderID: slice.id, name: trimmed == slice.name ? nil : trimmed,
                rules: ruleLines == slice.rules ? nil : ruleLines,
                trashDays: trashDays == currentTrash ? nil : trashDays,
                deleteGuard: deleteGuard == currentGuard ? nil : deleteGuard,
                projectID: projectID == slice.projectID ? nil : projectID)
            submitting = false
            if saved { dismiss() }
        }
    }
}

// MARK: - Add a machine

/// Adds this Mac (a directory picked here, which the local daemon can use) or another machine (a
/// directory on its host) to a folder: plans the join first, then attaches.
struct AttachMemberSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let model: FoldersModel
    let folderID: String
    let folderName: String
    let target: FolderAttachTarget
    @State private var path = ""
    @State private var mode = Dieter_V1_FolderMode.twoWay
    @State private var join = Dieter_V1_FolderJoin.merge
    @State private var plan: Dieter_V1_AttachFolderResult?
    @State private var browsing = false
    @State private var submitting = false

    private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            FolderSheetHeader(
                caption: target.thisMac ? "ADD THIS MAC" : "ADD A MACHINE", title: "\(folderName) on \(target.name)",
                disabled: submitting
            ) { dismiss() }
            Form {
                HStack {
                    TextField(
                        "Directory", text: $path, prompt: Text(target.thisMac ? "~/Dieter/\(folderName)" : "/path")
                    )
                    .font(DieterFont.mono)
                    .onChange(of: path) { _, _ in plan = nil }
                    .accessibilityIdentifier("folders.attach.path")
                    Button("Choose…") { choose() }
                }
                Picker("Direction", selection: $mode) {
                    Text("Two-way").tag(Dieter_V1_FolderMode.twoWay)
                    Text("Upload only").tag(Dieter_V1_FolderMode.sendOnly)
                    Text("Download only").tag(Dieter_V1_FolderMode.receiveOnly)
                }
                .onChange(of: mode) { _, _ in plan = nil }
                Picker("Files already there", selection: $join) {
                    Text("Keep both where they differ").tag(Dieter_V1_FolderJoin.merge)
                    Text("The folder wins (differing files go to the trash)").tag(Dieter_V1_FolderJoin.adopt)
                }
                .onChange(of: join) { _, _ in plan = nil }
                if let plan { planSummary(plan) }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(DieterTheme.coral)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle(size: 30))
                if plan == nil {
                    Button("Review") { attach(dryRun: true) }
                        .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
                        .disabled(trimmedPath.isEmpty || submitting)
                        .accessibilityIdentifier("folders.attach.review")
                } else {
                    Button("Add \(target.thisMac ? "this Mac" : target.name)") { attach(dryRun: false) }
                        .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
                        .disabled(submitting)
                        .accessibilityIdentifier("folders.attach.add")
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .background(DieterTheme.background)
        .sheet(isPresented: $browsing) {
            if let machine = store.machine(forFolderDaemon: target.daemonID) {
                RemoteDirectoryBrowserSheet(
                    machineID: machine.id, mode: .existing, selection: $path, anyDirectory: true
                )
                .environment(store)
            }
        }
    }

    private func planSummary(_ plan: Dieter_V1_AttachFolderResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What happens").font(.system(size: 12, weight: .semibold))
            Text(
                "\(plan.adopt) files already match · \(plan.newFiles) new here · \(plan.conflicts) kept as conflict copies · \(plan.trash) moved to the trash"
            )
            .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
            ForEach(Array(plan.plan.prefix(6).enumerated()), id: \.offset) { _, entry in
                Text("\(entry.action): \(entry.path)").font(DieterFont.monoSmall).foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityIdentifier("folders.attach.plan")
    }

    /// This Mac: the open panel, so the path is one the local daemon can use. Another machine: its
    /// directory listing, as the projects flow browses it.
    private func choose() {
        guard target.thisMac else {
            browsing = true
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Keep Here"
        panel.message = "Choose the directory where this Mac keeps \(folderName)."
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func attach(dryRun: Bool) {
        submitting = true
        Task {
            let result = await model.attachDaemon(
                folderID: folderID, daemonID: target.daemonID, path: trimmedPath, mode: mode, join: join,
                dryRun: dryRun)
            submitting = false
            guard let result else { return }
            if dryRun { plan = result } else { dismiss() }
        }
    }
}
