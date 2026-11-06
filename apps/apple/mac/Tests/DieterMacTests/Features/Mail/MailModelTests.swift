import DieterAPI
import DieterClientAPI
import Foundation
import Testing

@testable import DieterMacKit

/// The mail view model over a scripted core: it folds the mail slice the
/// core sends (rows in list order, the reader, the Dock badge), keeps the
/// list's selection in step with the reader, and every command carries the
/// view's scope and exactly what the user chose.
@MainActor
struct MailModelTests {
    private static let scope = "test-mail"

    private static func ref(_ id: String, daemon: String = "d1") -> ClientMailMessageRef {
        .with {
            $0.daemonID = daemon
            $0.id = id
        }
    }

    private static func row(
        _ id: String, daemon: String = "d1", read: Bool = false, flagged: Bool = false,
        folder: Dieter_V1_MailFolder = .inbox
    ) -> ClientMailRow {
        .with {
            $0.ref = ref(id, daemon: daemon)
            $0.subject = "Subject \(id)"
            $0.sender = "Sender"
            $0.read = read
            $0.flagged = flagged
            $0.folder = folder
        }
    }

    /// Today: a, b; Yesterday: c (on another machine).
    private static func slice(
        rows: [ClientMailRow]? = nil, reader: String? = nil, badge: String = "", box: ClientMailBox = .inbox
    ) -> ClientMailSlice {
        let rows = rows ?? [row("a"), row("b", read: true), row("c", daemon: "d2", flagged: true)]
        return .with {
            $0.box = box
            $0.boxes = [
                .with {
                    $0.box = .inbox; $0.title = "Inbox"; $0.unread = 2; $0.countLabel = "2"; $0.selected = box == .inbox
                },
                .with {
                    $0.box = .trash; $0.title = "Trash"; $0.selected = box == .trash
                },
            ]
            $0.sections = [
                .with {
                    $0.id = "today"; $0.title = "Today"; $0.rows = Array(rows.prefix(2))
                },
                .with {
                    $0.id = "yesterday"; $0.title = "Yesterday"; $0.rows = Array(rows.dropFirst(2))
                },
            ]
            $0.unread = 2
            $0.unreadLabel = "2"
            $0.appBadge = badge
            // The reader may show a message the mailbox no longer lists.
            if let reader, let shown = rows.first(where: { $0.ref.id == reader }) ?? Optional(row(reader)) {
                $0.reader = .with {
                    $0.ref = shown.ref
                    $0.subject = shown.subject
                    $0.read = true
                    $0.flagged = shown.flagged
                    $0.folder = shown.folder
                    $0.body = "## Summary"
                }
            }
        }
    }

    private func attached(followsList: Bool = true) -> (ScriptedCoreClient, MailModel) {
        let core = ScriptedCoreClient()
        let model = MailModel(scope: Self.scope, followsList: followsList, searchDelay: .zero)
        model.attach(core)
        model.attach(core)
        return (core, model)
    }

    private func emit(_ core: ScriptedCoreClient, _ value: ClientMailSlice) {
        core.emit(.mail, scope: Self.scope) { $0.mail = value }
    }

    private func mailCommands(_ core: ScriptedCoreClient) -> [ClientMailCommand] {
        core.commands.compactMap { if case .mail(let command)? = $0.command { command } else { nil } }
    }

    private let a = MailMessageKey(daemonID: "d1", id: "a")
    private let b = MailMessageKey(daemonID: "d1", id: "b")
    private let c = MailMessageKey(daemonID: "d2", id: "c")

    @Test func itFoldsTheMailboxInListOrderAndReportsTheBadge() {
        let (core, model) = attached()
        var badges: [String] = []
        model.onAppBadgeChange = { badges.append($0) }
        #expect(core.isObserved(.mail, scope: Self.scope))
        #expect(model.isEmpty && model.reader == nil)

        emit(core, Self.slice(badge: "2"))
        #expect(model.orderedKeys == [a, b, c])
        #expect(model.row(c)?.flagged == true)
        #expect(model.unread == 2 && model.selectedBox?.title == "Inbox")
        #expect(model.state(b) == MailMessageState(Self.row("b", read: true)))
        emit(core, Self.slice(badge: "2"))
        emit(core, Self.slice(badge: ""))
        #expect(badges == ["2", ""], "the badge is reported when it changes only")
    }

