import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct RemoteDirectoryBrowserSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let machineID: String
    let mode: ProjectSetupMode
    @Binding var selection: String
    @State private var listing: Dieter_V1_DirectoryListing?
    @State private var pathField = ""
    @State private var loading = false
    @State private var showHidden = false
    @State private var errorMessage = ""
    @State private var newFolderName = ""
    @State private var activeLoadID = UUID()

    private var machine: DieterEndpoint? {
        store.machines.first { $0.id == machineID } ?? (store.endpoint.id == machineID ? store.endpoint : nil)
    }
    private var entries: [Dieter_V1_DirectoryEntry] {
        (listing?.entries ?? []).filter { showHidden || !$0.hidden }
    }
    private var separator: String { listing?.separator.isEmpty == false ? listing!.separator : "/" }
    private var newProjectPath: String {
        RemoteProjectPath.joining(
            listing?.path ?? "", newFolderName.trimmingCharacters(in: .whitespacesAndNewlines), separator: separator)
    }
    private var newFolderExists: Bool {
        listing?.entries.contains {
            $0.name.localizedCaseInsensitiveCompare(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines))
                == .orderedSame
        } == true
    }
    private var canUseSelection: Bool {
        switch mode {
        case .existing:
            listing?.gitRepository == true
        case .newRepository:
            listing != nil && RemoteProjectPath.validDirectoryName(newFolderName) && !newFolderExists
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                    .frame(width: 36, height: 36).background(
                        DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .existing ? "Choose a Git working tree" : "Choose where to create the project")
                        .font(.system(size: 17, weight: .bold))
                    Text("Browsing \(machine?.name ?? "remote machine") · rendered locally")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(18)

            Divider().overlay(DieterTheme.border)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("LOCATIONS").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                        .padding(.horizontal, 9).padding(.bottom, 3)
                    ForEach(listing?.locations ?? [], id: \.path) { location in
                        Button {
                            Task { await load(location.path) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: locationSymbol(location.kind)).frame(width: 15)
                                Text(location.name).lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                            .padding(.horizontal, 9).frame(height: 30)
                            .background(
                                listing?.path == location.path ? DieterTheme.raised : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    Toggle("Show hidden folders", isOn: $showHidden).toggleStyle(.checkbox).font(.caption)
                        .foregroundStyle(DieterTheme.subtle)
                }
                .padding(12).frame(width: 165).background(DieterTheme.sidebar)

                Divider().overlay(DieterTheme.border)

                VStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Button {
                            if let parent = listing?.parent, !parent.isEmpty { Task { await load(parent) } }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(DieterIconButtonStyle()).disabled(listing?.parent.isEmpty != false || loading)
                        TextField("Path on \(machine?.name ?? "machine")", text: $pathField)
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DieterTheme.strongBorder))
                            .onSubmit { Task { await load(pathField) } }
                        Button("Go") { Task { await load(pathField) } }.buttonStyle(DieterSecondaryButtonStyle())
                            .disabled(loading)
                    }

                    if !errorMessage.isEmpty {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorMessage).lineLimit(2)
                            Spacer()
                        }
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                    }

                    ScrollView {
                        LazyVStack(spacing: 3) {
                            if entries.isEmpty, !loading {
                                ContentUnavailableView(
                                    "No folders", systemImage: "folder",
                                    description: Text("This directory has no visible subfolders.")
                                )
                                .padding(.top, 45)
                            }
                            ForEach(entries, id: \.path) { entry in
                                Button {
                                    Task { await load(entry.path) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(
                                            systemName: entry.gitRepository ? "folder.badge.gearshape" : "folder.fill"
                                        )
                                        .foregroundStyle(entry.gitRepository ? DieterTheme.eyes : DieterTheme.shell)
                                        .frame(width: 19)
                                        Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Spacer()
                                        if entry.gitRepository {
                                            Text("Git repository").font(.caption2.weight(.semibold)).foregroundStyle(
                                                DieterTheme.eyes
                                            )
                                            .padding(.horizontal, 7).padding(.vertical, 3).background(
                                                DieterTheme.eyes.opacity(0.1), in: Capsule())
                                        }
                                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(DieterTheme.tertiary)
                                    }
                                    .foregroundStyle(DieterTheme.subtle).padding(.horizontal, 11).frame(height: 36)
                                    .background(
                                        DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(DieterTheme.border)
            VStack(alignment: .leading, spacing: 9) {
                if mode == .newRepository {
                    HStack(spacing: 9) {
                        Text("New folder").font(.caption.weight(.semibold)).foregroundStyle(DieterTheme.subtle)
                        TextField("project", text: $newFolderName)
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DieterTheme.strongBorder))
                            .accessibilityIdentifier("new-project.browser-folder-name")
                        Text(newProjectPath)
                            .font(.caption2.monospaced()).foregroundStyle(DieterTheme.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if newFolderExists {
                        Label(
                            "A folder with this name already exists. Choose it in Existing Git repo or use another name.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                    }
                }

                HStack {
                    if mode == .existing {
                        if listing?.gitRepository == true {
                            Label(
                                "\(listing?.name ?? "Folder") is a Git working tree",
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(.caption).foregroundStyle(DieterTheme.eyes)
                        } else {
                            Text("Open a folder containing a .git directory or linked-worktree .git file to select it.")
                                .font(.caption).foregroundStyle(DieterTheme.tertiary)
                        }
                    } else if !newFolderExists, RemoteProjectPath.validDirectoryName(newFolderName) {
                        Label("The project will be created at \(newProjectPath)", systemImage: "folder.badge.plus")
                            .font(.caption).foregroundStyle(DieterTheme.eyes)
                    } else {
                        Text("Choose a parent directory and enter a new folder name.")
                            .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                    Button(mode == .existing ? "Use this working tree" : "Use this path") {
                        selection = mode == .existing ? (listing?.path ?? "") : newProjectPath
                        dismiss()
                    }
                    .buttonStyle(DieterPrimaryButtonStyle()).disabled(!canUseSelection)
                    .accessibilityIdentifier("new-project.browser-use")
                }
            }
            .padding(14)
        }
        .frame(width: 720, height: 560)
        .background(DieterTheme.background)
        .task { await prepareInitialLocation() }
    }

    private func prepareInitialLocation() async {
        guard mode == .newRepository else {
            await load(selection)
            return
        }
        let components = RemoteProjectPath.parentAndName(selection)
        newFolderName = components.name
        await load(components.parent)
    }

    private func load(_ path: String) async {
        let loadID = UUID()
        activeLoadID = loadID
        loading = true
        errorMessage = ""
        do {
            let value = try await store.listProjectDirectories(path: path, machineID: machineID)
            guard activeLoadID == loadID else { return }
            listing = value
            pathField = value.path
        } catch {
            guard activeLoadID == loadID else { return }
            errorMessage = error.localizedDescription
        }
        if activeLoadID == loadID { loading = false }
    }

    private func locationSymbol(_ kind: String) -> String {
        switch kind {
        case "home": "house.fill"
        case "code": "chevron.left.forwardslash.chevron.right"
        case "computer": "desktopcomputer"
        default: "folder"
        }
    }
}
