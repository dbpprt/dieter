import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ArchivePolicySheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var policy = "never"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Done retention").font(.title2.weight(.bold))
            Text("Automatically archive cards that remain in Done. Scheduled occurrence history stays authoritative.")
                .foregroundStyle(.secondary)
            Picker("Archive done cards", selection: $policy) {
                ForEach(DoneArchivePolicy.allCases) { option in Text(option.title).tag(option.rawValue) }
            }.pickerStyle(.radioGroup)
            HStack {
                Spacer(); Button("Cancel") { dismiss() };
                Button("Save") { Task { await store.setArchivePolicy(policy) } }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 500).onAppear { policy = store.selectedBoard?.doneArchivePolicy ?? "never" }
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
