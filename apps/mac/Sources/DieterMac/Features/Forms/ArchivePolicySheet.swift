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
    @State private var remotePublishMode = RemotePublishMode.manual.rawValue
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

            Picker("Settings section", selection: $selectedTab) {
                Text("General").tag("general")
                Text("Browser routing").tag("routing")
            }
            .pickerStyle(.segmented)
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
                                ForEach(RemotePublishMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                            }
                            Text(RemotePublishMode(rawValue: remotePublishMode)?.detail ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Section("Completed cards") {
                            Picker("Archive done cards", selection: $policy) {
                                ForEach(DoneArchivePolicy.allCases) { option in Text(option.title).tag(option.rawValue)
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
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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
                Button("Cancel") { dismiss() }.buttonStyle(.glass).disabled(saving)
                    .keyboardShortcut(.cancelAction)
                    .smokeTarget("board.settings.cancel")
                Button(saving ? "Saving…" : "Save changes") { Task { await save() } }
                    .buttonStyle(.glassProminent)
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
                ? store.selectedBoard!.remotePublishMode : RemotePublishMode.manual.rawValue
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
enum BoardWorkflow: String, CaseIterable, Identifiable {
    case review
    case direct

    var id: String { rawValue }
    var title: String { self == .review ? "With review" : "Direct to done" }
    var laneDescription: String {
        self == .review ? "Todo → Running → Review → Done" : "Todo → Running → Done"
    }
}

enum DoneArchivePolicy: String, CaseIterable, Identifiable {
    case never
    case immediately
    case afterOneDay = "after_1_day"
    case afterSevenDays = "after_7_days"
    case afterThirtyDays = "after_30_days"
    case afterNinetyDays = "after_90_days"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: "Never"
        case .immediately: "Immediately"
        case .afterOneDay: "After 1 day"
        case .afterSevenDays: "After 7 days"
        case .afterThirtyDays: "After 30 days"
        case .afterNinetyDays: "After 90 days"
        }
    }
}
