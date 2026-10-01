import DieterAPI
import Foundation
import SharedCore
import SwiftUI

struct SharedConflictsButton: View {
    let keys: [String]
    @State private var presented = false
    var body: some View {
        if !keys.isEmpty {
            Button("Resolve shared edits (\(keys.count))") { presented = true }
                .sheet(isPresented: $presented) { SharedConflictsView(keys: keys) }
        }
    }
}

private struct SharedConflictsView: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let keys: [String]
    @State private var records: [Dieter_V1_PeerRecord] = []
    @State private var error = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                ForEach(records, id: \.id) { record in
                    Section(record.id.split(separator: ".").last.map(String.init) ?? record.id) {
                        Text(
                            "These edits were made independently. Choose the value to keep, then edit it normally if needed."
                        )
                        .foregroundStyle(.secondary)
                        ForEach(Array(record.versions.enumerated()), id: \.offset) { _, version in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(display(version)).textSelection(.enabled)
                                Button(version.deleted ? "Keep deletion" : "Keep this value") {
                                    Task { await resolve(record, version) }
                                }.disabled(saving)
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("Resolve shared edits")
            .toolbar { Button("Done") { dismiss() } }
        }.frame(width: 600, height: 500)
            .task { await load() }
    }

    private func display(_ value: Dieter_V1_PeerVersion) -> String {
        if value.deleted { return "Deleted" }
        if let string = try? JSONDecoder().decode(String.self, from: value.valueJson) { return string }
        return String(data: value.valueJson, encoding: .utf8) ?? "Unavailable value"
    }
    /// The competing versions, read from the project's replica.
    private func load() async {
        let projectID = store.selectedProjectID
        do {
            var loaded: [Dieter_V1_PeerRecord] = []
            for key in keys where key.contains("/") {
                let conflict = try await store.administer {
                    $0.conflict = .with {
                        $0.projectID = projectID
                        $0.key = key
                    }
                }.conflict
                if conflict.hasRecord { loaded.append(conflict.record) }
            }
            records = loaded
        } catch { self.error = (error as? CoreFailure)?.message ?? error.localizedDescription }
    }
    /// Keeps one version, or the deletion, on the replica that served it.
    private func resolve(_ record: Dieter_V1_PeerRecord, _ version: Dieter_V1_PeerVersion) async {
        saving = true; defer { saving = false }
        let projectID = store.selectedProjectID
        do {
            _ = try await store.administer {
                $0.resolveConflict = .with {
                    $0.projectID = projectID
                    $0.record = record
                    $0.valueJson = version.valueJson
                    $0.deleted = version.deleted
                }
            }
            await store.refreshState(); await load()
        } catch { self.error = (error as? CoreFailure)?.message ?? error.localizedDescription }
    }
}
