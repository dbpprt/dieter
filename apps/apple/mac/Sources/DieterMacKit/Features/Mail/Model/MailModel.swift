import DieterClientAPI
import Foundation
import Observation

/// One message on one machine, as the list's selection and the message
/// windows identify it.
struct MailMessageKey: Hashable, Codable, Sendable, CustomStringConvertible {
    let daemonID: String
    let id: String

    init(daemonID: String, id: String) {
        self.daemonID = daemonID
        self.id = id
    }

    init(_ ref: ClientMailMessageRef) {
        self.init(daemonID: ref.daemonID, id: ref.id)
    }

    var ref: ClientMailMessageRef {
        .with {
            $0.daemonID = daemonID
            $0.id = id
        }
    }

    var description: String { "\(daemonID)/\(id)" }
}

extension ClientMailRow {
    var key: MailMessageKey { MailMessageKey(ref) }
}

/// Agent mail as the shared core presents it: the mailboxes and their
/// counts, the shown mailbox in date groups, the reading pane, the unread
/// badge and this device's preferences. The core files, sorts, groups,
/// words and counts everything; this model folds its slice, keeps the list's
/// selection, and sends the user's commands.
@MainActor @Observable
final class MailModel {
    /// The mailbox, its rows and the reader.
    private(set) var slice = ClientMailSlice()
    /// The rows the list selects, in the list's terms. One selected row is
    /// the reader's message; several are the target of bulk actions.
    private(set) var selection: Set<MailMessageKey> = []
    /// What the search field shows; the core receives it after a pause.
    private(set) var searchText = ""
    /// Bumped to focus the search field (⌘F).
    private(set) var searchFocusRequest = 0
    /// Messages waiting for the user to confirm deleting them for good.
    var permanentDeletion: [MailMessageKey] = []
    /// The user asked to empty the Trash and has yet to confirm.
    var emptyTrashRequested = false
    /// Why the last command failed; the list shows it.
    var errorMessage: String?
    /// Called with the app icon badge (empty: none) whenever it changes.
    @ObservationIgnored var onAppBadgeChange: (@MainActor (String) -> Void)?
    @ObservationIgnored let diagramImages = NativeMarkdownDiagramImageCache()
    @ObservationIgnored let scope: String
    /// The main window's reader moves on when its message leaves the shown
    /// mailbox; a message window keeps showing its one message.
    @ObservationIgnored let followsList: Bool
    @ObservationIgnored private let searchDelay: Duration
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    /// Counts dispatched commands; a reply folds only while it is the latest,
    /// so a slow reply never replaces a newer mailbox.
    @ObservationIgnored private var commandGeneration = 0
    /// Every listed row by its key, in list order.
    @ObservationIgnored private var rowsByKey: [MailMessageKey: ClientMailRow] = [:]
    @ObservationIgnored private(set) var orderedKeys: [MailMessageKey] = []

    init(scope: String = "mac-mail", followsList: Bool = true, searchDelay: Duration = .milliseconds(250)) {
        self.scope = scope
        self.followsList = followsList
        self.searchDelay = searchDelay
    }

    var reader: ClientMailReader? { slice.hasReader ? slice.reader : nil }
    var readerKey: MailMessageKey? { reader.map { MailMessageKey($0.ref) } }
    var unread: Int { Int(slice.unread) }
    var box: ClientMailBox { slice.box }
    var selectedBox: ClientMailBoxRow? { slice.boxes.first { $0.box == slice.box } }
    var isEmpty: Bool { orderedKeys.isEmpty }
    var hasFilter: Bool {
        let filter = slice.filter
        return !filter.projectID.isEmpty || !filter.daemonID.isEmpty || !filter.senderKey.isEmpty
            || filter.importantOnly
    }
    /// The failure to show: this view's last command, else the core's.
    var error: String? { errorMessage ?? (slice.actionError.isEmpty ? nil : slice.actionError) }

    func row(_ key: MailMessageKey) -> ClientMailRow? { rowsByKey[key] }

    /// Observes the mailbox; a second call keeps the first observation.
    func attach(_ core: CoreClient) {
        guard subscription == nil else { return }
        self.core = core
        subscription = SliceSubscription(client: core, slice: .mail, scope: scope) { [weak self] update in
            guard let self, case .mail(let value) = update.value else { return }
            self.fold(value)
        }
    }

    /// Stops observing, e.g. when a message window closes.
    func detach() {
        diagramImages.removeAll()
        pendingSearch?.cancel()
        subscription?.close()
        subscription = nil
        core = nil
    }

    func fold(_ value: ClientMailSlice) {
        let previousBadge = slice.appBadge
        let previousReader = readerKey
        if slice != value {
            slice = value
            var rows: [MailMessageKey: ClientMailRow] = [:]
            var order: [MailMessageKey] = []
            for section in value.sections {
                for row in section.rows {
                    let key = row.key
                    if rows.updateValue(row, forKey: key) == nil { order.append(key) }
                }
            }
            rowsByKey = rows
            orderedKeys = order
        }
        if value.appBadge != previousBadge { onAppBadgeChange?(value.appBadge) }
        // The core closed the reader (the message is gone): so does the list.
        if readerKey == nil, let previousReader, selection == [previousReader] { selection = [] }
        // Rows that left the shown mailbox leave the selection; the reader's
        // message stays selected while it shows.
        let listed = selection.filter { rowsByKey[$0] != nil || $0 == readerKey }
        if listed != selection { selection = listed }
    }