    @Test func choosingOneRowOpensItAndSeveralStayForBulkActions() async {
        let (core, model) = attached()
        emit(core, Self.slice())

        await model.setSelection([b])?.value
        #expect(model.selection == [b])
        #expect(mailCommands(core).last?.select == Self.ref("b"))
        #expect(mailCommands(core).allSatisfy { $0.scope == Self.scope })

        emit(core, Self.slice(reader: "b"))
        #expect(model.readerKey == b)
        #expect(model.setSelection([b]) == nil, "an unchanged selection sends nothing")
        let sent = core.commands.count
        #expect(model.setSelection([c, a]) == nil, "several rows keep the reader")
        #expect(core.commands.count == sent)
        #expect(model.targets == [a, c], "bulk actions run in list order")

        await model.setSelection([])?.value
        #expect(mailCommands(core).last?.select == ClientMailMessageRef(), "no selection closes the reader")
        #expect(model.targets == [b], "the reader's message stays the target until the core closes it")
        emit(core, Self.slice())
        #expect(model.targets.isEmpty)
    }

    @Test func rowsThatLeaveTheMailboxLeaveTheSelection() async {
        let (core, model) = attached()
        emit(core, Self.slice(reader: "a"))
        await model.setSelection([a, b])?.value
        emit(core, Self.slice(rows: [Self.row("a"), Self.row("c", daemon: "d2")], reader: "a"))
        #expect(model.selection == [a])
        // The core closes the reader when its message is gone.
        await model.select(c)
        emit(core, Self.slice(rows: [Self.row("a")]))
        #expect(model.selection.isEmpty)
    }

    @Test func arrowsMoveTheSelectionWithinTheList() async {
        let (core, model) = attached()
        emit(core, Self.slice())
        await model.moveSelection(by: 1)
        #expect(model.selection == [a], "without a selection the first row opens")
        emit(core, Self.slice(reader: "a"))
        await model.moveSelection(by: 1)
        await model.moveSelection(by: 1)
        await model.moveSelection(by: 1)
        #expect(model.selection == [c], "the last row stays selected")
        await model.moveSelection(by: -1)
        #expect(model.selection == [b])
        #expect(mailCommands(core).map(\.select.id) == ["a", "b", "c", "c", "b"])
    }

