import AppKit
import DieterClientAPI
import SwiftUI

/// The message list: the mailbox chooser, search and filters above the
/// shown mailbox in the core's date groups. Selecting a row reads it;
/// ⌘- and ⇧-click select several for the context menu's bulk actions.
struct MailListPane: View {
    let model: MailModel
    let openInWindow: (MailMessageKey) -> Void

    var body: some View {
        VStack(spacing: 0) {
            MailListHeader(model: model)
            if let error = model.error {
                DieterCallout(text: error, tint: DieterTheme.coral)
                    .padding(.horizontal, 12).padding(.bottom, 6)
                    .accessibilityIdentifier("mail.error")
            }
            if model.isEmpty {
                if model.slice.loading {
                    LoadFeedback(title: "Reading mail…")
                        .accessibilityIdentifier("mail.loading")
                } else {
                    MailEmptyState(title: model.slice.emptyTitle, detail: model.slice.emptyDetail)
                }
            } else {
                MailMessageList(model: model, openInWindow: openInWindow)
            }
            if model.box == .trash, !model.isEmpty {
                Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                HStack {
                    Spacer()
                    Button("Empty Trash", role: .destructive) { model.emptyTrashRequested = true }
                        .buttonStyle(DieterBarButtonStyle(destructive: true, size: 26))
                        .accessibilityIdentifier("mail.empty-trash")
                        .e2eTarget("mail.empty-trash")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .confirmationDialog(
            "Delete every message in the Trash for good?",
            isPresented: Binding(get: { model.emptyTrashRequested }, set: { model.emptyTrashRequested = $0 }),
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are deleted on every machine that holds them. This cannot be undone.")
        }
    }
}

/// "Inbox ▾" with its count, filters and Mark All as Read; then search.
private struct MailListHeader: View {
    let model: MailModel
    @State private var mailboxesPresented = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let slice = model.slice
        VStack(alignment: .leading, spacing: 8) {
            DieterPaneTopBar {
                Button {
                    mailboxesPresented.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: MailStyle.mailboxSymbol(slice.box)).font(.system(size: 12, weight: .medium))
                        Text(model.selectedBox?.title ?? "Inbox").font(.system(size: 13.5, weight: .semibold))
                        if let count = model.selectedBox?.countLabel, !count.isEmpty {
                            Text(count).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(DieterTheme.tertiary)
                    }
                    .foregroundStyle(DieterTheme.text)
                    .padding(.horizontal, 14).frame(height: DieterMetrics.capsuleHeight)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .dieterCapsuleChrome()
                .help("Choose a mailbox")
                .accessibilityLabel("Mailbox: \(model.selectedBox?.title ?? "Inbox")")
                .accessibilityIdentifier("mail.mailbox")
                .e2eTarget("mail.mailbox", text: model.selectedBox?.title ?? "Inbox")
                .popover(isPresented: $mailboxesPresented, arrowEdge: .bottom) {
                    MailboxChooser(model: model) { mailboxesPresented = false }
                }
            } trailing: {
                MailFilterMenu(model: model)
                Button {
                    Task { await model.markAllRead() }
                } label: {
                    Image(systemName: "envelope.open").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle))
                .disabled((model.selectedBox?.unread ?? 0) == 0)
                .help("Mark All as Read")
                .accessibilityLabel("Mark all as read")
                .accessibilityIdentifier("mail.mark-all-read")
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                TextField("Search mail", text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(DieterTheme.text)
                    .focused($searchFocused)
                    .onExitCommand { searchText = "" }
                    .accessibilityLabel("Search mail")
                    .accessibilityIdentifier("mail.search")
                    .e2eTarget("mail.search")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 11).frame(height: 30)
            .dieterCapsuleChrome(interactive: false)
            .padding(.leading, 14).padding(.trailing, 8)
        }
        .padding(.bottom, 8)
        .onAppear { searchText = model.searchText }
        .onChange(of: searchText) { _, value in model.updateSearch(value) }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
    }
}

/// Inbox, Flagged, Unread, Archive and Trash with the core's counts.
private struct MailboxChooser: View {
    let model: MailModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(model.slice.boxes, id: \.box) { row in
                if row.box == .archive { Divider().padding(.vertical, 3) }
                MailboxChooserRow(row: row) {
                    dismiss()
                    Task { await model.selectBox(row.box) }
                }
            }
        }
        .padding(6)
        .frame(width: 220)
    }
}

private struct MailboxChooserRow: View {
    let row: ClientMailBoxRow
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 9) {
                Image(systemName: MailStyle.mailboxSymbol(row.box)).frame(width: 17)
                    .foregroundStyle(DieterTheme.subtle)
                Text(row.title).foregroundStyle(DieterTheme.text)
                Spacer(minLength: 6)
                if !row.countLabel.isEmpty {
                    Text(row.countLabel).monospacedDigit().foregroundStyle(DieterTheme.tertiary)
                }
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DieterTheme.action)
                    .opacity(row.selected ? 1 : 0)
            }
            .font(.system(size: 12.5, weight: row.selected ? .semibold : .regular))
            .padding(.horizontal, 9).frame(height: 28)
            .background(
                hovering ? DieterTheme.tileHover : .clear,
                in: RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(row.selected ? .isSelected : [])
        .accessibilityIdentifier("mail.mailbox.\(MailStyle.mailboxIdentifier(row.box))")
        .e2eTarget("mail.mailbox.\(MailStyle.mailboxIdentifier(row.box))", text: row.title)
    }
}

/// Projects, machines and senders from the mail on hand, Important only,
/// and Clear.
private struct MailFilterMenu: View {
    let model: MailModel