    // MARK: Selection

    /// The list's selection changed: one row opens in the reader, none
    /// closes it, several stay for bulk actions. The selection changes at
    /// once; the returned task (if any) sends it to the core.
    @discardableResult
    func setSelection(_ keys: Set<MailMessageKey>) -> Task<Void, Never>? {
        guard keys != selection else { return nil }
        selection = keys
        if keys.count == 1, let key = keys.first, key != readerKey {
            return Task { await self.show(key) }
        }
        if keys.isEmpty, readerKey != nil {
            return Task { await self.show(nil) }
        }
        return nil
    }

    /// Opens `key` in the reader (it loads its body and marks it read);
    /// nil closes the reader.
    func select(_ key: MailMessageKey?) async {
        selection = key.map { [$0] } ?? []
        await show(key)
    }

    /// Opens `key` from outside the list (a notification, a link): it shows
    /// the Inbox first unless the shown mailbox lists the message.
    func reveal(_ key: MailMessageKey) async {
        if row(key) == nil, box != .inbox { await selectBox(.inbox) }
        await select(key)
    }

    private func show(_ key: MailMessageKey?) async {
        await run { $0.select = key?.ref ?? ClientMailMessageRef() }
    }

    /// Moves the single selection to the next (`offset` 1) or previous row.
    func moveSelection(by offset: Int) async {
        guard !orderedKeys.isEmpty else { return }
        let current = selection.count == 1 ? selection.first : readerKey
        let index = current.flatMap { orderedKeys.firstIndex(of: $0) }
        let next =
            index.map { min(max($0 + offset, 0), orderedKeys.count - 1) } ?? (offset < 0 ? orderedKeys.count - 1 : 0)
        await select(orderedKeys[next])
    }

    /// The messages an action applies to: the selected rows in list order,
    /// else the reader's message.
    var targets: [MailMessageKey] {
        let selected = orderedKeys.filter(selection.contains)
        if !selected.isEmpty { return selected }
        if let key = selection.first ?? readerKey { return [key] }
        return []
    }

    /// Whether every key is read, flagged, archived or in the Trash, from
    /// the rows (or the reader, for a message the list no longer shows).
    func all(_ keys: [MailMessageKey], _ test: (MailMessageState) -> Bool) -> Bool {
        let states = keys.compactMap(state)
        return !states.isEmpty && states.allSatisfy(test)
    }

    func state(_ key: MailMessageKey) -> MailMessageState? {
        if let row = rowsByKey[key] { return MailMessageState(row) }
        if let reader, MailMessageKey(reader.ref) == key { return MailMessageState(reader) }
        return nil
    }

    // MARK: Mailbox, search and filters

    /// The mailbox is on screen: the core fetches unread bodies ahead.
    func setActive(_ active: Bool) async {
        await run { $0.active = .with { $0.on = active } }
    }

    func selectBox(_ box: ClientMailBox) async {
        guard box != slice.box else { return }
        selection = []
        await run { $0.selectBox = box }
    }

    func focusSearch() { searchFocusRequest &+= 1 }

    /// Edits the search; the core filters once typing pauses.
    func updateSearch(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        pendingSearch?.cancel()
        let delay = searchDelay
        pendingSearch = Task { [weak self] in
            if delay > .zero {
                do { try await DieterTaskSleep.duration(delay) } catch { return }
            }
            await self?.search(text)
        }
    }

    func search(_ text: String) async {
        await run { $0.search = text }
    }

    func setFilter(_ filter: ClientMailFilter) async {
        await run { $0.filter = filter }
    }

    /// Picks `id` for one filter dimension, or clears it when it is already picked.
    func toggleFilter(_ dimension: MailFilterDimension, id: String) async {
        var filter = slice.filter
        switch dimension {
        case .project: filter.projectID = filter.projectID == id ? "" : id
        case .machine: filter.daemonID = filter.daemonID == id ? "" : id
        case .sender: filter.senderKey = filter.senderKey == id ? "" : id
        }
        await setFilter(filter)
    }

    func setImportantOnly(_ on: Bool) async {
        var filter = slice.filter
        filter.importantOnly = on
        await setFilter(filter)
    }

    func clearFilters() async {
        await setFilter(ClientMailFilter())
    }

    // MARK: Message actions

    func setRead(_ keys: [MailMessageKey], read: Bool) async {
        await change(keys) { $0.read = read }
    }

    /// Marks the keys read, or unread when every one of them is read.
    func toggleRead(_ keys: [MailMessageKey]) async {
        await setRead(keys, read: !all(keys) { $0.read })
    }

    func setFlagged(_ keys: [MailMessageKey], flagged: Bool) async {
        await change(keys) { $0.flagged = flagged }
    }

