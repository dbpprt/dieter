import DieterAPI
import Foundation
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
                        Text("These edits were made independently. Choose the value to keep, then edit it normally if needed.")
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
    private func load() async {
        guard let rpc = store.rpc else { return }
        do {
            var loaded: [Dieter_V1_PeerRecord] = []
            for key in keys {
                let parts = key.split(separator: "/", maxSplits: 1)
                guard parts.count == 2 else { continue }
                var request = Dieter_V1_PeerRecordRef(); request.kind = String(parts[0]); request.id = String(parts[1])
                let record = try await rpc.peerRecord(request)
                if record.versions.count > 1 { loaded.append(record) }
            }
            records = loaded
        } catch { self.error = DieterRPCFailure.message(for: error) }
    }
    private func resolve(_ record: Dieter_V1_PeerRecord, _ version: Dieter_V1_PeerVersion) async {
        guard let rpc = store.rpc else { return }
        saving = true; defer { saving = false }
        var request = Dieter_V1_PutPeerRecordRequest()
        request.kind = record.kind; request.id = record.id; request.expectedRevision = record.revision
        request.deleted = version.deleted; request.valueJson = version.valueJson
        do {
            _ = try await rpc.putPeerRecord(request)
            await store.refreshState(); await load()
        } catch { self.error = DieterRPCFailure.message(for: error) }
    }
}
