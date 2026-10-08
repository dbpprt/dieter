import AppKit
import DieterAPI
import SwiftUI

struct ArchivePolicySheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "general"
    @State private var boardName = ""
    @State private var policy = "never"
    @State private var baseRemote = ""
    @State private var remotePublishMode = AdminChoices.options.defaultPublishMode
    @State private var browserURLs = ""
    @State private var initialized = false
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Board settings").font(.title2.weight(.semibold))
                    Text("\(store.selectedProject?.name ?? "Project") · \(store.selectedBoard?.name ?? "Board")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)

            DieterSegmentedPicker(
                "Settings section", selection: $selectedTab, options: ["general", "routing"], fillsWidth: true
            ) { $0 == "general" ? "General" : "Browser routing" }
            .accessibilityIdentifier("board.settings.sections")
            .smokeTarget("board.settings.sections")
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            Group {
                if selectedTab == "general" {
                    Form {
                        Section("Board") {
                            TextField("Name", text: $boardName)
                                .accessibilityIdentifier("board.settings.name")
                                .smokeTarget("board.settings.name")
                        }
                        Section("New conversations") {
                            TextField("Default Git remote", text: $baseRemote)
                            Picker("Remote publishing", selection: $remotePublishMode) {
                                ForEach(AdminChoices.options.publishModes, id: \.id) { mode in
                                    Text(mode.title).tag(mode.id)
                                }
                            }
                            Text(
                                AdminChoices.choice(remotePublishMode, in: AdminChoices.options.publishModes)?.detail
                                    ?? ""
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Section("Completed cards") {
                            Picker("Archive done cards", selection: $policy) {
                                ForEach(AdminChoices.options.archivePolicies, id: \.id) { option in
                                    Text(option.title).tag(option.id)
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                } else {

                    Form {
                        Section("Browser routing") {
                            Text("Browser URLs or hostnames with optional ports")
                            TextEditor(text: $browserURLs)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 140)
                                .dieterInset(radius: 8)
                                .accessibilityIdentifier("board.hostnames")
                                .smokeTarget("board.hostnames")
                            Text(
                                "One per line. Include a port to match a specific app, such as localhost:4018. Without a port, the hostname matches any port. URL paths are ignored."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .disabled(saving)

            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(.orange).padding(.horizontal, 24)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle()).disabled(saving)
                    .keyboardShortcut(.cancelAction)
                    .smokeTarget("board.settings.cancel")
                Button(saving ? "Saving…" : "Save changes") { Task { await save() } }
                    .buttonStyle(DieterBarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        saving || boardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(20)
        }
        .frame(width: 620, height: 540)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            boardName = store.selectedBoard?.name ?? ""
            browserURLs = store.selectedBoard?.hostnames.joined(separator: "\n") ?? ""
            policy = store.selectedBoard?.doneArchivePolicy ?? "never"
            let boardRemote = store.selectedBoard?.baseRemote ?? ""
            baseRemote = boardRemote.isEmpty ? (store.selectedProject?.baseRemote ?? "") : boardRemote
            remotePublishMode =
                store.selectedBoard?.remotePublishMode.isEmpty == false
                ? store.selectedBoard!.remotePublishMode : AdminChoices.options.defaultPublishMode
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        guard let board = store.selectedBoard else { return }
        let name = boardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        saving = true
        defer { saving = false }
        saveError = nil
        if name != board.name, !(await store.renameBoard(id: board.id, name: name)) {
            saveError = "The board could not be renamed. Please try again."
            return
        }
        let hosts = browserURLs.split(whereSeparator: { $0.isNewline }).map {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return CaptureBrowserContext.hostname(value) ?? value
        }.filter { !$0.isEmpty }
        do { try await store.updateBoardHostnames(hosts) } catch {
            saveError = error.localizedDescription
            return
        }
        guard await store.updateBoardGitSettings(remote: baseRemote, publishMode: remotePublishMode) else {
            saveError = "Board Git settings could not be saved. Your edits are still here."
            return
        }
        await store.setArchivePolicy(policy)
    }
}