    @Test func actionsCarryTheTargetsAndToggleAsAGroup() async {
        let (core, model) = attached()
        emit(core, Self.slice(reader: "a"))
        await model.select(a)
        await model.toggleRead([a, b])
        await model.toggleRead([b])
        await model.toggleFlag([a, c])
        await model.toggleFlag([c])
        let changes = mailCommands(core).compactMap(\.changeAction)
        #expect(
            changes.map(\.refs) == [
                [Self.ref("a"), Self.ref("b")], [Self.ref("b")], [Self.ref("a"), Self.ref("c", daemon: "d2")],
                [Self.ref("c", daemon: "d2")],
            ])
        #expect(changes[0].read == true, "a group with an unread message is marked read")
        #expect(changes[1].read == false, "a read message is marked unread")
        #expect(changes[2].flagged == true && changes[3].flagged == false)
        #expect(changes.allSatisfy { $0.folder == .unspecified })
        #expect(!changes[0].hasFlagged && !changes[2].hasRead, "unset fields stay unchanged")
    }

    @Test func archivingTheShownMessageMovesTheReaderOnAsInMail() async {
        let (core, model) = attached()
        let archived = Self.slice(rows: [Self.row("a"), Self.row("c", daemon: "d2")], reader: "b")
        core.handler = { command in
            guard case .mail(let mail)? = command.command, mail.changeAction != nil else {
                return .with { $0.done = ClientDone() }
            }
            var value = archived
            value.reader.folder = .archive
            return .with { $0.mail = value }
        }
        emit(core, Self.slice(reader: "b"))
        await model.select(b)
        await model.archive([b])
        let commands = mailCommands(core)
        #expect(commands.contains { $0.changeAction?.folder == .archive && $0.changeAction?.refs == [Self.ref("b")] })
        #expect(commands.last?.select == Self.ref("c", daemon: "d2"), "the next row opens")
        #expect(model.selection == [c])
        #expect(model.successor(after: [c]) == a, "the last row's successor is the one before it")
        #expect(model.successor(after: [MailMessageKey(daemonID: "d9", id: "gone")]) == nil)
    }

    @Test func aMessageWindowKeepsItsMessageAfterAMove() async {
        let (core, model) = attached(followsList: false)
        core.handler = { command in
            guard case .mail(let mail)? = command.command, mail.changeAction != nil else {
                return .with { $0.done = ClientDone() }
            }
            var value = Self.slice(rows: [Self.row("a"), Self.row("c", daemon: "d2")], reader: "b")
            value.reader.folder = .trash
            return .with { $0.mail = value }
        }
        emit(core, Self.slice(reader: "b"))
        await model.select(b)
        await model.delete([b])
        #expect(mailCommands(core).last?.changeAction?.folder == .trash)
        #expect(model.readerKey == b && model.selection == [b])
        #expect(model.state(b)?.trashed == true)
    }

    @Test func deletingInTheTrashAsksFirstThenDeletesForGood() async {
        let (core, model) = attached()
        let trashed = [Self.row("a", folder: .trash), Self.row("b", folder: .trash)]
        emit(core, Self.slice(rows: trashed, box: .trash))
        await model.delete([a])
        #expect(model.permanentDeletion == [a])
        #expect(mailCommands(core).isEmpty, "nothing is deleted before the user confirms")
        await model.confirmPermanentDeletion()
        #expect(model.permanentDeletion.isEmpty)
        #expect(mailCommands(core).last?.delete.refs == [Self.ref("a")])

        model.emptyTrashRequested = true
        await model.emptyTrash()
        #expect(!model.emptyTrashRequested)
        #expect(mailCommands(core).last?.isEmptyTrash == true)
    }

    @Test func mailboxesSearchFiltersAndPreferencesReachTheCore() async throws {
        let (core, model) = attached()
        var value = Self.slice()
        value.filter = .with { $0.projectID = "p1" }
        value.preferences = .with { $0.notify = true }
        emit(core, value)
        await model.setSelection([a])?.value
        await model.selectBox(.trash)
        #expect(model.selection.isEmpty, "another mailbox starts without a selection")
        var trash = value
        trash.box = .trash
        emit(core, trash)
        await model.selectBox(.trash)
        await model.selectBox(.inbox)
        emit(core, value)
        await model.toggleFilter(.project, id: "p1")
        await model.toggleFilter(.machine, id: "d2")
        await model.setImportantOnly(true)
        await model.clearFilters()
        await model.setActive(true)
        await model.markAllRead()
        await model.updatePreferences { $0.appBadge = true }
        model.updateSearch("audit")
        model.updateSearch("audit")
        for _ in 0..<100 where !mailCommands(core).contains(where: { $0.searchAction != nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let commands = mailCommands(core)
        #expect(commands.compactMap(\.selectBoxAction) == [.trash, .inbox])
        let filters = commands.compactMap(\.filterAction)
        #expect(filters.count == 4)
        #expect(filters[0].projectID.isEmpty, "picking the chosen project clears it")
        #expect(filters[1].projectID == "p1" && filters[1].daemonID == "d2")
        #expect(filters[2].importantOnly)
        #expect(filters[3] == ClientMailFilter())
        #expect(commands.contains { $0.activeAction == true })
        #expect(commands.contains { $0.isMarkAllRead })
        let preferences = try #require(commands.compactMap(\.preferencesAction).first)
        #expect(preferences.notify && preferences.appBadge && !preferences.notifyImportantOnly)
        #expect(commands.compactMap(\.searchAction) == ["audit"], "an unchanged search is sent once")
        #expect(commands.allSatisfy { $0.scope == Self.scope })
    }

    @Test func refusalsShowAndASlowReplyNeverReplacesANewerMailbox() async throws {
        let (core, model) = attached()
        emit(core, Self.slice())
        core.handler = { _ in throw CoreFailure(kind: .invalid, message: "Open the mail first.") }
        await model.markAllRead()
        #expect(model.error == "Open the mail first.")

        // The first reply arrives after the second command's.
        var release: CheckedContinuation<Void, Never>?
        core.handler = { _ in .with { $0.done = ClientDone() } }
        core.asyncHandler = { command in
            guard case .mail(let mail)? = command.command else { return .with { $0.done = ClientDone() } }
            if mail.select.id == "a" {
                await withCheckedContinuation { release = $0 }
                return .with { $0.mail = Self.slice(reader: "a") }
            }
            return .with { $0.mail = Self.slice(reader: mail.select.id) }
        }
        let first = Task { await model.select(a) }
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(5)) }
        await model.select(b)
        #expect(model.readerKey == b)
        release?.resume()
        await first.value
        #expect(model.readerKey == b, "the stale reply is not folded")
        #expect(model.error == nil, "a later success clears the failure")
    }

    @Test func revealingAMessageOutsideTheShownMailboxShowsTheInbox() async {
        let (core, model) = attached()
        emit(core, Self.slice(rows: [Self.row("a", folder: .trash)], box: .trash))
        await model.reveal(b)
        let commands = mailCommands(core)
        #expect(commands.first?.selectBox == .inbox)
        #expect(commands.last?.select == Self.ref("b"))
        // A listed message opens where it is.
        await model.reveal(a)
        #expect(mailCommands(core).compactMap(\.selectBoxAction).count == 1)
    }

    @Test func messageKeysRoundTripForTheirWindows() throws {
        let key = MailMessageKey(daemonID: "d1", id: "msg_1")
        let decoded = try JSONDecoder().decode(MailMessageKey.self, from: JSONEncoder().encode(key))
        #expect(decoded == key)
        #expect(key.ref == Self.ref("msg_1"))
        #expect(MailMessageKey(key.ref) == key)
        #expect(AppSection.mail.rawValue == "Mail" && AppSection.mail.symbol == "envelope")
    }
}