    var body: some View {
        let slice = model.slice
        Menu {
            section("Projects", options: slice.projects, dimension: .project)
            section("Machines", options: slice.machines, dimension: .machine)
            section("Senders", options: slice.senders, dimension: .sender)
            Toggle(
                "Important Only",
                isOn: Binding(
                    get: { slice.filter.importantOnly },
                    set: { on in Task { await model.setImportantOnly(on) } }))
            Divider()
            Button("Clear Filters") { Task { await model.clearFilters() } }
                .disabled(!model.hasFilter)
        } label: {
            DieterMenuLabel(
                symbol: model.hasFilter
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .dieterMenuChrome(.circle, prominent: model.hasFilter)
        .help("Filter mail")
        .accessibilityLabel("Filter mail")
        .accessibilityIdentifier("mail.filter")
    }

    @ViewBuilder
    private func section(
        _ title: String, options: [ClientMailFilterOption], dimension: MailFilterDimension
    ) -> some View {
        if !options.isEmpty {
            Section(title) {
                ForEach(options, id: \.id) { option in
                    Toggle(
                        option.title,
                        isOn: Binding(
                            get: { option.selected },
                            set: { _ in Task { await model.toggleFilter(dimension, id: option.id) } }))
                }
            }
        }
    }
}

/// The shown mailbox in a native list: date groups with sticky headers,
/// multiple selection, the reading pane's actions in the context menu,
/// Delete to move to the Trash and a double-click to open a window.
private struct MailMessageList: View {
    let model: MailModel
    let openInWindow: (MailMessageKey) -> Void

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.setSelection($0) })) {
            ForEach(model.slice.sections, id: \.id) { section in
                Section {
                    ForEach(section.rows, id: \.key) { row in
                        MailRowView(row: row)
                            .equatable()
                            .tag(row.key)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6))
                    }
                } header: {
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .accessibilityIdentifier("mail.section.\(section.id)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: MailMessageKey.self) { keys in
            MailActionsMenu(model: model, keys: model.orderedKeys.filter(keys.contains), openInWindow: openInWindow)
        } primaryAction: { keys in
            if keys.count == 1, let key = keys.first { openInWindow(key) }
        }
        .onDeleteCommand { Task { await model.delete(model.targets) } }
        .accessibilityIdentifier("mail.list")
        .e2eTarget("mail.list")
    }
}

/// The reading pane's actions for the rows a context menu targets.
struct MailActionsMenu: View {
    let model: MailModel
    let keys: [MailMessageKey]
    let openInWindow: ((MailMessageKey) -> Void)?

    var body: some View {
        if !keys.isEmpty {
            let read = model.all(keys, \.read)
            let flagged = model.all(keys, \.flagged)
            let archived = model.all(keys, \.archived)
            let trashed = model.all(keys, \.trashed)
            if keys.count == 1, let key = keys.first, let openInWindow {
                Button("Open in New Window") { openInWindow(key) }
                Divider()
            }
            Button(read ? "Mark as Unread" : "Mark as Read") { Task { await model.toggleRead(keys) } }
            Button(flagged ? "Unflag" : "Flag") { Task { await model.toggleFlag(keys) } }
            Divider()
            if archived || trashed {
                Button("Move to Inbox") { Task { await model.moveToInbox(keys) } }
            }
            if !archived {
                Button("Archive") { Task { await model.archive(keys) } }
            }
            Button(trashed ? "Delete Permanently…" : "Delete", role: .destructive) {
                Task { await model.delete(keys) }
            }
        }
    }
}

/// A row as in Mail: the blue unread bar, the sender's avatar, the sender
/// (bold while unread) with the time, importance and flag, the subject and
/// two lines of preview; a stale row dims and says why.
struct MailRowView: View, Equatable {
    let row: ClientMailRow
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let emphasized = prominence == .increased
        let primary = emphasized ? Color.white : Color.primary
        let secondary = emphasized ? Color.white.opacity(0.85) : Color.secondary
        let weight: Font.Weight = row.read ? .regular : .semibold
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 9) {
                MailAvatar(row: row, size: 30, emphasized: emphasized).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(row.sender).font(.system(size: 12.5, weight: weight)).foregroundStyle(primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if row.important {
                            Text("!").font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(emphasized ? Color.white : MailStyle.important)
                                .accessibilityHidden(true)
                        }
                        if row.flagged {
                            Image(systemName: "flag.fill").font(.system(size: 9.5))
                                .foregroundStyle(emphasized ? Color.white : MailStyle.flag)
                                .accessibilityHidden(true)
                        }
                        Text(row.timeLabel).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(secondary)
                            .lineLimit(1).fixedSize()
                    }
                    Text(row.subject).font(.system(size: 12, weight: weight)).foregroundStyle(primary).lineLimit(1)
                    Text(row.preview).font(.system(size: 11.5)).foregroundStyle(secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(row.stale.isEmpty ? 1 : 0.6)
            if !row.stale.isEmpty {
                MailStaleNote(text: row.stale, tint: emphasized ? Color.white : nil)
                    .padding(.leading, 39)
            }
        }
        .padding(.leading, 11).padding(.vertical, 7)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(row.read ? Color.clear : (emphasized ? Color.white : MailStyle.unread))
                .frame(width: 3)
                .padding(.vertical, 5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("mail.row.\(row.ref.id)")
        .e2eTarget("mail.row.\(row.ref.id)", text: row.subject)
    }

    nonisolated static func == (lhs: MailRowView, rhs: MailRowView) -> Bool { lhs.row == rhs.row }
}

private struct MailEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DieterTheme.shell)
                .frame(width: 60, height: 60)
                .background(DieterTheme.shell.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
                .multilineTextAlignment(.center).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mail.empty")
        .e2eTarget("mail.empty", text: title)
    }
}
