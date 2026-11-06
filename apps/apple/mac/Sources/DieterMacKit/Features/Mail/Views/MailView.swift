import AppKit
import SwiftUI

/// Agent mail: the message list beside the reading pane. Read-only by
/// design; agents send, the user reads, flags, archives and deletes.
struct MailView: View {
    var active = true
    @Environment(DieterStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let model = store.mailModel
        // The split's panes live in their own hosting views: hand them the
        // window action rather than their environment.
        let open: (MailMessageKey) -> Void = { openWindow(id: MailWindow.id, value: $0) }
        ChatPaneSplit(layout: .mail) {
            MailListPane(model: model, openInWindow: open)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mail.list-pane")
                .e2eTarget("mail.list-pane")
        } detail: {
            MailReaderPane(model: model, openInWindow: open)
                .environment(store)
        }
        .defaultAppStorage(store.environment.defaults)
        .ignoresSafeArea(.container, edges: .top)
        .background {
            if active {
                Button("Search Mail") { model.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .mailConfirmations(model)
        .task(id: active) { await model.setActive(active) }
    }
}

/// The message windows: one message per window, from ⌘O, a double-click
/// or the ⋯ menu.
enum MailWindow {
    static let id = "mail-message"
}

/// One message in its own window, read through its own mail surface.
struct MailMessageWindow: View {
    let key: MailMessageKey?
    @Environment(DieterStore.self) private var store
    @State private var model = MailModel(scope: "mac-mail-window-\(UUID().uuidString)", followsList: false)

    var body: some View {
        Group {
            if key == nil {
                Text("This message is no longer available.")
                    .foregroundStyle(DieterTheme.subtle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MailReaderPane(model: model, openInWindow: nil)
            }
        }
        .frame(minWidth: 560, idealWidth: 860, minHeight: 420, idealHeight: 760)
        .background(DieterTheme.background)
        .navigationTitle(model.reader?.subject ?? "Message")
        .focusedSceneValue(\.mailModel, model)
        .mailConfirmations(model)
        .task(id: key) {
            model.attach(store.core)
            guard let key else { return }
            await model.select(key)
        }
        .onDisappear { model.detach() }
    }
}

extension FocusedValues {
    /// The mail the Message menu acts on: the key window's message window,
    /// or the workspace while it shows Mail.
    @Entry var mailModel: MailModel?
}

/// Publishes the workspace's mail to the Message menu while Mail is shown.
struct WorkspaceMailFocus: ViewModifier {
    @Environment(DieterStore.self) private var store

    func body(content: Content) -> some View {
        content.focusedSceneValue(\.mailModel, store.section == .mail ? store.mailModel : nil)
    }
}

extension View {
    /// The confirmations a mail view asks before deleting for good.
    func mailConfirmations(_ model: MailModel) -> some View {
        confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(
                get: { !model.permanentDeletion.isEmpty }, set: { if !$0 { model.permanentDeletion = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { Task { await model.confirmPermanentDeletion() } }
            Button("Cancel", role: .cancel) { model.permanentDeletion = [] }
        } message: {
            Text("The selected messages are deleted on the machines that hold them. This cannot be undone.")
        }
    }
}

/// The Message menu, as in Mail. It acts on the focused mail (see
/// `FocusedValues.mailModel`) and is disabled elsewhere.
struct MailMessageCommands: View {
    @FocusedValue(\.mailModel) private var model
    let openInWindow: (MailMessageKey) -> Void

    var body: some View {
        let targets = model?.targets ?? []
        let enabled = model != nil && !targets.isEmpty
        let trashed = model?.all(targets, \.trashed) ?? false
        let archived = model?.all(targets, \.archived) ?? false
        let read = model?.all(targets, \.read) ?? false
        let flagged = model?.all(targets, \.flagged) ?? false
        Button(trashed ? "Delete Permanently…" : "Delete") {
            // ⌘⌫ in a text field deletes to the start of the line, as anywhere.
            if MailTextEditing.deleteToLineStartIfEditing() { return }
            run { await $0.delete(targets) }
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!enabled)
        Button("Archive") { run { await $0.archive(targets) } }
            .keyboardShortcut("a", modifiers: [.control, .command])
            .disabled(!enabled || archived)
        Button("Move to Inbox") { run { await $0.moveToInbox(targets) } }
            .disabled(!enabled || !(archived || trashed))
        Divider()
        Button(read ? "Mark as Unread" : "Mark as Read") { run { await $0.toggleRead(targets) } }
            .keyboardShortcut("u", modifiers: [.shift, .command])
            .disabled(!enabled)
        Button(flagged ? "Unflag" : "Flag") { run { await $0.toggleFlag(targets) } }
            .keyboardShortcut("l", modifiers: [.shift, .command])
            .disabled(!enabled)
        Divider()
        Button("Open in New Window") {
            if let key = targets.first { openInWindow(key) }
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(!enabled || targets.count != 1 || model?.followsList != true)
    }

    private func run(_ action: @escaping @MainActor (MailModel) async -> Void) {
        guard let model else { return }
        Task { await action(model) }
    }
}

@MainActor
enum MailTextEditing {
    /// When an editable text view has focus, ⌘⌫ belongs to it: deletes to
    /// the start of its line and reports true.
    static func deleteToLineStartIfEditing() -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable else {
            return false
        }
        textView.deleteToBeginningOfLine(nil)
        return true
    }
}
