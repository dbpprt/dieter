import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ArchivePolicySheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var policy = "never"
    @State private var baseRemote = ""
    @State private var remotePublishMode = RemotePublishMode.manual.rawValue
    @State private var saving = false
    @State private var browserURLs = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Board settings").font(.title2.weight(.bold))
            Text("Choose how new conversations publish Git work and when completed cards are archived.")
                .foregroundStyle(.secondary)
            Text("Browser URLs or hostnames").font(.headline)
            TextEditor(text: $browserURLs).frame(height: 70)
                .accessibilityIdentifier("board.hostnames")
            Text("One per line. Routing uses the exact hostname, across all URL paths and ports.").font(
                .caption
            ).foregroundStyle(.secondary)
            if let saveError { Text(saveError).foregroundStyle(.orange) }
            TextField("Default Git remote", text: $baseRemote)
            Picker("Remote publishing", selection: $remotePublishMode) {
                ForEach(RemotePublishMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
            }
            Text(RemotePublishMode(rawValue: remotePublishMode)?.detail ?? "")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Archive done cards", selection: $policy) {
                ForEach(DoneArchivePolicy.allCases) { option in Text(option.title).tag(option.rawValue) }
            }.pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saving ? "Saving…" : "Save") { Task { await save() } }.buttonStyle(
                    .borderedProminent
                ).disabled(saving)
            }
        }.padding(24).frame(width: 520).onAppear {
            browserURLs = store.selectedBoard?.hostnames.joined(separator: "\n") ?? ""
            policy = store.selectedBoard?.doneArchivePolicy ?? "never"
            let boardRemote = store.selectedBoard?.baseRemote ?? ""
            baseRemote = boardRemote.isEmpty ? (store.selectedProject?.baseRemote ?? "") : boardRemote
            remotePublishMode =
                store.selectedBoard?.remotePublishMode.isEmpty == false
                ? store.selectedBoard!.remotePublishMode : RemotePublishMode.manual.rawValue
        }
    }

    private func save() async {
        saving = true
        saveError = nil
        let hosts = browserURLs.split(whereSeparator: { $0.isNewline }).map {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return CaptureBrowserContext.hostname(value) ?? value
        }.filter { !$0.isEmpty }
        do { try await store.updateBoardHostnames(hosts) } catch {
            saveError = error.localizedDescription
            saving = false
            return
        }
        guard await store.updateBoardGitSettings(remote: baseRemote, publishMode: remotePublishMode)
        else {
            saving = false
            return
        }
        await store.setArchivePolicy(policy)
        saving = false
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
