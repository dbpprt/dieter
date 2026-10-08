import SwiftUI

struct ArchiveView: View {
    @Environment(DieterStore.self) private var store
    @State private var scope = "Cards"

    private var itemCount: Int {
        switch scope {
        case "Chats": store.chats.filter(\.archived).count
        case "Projects": store.archivedProjects.count
        default: store.archivedCards.count
        }
    }

    var body: some View {
        DieterSectionScaffold {
            DieterTitleCapsule(
                title: "Archive", count: itemCount, symbol: "archivebox",
                detail: "archived \(scope.lowercased())")
            DieterSegmentTrack {
                ForEach(["Cards", "Chats", "Projects"], id: \.self) { item in
                    Button(item) { scope = item }
                        .buttonStyle(DieterSegmentStyle(selected: scope == item))
                        .accessibilityIdentifier("archive.scope.\(item.lowercased())")
                }
            }
            .fixedSize()
        } trailing: {
            Button {
                Task { await store.loadArchive() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle))
            .help("Refresh archive")
        } content: {
            VStack(spacing: 0) {
                if store.archiveLoading || store.archiveError != nil {
                    LoadFeedback(
                        title: "Loading archive…", error: store.archiveError,
                        retry: { Task { await store.loadArchive() } }, compact: true)
                }
                List {
                    if scope == "Cards" {
                        ForEach(store.archivedCards, id: \.id) { card in
                            ArchiveRow(title: card.title, detail: card.summary) {
                                Task {
                                    await store.archive(card, archived: false); await store.loadArchive()
                                }
                            }
                        }
                    } else if scope == "Chats" {
                        ForEach(store.chats.filter(\.archived), id: \.id) { card in
                            ArchiveRow(title: card.title, detail: card.updatedAt) {
                                Task {
                                    await store.archive(card, archived: false); await store.loadArchive()
                                }
                            }
                        }
                    } else {
                        ForEach(store.archivedProjects, id: \.id) { project in
                            ArchiveRow(title: project.name, detail: project.path) {
                                Task { await store.setProjectArchived(id: project.id, archived: false) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await store.loadArchive() }
    }
}

/// One archived item and its Restore action.
private struct ArchiveRow: View {
    @Environment(DieterStore.self) private var store
    let title: String
    let detail: String
    let restore: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(DieterTheme.tertiary).lineLimit(2)
            }
            Spacer()
            Button("Restore", action: restore)
                .buttonStyle(DieterBarButtonStyle(size: 28))
                .disabled(!store.phase.isConnected)
        }
        .padding(11)
        .dieterTile()
        .listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}