extension ClientMailCommand {
    fileprivate var changeAction: ClientMailChange? { if case .change(let value)? = action { value } else { nil } }
    fileprivate var selectBoxAction: ClientMailBox? { if case .selectBox(let value)? = action { value } else { nil } }
    fileprivate var filterAction: ClientMailFilter? { if case .filter(let value)? = action { value } else { nil } }
    fileprivate var searchAction: String? { if case .search(let value)? = action { value } else { nil } }
    fileprivate var activeAction: Bool? { if case .active(let value)? = action { value.on } else { nil } }
    fileprivate var preferencesAction: ClientMailPreferences? {
        if case .setPreferences(let value)? = action { value } else { nil }
    }
    fileprivate var isMarkAllRead: Bool { if case .markAllRead? = action { true } else { false } }
    fileprivate var isEmptyTrash: Bool { if case .emptyTrash? = action { true } else { false } }
}

/// Links in a message: web and mail links leave Dieter, workspace links
/// resolve inside the sender's checkout, everything else does nothing.
@MainActor
struct MailLinkTests {
    @Test func linksOpenWhereTheyBelong() throws {
        let root = "/Users/me/src/dieter"
        func url(_ string: String) throws -> URL { try #require(URL(string: string)) }
        #expect(
            MailLink.classify(try url("https://example.com/a"), workspaceRoot: nil)
                == .external(try url("https://example.com/a")))
        #expect(
            MailLink.classify(try url("mailto:ops@example.com"), workspaceRoot: root)
                == .external(try url("mailto:ops@example.com")))
        #expect(
            MailLink.classify(try url("README.md"), workspaceRoot: root) == .workspaceFile(path: "README.md", line: nil)
        )
        #expect(
            MailLink.classify(try url("docs/a.md#L12"), workspaceRoot: root)
                == .workspaceFile(path: "docs/a.md", line: 12))
        #expect(
            MailLink.classify(try url("file:///Users/me/src/dieter/go.mod"), workspaceRoot: root)
                == .workspaceFile(path: "go.mod", line: nil))
        #expect(
            MailLink.classify(try url("README.md"), workspaceRoot: nil) == .ignored, "operator mail has no workspace")
        #expect(MailLink.classify(try url("../../etc/passwd"), workspaceRoot: root) == .ignored)
        #expect(MailLink.classify(try url("file:///etc/passwd"), workspaceRoot: root) == .ignored)
        #expect(MailLink.classify(try url("javascript:alert(1)"), workspaceRoot: root) == .ignored)
        #expect(MailLink.classify(try url("ssh://host/x"), workspaceRoot: root) == .ignored)
    }

    @Test func exportsAreNamedAfterTheSubject() {
        #expect(MailExportName.filename(subject: "Dependency audit — 3 critical") == "Dependency audit — 3 critical.md")
        #expect(MailExportName.filename(subject: "a/b: c") == "a b  c.md")
        #expect(MailExportName.filename(subject: "  ") == "Message.md")
    }
}

/// A notification response reaches the core with its key and action, and the
/// window goes where the core says.
@MainActor
struct MailNotificationRoutingTests {
    @Test func theCoresTargetDecidesWhereTheAppGoes() async {
        let core = ScriptedCoreClient()
        let store = DieterStore(core: core, liveEnvironment: false)
        var target = ClientNotificationTarget()
        core.handler = { command in
            if case .notificationResponse = command.command { return .with { $0.notificationTarget = target } }
            return .with { $0.done = ClientDone() }
        }
        target.none = ClientStep()
        await store.respondToNotification(key: "mail:d1:m1", action: "ARCHIVE")
        #expect(store.section != .mail)
        let response = core.commands.compactMap { command -> ClientNotificationResponse? in
            if case .notificationResponse(let response)? = command.command { response } else { nil }
        }.first
        #expect(response?.key == "mail:d1:m1" && response?.action == "ARCHIVE")

        target.mail = .with {
            $0.daemonID = "d1"
            $0.id = "m1"
        }
        await store.respondToNotification(key: "mail:d1:m1", action: "")
        #expect(store.section == .mail)

        target.inbox = ClientStep()
        await store.respondToNotification(key: "card:c1", action: "")
        #expect(store.section == .inbox)

        target.cardID = "c_task"
        await store.respondToNotification(key: "card:c_task", action: "OPEN")
        #expect(store.selectedCardID == "c_task" || store.selectedChatID == "c_task")
    }
}
