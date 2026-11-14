import DieterAPI
import DieterClientAPI
import SwiftUI

/// Settings › Folders: the Mac syncs through the daemon running on it, so this page has no
/// interval, network or power settings. For each folder it shows whether this Mac keeps a copy
/// and edits that daemon member's settings in place; a Mac without a daemon gets a hint.
struct FolderSettingsPage: View {
    @Environment(DieterStore.self) private var store
    @State private var adding: FolderAttachTarget?
    @State private var addingFolder: ClientFolderRow?

    var body: some View {
        let model = store.foldersModel
        SettingsPage {
            VStack(spacing: 14) {
                if let daemonID = store.localFolderDaemonID {
                    if let error = model.errorMessage {
                        DieterCallout(text: error, tint: DieterTheme.coral)
                    }
                    if model.list.folders.isEmpty {
                        SettingsPanel(title: "Folders") {
                            Text(model.list.loading ? "Reading folders…" : "No folders yet. Create one in Folders.")
                                .font(.caption).foregroundStyle(DieterTheme.tertiary)
                        }
                    }
                    ForEach(model.list.folders, id: \.id) { row in
                        FolderOnThisMacPanel(model: model, row: row, daemonID: daemonID) {
                            addingFolder = row
                            adding = FolderAttachTarget(daemonID: daemonID, name: "This Mac", thisMac: true)
                        }
                    }
                } else {
                    SettingsPanel(title: "This Mac") {
                        Text("Install the Dieter daemon on this Mac to keep a copy of your folders here.")
                            .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
                            .accessibilityIdentifier("settings.folders.no-daemon")
                    }
                }
                SettingsPanel(title: "How it works") {
                    Text(
                        "This Mac keeps a folder through the Dieter daemon running here, which syncs it with your other machines and phones. The app manages folders and reveals this Mac's copy in Finder."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Which folders the daemon here keeps, with its paths and limits.
            .task(id: [store.localFolderDaemonID ?? ""] + model.list.folders.map(\.id)) {
                guard let daemonID = store.localFolderDaemonID else { return }
                await model.refreshLocal(daemonID: daemonID)
            }
        }
        .sheet(
            isPresented: Binding(get: { adding != nil && addingFolder != nil }, set: { if !$0 { adding = nil } })
        ) {
            if let adding, let addingFolder {
                AttachMemberSheet(
                    model: model, folderID: addingFolder.id, folderName: addingFolder.name, target: adding
                )
                .environment(store)
            }
        }
    }
}

/// One folder: this Mac's copy with its member settings, or a way to add this Mac.
private struct FolderOnThisMacPanel: View {
    let model: FoldersModel
    let row: ClientFolderRow
    let daemonID: String
    let add: () -> Void

    /// Full rescan intervals the daemon offers.
    private static let rescanChoices: [(Int32, String)] = [
        (900, "Every 15 min"), (3_600, "Every hour"), (21_600, "Every 6 hours"), (86_400, "Every 24 hours"),
    ]
    /// Bytes per second; zero is unlimited.
    private static let bandwidthChoices: [(Int64, String)] = [
        (0, "Unlimited"), (1_048_576, "1 MB/s"), (5_242_880, "5 MB/s"), (10_485_760, "10 MB/s"),
        (52_428_800, "50 MB/s"),
    ]

    var body: some View {
        let member = model.member(folderID: row.id, daemonID: daemonID)
        SettingsPanel(title: row.name, subtitle: member == nil ? row.status : "On this Mac · \(row.status)") {
            if let member {
                memberSettings(member)
            } else if model.notOnThisMac.contains(row.id) {
                HStack {
                    Text("This Mac keeps no copy of this folder.").font(.system(size: 12))
                        .foregroundStyle(DieterTheme.subtle)
                    Spacer()
                    Button("Add this Mac…", action: add).buttonStyle(DieterBarButtonStyle(size: 26))
                        .accessibilityIdentifier("settings.folders.add.\(row.id)")
                }
            } else {
                Text(model.refreshingLocal ? "Asking the daemon on this Mac…" : "Not read yet.")
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
            }
        }
        .accessibilityIdentifier("settings.folders.\(row.id)")
    }

    @ViewBuilder
    private func memberSettings(_ member: Dieter_V1_FolderMember) -> some View {
        HStack(spacing: 8) {
            Text(member.path).font(DieterFont.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            if let url = FileExternalActions.localDirectory(verifiedLocal: true, path: member.path) {
                Button("Reveal in Finder") { FileExternalActions.reveal(url) }
                    .buttonStyle(DieterBarButtonStyle(size: 26))
            }
        }
        Picker("Direction", selection: binding(member.mode) { $0.mode = $1 }) {
            Text("Two-way").tag(Dieter_V1_FolderMode.twoWay)
            Text("Upload only").tag(Dieter_V1_FolderMode.sendOnly)
            Text("Download only").tag(Dieter_V1_FolderMode.receiveOnly)
        }
        Toggle("Paused", isOn: binding(member.paused) { $0.paused = $1 }).toggleStyle(.switch)
        Toggle("Watch for changes", isOn: binding(member.watch) { $0.watch = $1 }).toggleStyle(.switch)
        Picker("Full rescan", selection: binding(rescan(member)) { $0.rescanSeconds = $1 }) {
            ForEach(Self.rescanChoices, id: \.0) { Text($0.1).tag($0.0) }
        }
        Picker("Bandwidth limit", selection: binding(bandwidth(member)) { $0.bandwidthLimit = $1 }) {
            ForEach(Self.bandwidthChoices, id: \.0) { Text($0.1).tag($0.0) }
        }
        Stepper(
            "Transfers at once: \(member.concurrency > 0 ? member.concurrency : 4)",
            value: binding(member.concurrency > 0 ? member.concurrency : 4) { $0.concurrency = $1 }, in: 1...8)
        Toggle("Quarantine files from other devices", isOn: binding(member.quarantine) { $0.quarantine = $1 })
            .toggleStyle(.switch)
            .help("Gatekeeper checks files that arrive from another device before they open, as with AirDrop.")
    }

    /// The listed choice nearest to the daemon's interval, so an unlisted value still shows.
    private func rescan(_ member: Dieter_V1_FolderMember) -> Int32 {
        let seconds = member.rescanSeconds > 0 ? member.rescanSeconds : 3_600
        return Self.rescanChoices.min { abs($0.0 - seconds) < abs($1.0 - seconds) }?.0 ?? 3_600
    }

    private func bandwidth(_ member: Dieter_V1_FolderMember) -> Int64 {
        Self.bandwidthChoices.min { abs($0.0 - member.bandwidthLimit) < abs($1.0 - member.bandwidthLimit) }?.0 ?? 0
    }

    private func binding<Value: Equatable & Sendable>(
        _ value: Value, _ set: @escaping (inout ClientFolderUpdateDaemon, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { value },
            set: { next in
                guard next != value else { return }
                Task { await model.updateDaemon(folderID: row.id, daemonID: daemonID) { set(&$0, next) } }
            })
    }
}