    /// Flags the keys, or unflags them when every one of them is flagged.
    func toggleFlag(_ keys: [MailMessageKey]) async {
        await setFlagged(keys, flagged: !all(keys) { $0.flagged })
    }

    func archive(_ keys: [MailMessageKey]) async {
        await move(keys) { $0.folder = .archive }
    }

    /// Moves to the Trash; deleting from the Trash is `deletePermanently`.
    func trash(_ keys: [MailMessageKey]) async {
        await move(keys) { $0.folder = .trash }
    }

    /// Delete as the toolbar and ⌘⌫ mean it: messages outside the Trash move
    /// there; deleting in the Trash asks to confirm deleting for good.
    func delete(_ keys: [MailMessageKey]) async {
        guard !keys.isEmpty else { return }
        if all(keys, \.trashed) {
            permanentDeletion = keys
        } else {
            await trash(keys)
        }
    }

    /// Restores archived or deleted messages to the Inbox.
    func moveToInbox(_ keys: [MailMessageKey]) async {
        await move(keys) { $0.folder = .inbox }
    }

    func deletePermanently(_ keys: [MailMessageKey]) async {
        guard !keys.isEmpty else { return }
        let next = successor(after: keys)
        let refs = keys.map(\.ref)
        await run { $0.delete = .with { $0.refs = refs } }
        await follow(removed: keys, next: next)
    }

    /// Deletes what `delete` asked to confirm.
    func confirmPermanentDeletion() async {
        let keys = permanentDeletion
        permanentDeletion = []
        await deletePermanently(keys)
    }

    func emptyTrash() async {
        emptyTrashRequested = false
        await run { $0.emptyTrash = ClientStep() }
    }

    func markAllRead() async {
        await run { $0.markAllRead = ClientStep() }
    }

    func setPreferences(_ preferences: ClientMailPreferences) async {
        await run { $0.setPreferences = preferences }
    }

    /// Changes one preference and keeps the others as the core has them.
    func updatePreferences(_ edit: (inout ClientMailPreferences) -> Void) async {
        var preferences = slice.preferences
        edit(&preferences)
        await setPreferences(preferences)
    }

    private func change(_ keys: [MailMessageKey], _ build: (inout ClientMailChange) -> Void) async {
        guard !keys.isEmpty else { return }
        var change = ClientMailChange()
        change.refs = keys.map(\.ref)
        build(&change)
        let sent = change
        await run { $0.change = sent }
    }

    /// A folder move; when it takes the reader's message out of the shown
    /// mailbox, the reader moves on to the next message, as in Mail.
    private func move(_ keys: [MailMessageKey], _ build: (inout ClientMailChange) -> Void) async {
        guard !keys.isEmpty else { return }
        let next = successor(after: keys)
        await change(keys, build)
        await follow(removed: keys, next: next)
    }

    /// The row after the last of `keys` that is not one of them, else the
    /// one before the first.
    func successor(after keys: [MailMessageKey]) -> MailMessageKey? {
        let removed = Set(keys)
        let indices = keys.compactMap { orderedKeys.firstIndex(of: $0) }
        guard let last = indices.max(), let first = indices.min() else { return nil }
        if let after = orderedKeys[(last + 1)...].first(where: { !removed.contains($0) }) { return after }
        return orderedKeys[..<first].last(where: { !removed.contains($0) })
    }

    private func follow(removed keys: [MailMessageKey], next: MailMessageKey?) async {
        guard followsList, let reader = readerKey, keys.contains(reader), rowsByKey[reader] == nil else {
            let remaining = selection.filter { rowsByKey[$0] != nil || $0 == readerKey }
            if remaining != selection { selection = remaining }
            return
        }
        if let next, rowsByKey[next] != nil {
            await select(next)
        } else {
            await select(nil)
        }
    }

    /// Runs a command and folds the mailbox it returns, unless a newer
    /// command was sent meanwhile; a failure becomes the error message.
    @discardableResult
    private func run(_ build: (inout ClientMailCommand) -> Void) async -> ClientResult? {
        guard let core else { return nil }
        var command = ClientMailCommand()
        command.scope = scope
        build(&command)
        let sent = command
        commandGeneration &+= 1
        let generation = commandGeneration
        do {
            let result = try await core.dispatch(.with { $0.mail = sent })
            if generation == commandGeneration, case .mail(let value)? = result.result { fold(value) }
            if errorMessage != nil { errorMessage = nil }
            return result
        } catch let failure as CoreFailure {
            errorMessage = failure.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

enum MailFilterDimension: Sendable { case project, machine, sender }

/// What the actions need to know of a message, from its row or the reader.
struct MailMessageState: Equatable, Sendable {
    let read: Bool
    let flagged: Bool
    let archived: Bool
    let trashed: Bool

    init(_ row: ClientMailRow) {
        read = row.read
        flagged = row.flagged
        archived = row.folder == .archive
        trashed = row.folder == .trash
    }

    init(_ reader: ClientMailReader) {
        read = reader.read
        flagged = reader.flagged
        archived = reader.folder == .archive
        trashed = reader.folder == .trash
    }
}
