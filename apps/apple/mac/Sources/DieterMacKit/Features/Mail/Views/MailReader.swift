import AppKit
import DieterClientAPI
import SwiftUI

/// The reading pane: the message's actions, its header with the sender and
/// the way back to the conversation that sent it, and its Markdown body.
/// The main window and the message windows share it, each with its model.
struct MailReaderPane: View {
    let model: MailModel
    /// The main window offers Open in New Window; a message window does not.
    var openInWindow: ((MailMessageKey) -> Void)?
    @Environment(DieterStore.self) private var store

    var body: some View {
        if let reader = model.reader {
            VStack(spacing: 0) {
                MailReaderToolbar(model: model, reader: reader, openInWindow: openInWindow)
                Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MailReaderHeader(reader: reader) {
                            store.openMailConversation(cardID: reader.cardID)
                        }
                        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)
                        Rectangle().fill(DieterTheme.hairline).frame(height: 1).padding(.horizontal, 24)
                        if !reader.stale.isEmpty {
                            DieterCallout(text: reader.stale, symbol: "exclamationmark.triangle")
                                .padding(.horizontal, 24).padding(.top, 12)
                                .accessibilityIdentifier("mail.reader.stale")
                        }
                        MailReaderBody(reader: reader, diagramImages: model.diagramImages) { url in
                            store.openMailLink(url, checkoutID: reader.checkoutID, daemonID: reader.ref.daemonID)
                        }
                    }
                    .frame(maxWidth: MailMarkdown.maximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mail.reader")
            .e2eTarget("mail.reader", text: reader.subject)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(DieterTheme.shell)
                    .frame(width: 64, height: 64)
                    .background(DieterTheme.shell.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                Text("No message selected").font(.system(size: 17, weight: .semibold))
                Text("Reports your agents send show up here. Choose one to read it.")
                    .font(.system(size: 12.5)).foregroundStyle(DieterTheme.subtle)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("mail.reader.empty")
            .e2eTarget("mail.reader.empty")
        }
    }
}

/// Archive, Delete, Flag, Mark Unread, Move to Inbox and the ⋯ menu. Each
/// acts on the list's selection, else on the shown message.
private struct MailReaderToolbar: View {
    let model: MailModel
    let reader: ClientMailReader
    let openInWindow: ((MailMessageKey) -> Void)?
    @State private var exporting = false

    var body: some View {
        HStack(spacing: 6) {
            // Labelled buttons while they fit; icons in a narrow pane.
            ViewThatFits(in: .horizontal) {
                actions(iconOnly: false)
                actions(iconOnly: true)
            }
            Spacer(minLength: 6)
            Menu {
                Button("Copy Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reader.body, forType: .string)
                }
                .disabled(reader.body.isEmpty)
                Divider()
                ForEach(MarkdownFileExport.Format.allCases, id: \.self) { format in
                    Button("\(format.title)…") { export(format) }
                        .disabled(reader.body.isEmpty || exporting)
                }
                if let openInWindow {
                    Divider()
                    Button("Open in New Window") { openInWindow(MailMessageKey(reader.ref)) }
                }
            } label: {
                DieterMenuLabel(symbol: "ellipsis", size: 28)
            }
            .dieterMenuChrome(.circle)
            .help("More")
            .accessibilityLabel("More message actions")
            .accessibilityIdentifier("mail.reader.more")
        }
        .disabled(model.targets.isEmpty)
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private func actions(iconOnly: Bool) -> some View {
        let targets = model.targets
        let archived = model.all(targets, \.archived)
        let trashed = model.all(targets, \.trashed)
        let flagged = model.all(targets, \.flagged)
        let read = model.all(targets, \.read)
        return HStack(spacing: 6) {
            if archived || trashed {
                toolbarButton(
                    "Move to Inbox", symbol: "tray.and.arrow.up", id: "mail.reader.inbox", help: "Move to Inbox",
                    iconOnly: iconOnly
                ) {
                    await model.moveToInbox(targets)
                }
            }
            if !archived {
                toolbarButton(
                    "Archive", symbol: "archivebox", id: "mail.reader.archive", help: "Archive (⌃⌘A)",
                    iconOnly: iconOnly
                ) {
                    await model.archive(targets)
                }
            }
            toolbarButton(
                trashed ? "Delete Permanently" : "Delete", symbol: "trash", id: "mail.reader.delete",
                help: trashed ? "Delete Permanently (⌘⌫)" : "Move to Trash (⌘⌫)", iconOnly: iconOnly,
                destructive: trashed
            ) {
                await model.delete(targets)
            }
            toolbarButton(
                flagged ? "Unflag" : "Flag", symbol: flagged ? "flag.slash" : "flag", id: "mail.reader.flag",
                help: "\(flagged ? "Unflag" : "Flag") (⇧⌘L)", iconOnly: iconOnly
            ) {
                await model.toggleFlag(targets)
            }
            toolbarButton(
                read ? "Mark Unread" : "Mark Read", symbol: read ? "envelope.badge" : "envelope.open",
                id: "mail.reader.read", help: "\(read ? "Mark as Unread" : "Mark as Read") (⇧⌘U)", iconOnly: iconOnly
            ) {
                await model.toggleRead(targets)
            }
        }
    }

    private func toolbarButton(
        _ title: String, symbol: String, id: String, help: String, iconOnly: Bool, destructive: Bool = false,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            if iconOnly {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            } else {
                Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
            }
        }
        .buttonStyle(DieterBarButtonStyle(shape: iconOnly ? .circle : .capsule, destructive: destructive, size: 28))
        .fixedSize()
        .help(help)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
        .e2eTarget(id, text: title)
    }

    /// Exports the body through the Files export: a save panel, then the
    /// bundled renderer.
    private func export(_ format: MarkdownFileExport.Format) {
        let document = MarkdownFileExport.Document(
            name: MailExportName.filename(subject: reader.subject), source: reader.body)
        let panel = NSSavePanel()
        panel.title = format.title
        panel.prompt = "Export"
        panel.nameFieldStringValue = document.filename(for: format)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        let window = NSApp.keyWindow
        exporting = true
        Task { @MainActor in
            defer { exporting = false }
            let response = await withCheckedContinuation { continuation in
                if let window {
                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                } else {
                    panel.begin { continuation.resume(returning: $0) }
                }
            }
            guard response == .OK, let destination = panel.url else { return }
            do {
                let data = try await MarkdownFileExport.data(for: document, format: format)
                try data.write(to: destination, options: .atomic)
            } catch {
                model.errorMessage = "Could not export \(document.name): \(error.localizedDescription)"
            }
        }
    }
}

/// A file name for an exported message: its subject without path separators.
enum MailExportName {
    static func filename(subject: String) -> String {
        let cleaned = subject.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Message" : String(cleaned.prefix(120))) + ".md"
    }
}

/// The subject with its Important chip, then the sender, its details and
/// the sent time, and Open conversation.
private struct MailReaderHeader: View {
    let reader: ClientMailReader
    let openConversation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(reader.subject)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DieterTheme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mail.reader.subject")
                if reader.important { MailImportantChip() }
            }
            HStack(alignment: .center, spacing: 11) {
                MailAvatar(reader: reader)
                VStack(alignment: .leading, spacing: 3) {
                    Text(reader.sender)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DieterTheme.text)
                        .lineLimit(1)
                    Text([reader.senderDetail, reader.sentLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DieterTheme.tertiary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Button(action: openConversation) {
                    Label("Open conversation", systemImage: "arrow.up.forward.app").labelStyle(.titleAndIcon)
                }
                .buttonStyle(DieterBarButtonStyle(size: 28))
                .fixedSize()
                .disabled(!reader.canOpenConversation)
                .quickHelp(
                    reader.canOpenConversation
                        ? "Open the conversation that sent this message" : reader.openConversationUnavailable
                )
                .accessibilityHint(reader.canOpenConversation ? "" : reader.openConversationUnavailable)
                .accessibilityIdentifier("mail.reader.open-conversation")
                .e2eTarget("mail.reader.open-conversation", text: "Open conversation")
            }
        }
    }
}

/// The body, or why it is not shown yet.
private struct MailReaderBody: View {
    let reader: ClientMailReader
    let diagramImages: NativeMarkdownDiagramImageCache
    let openLink: @MainActor (URL) -> Bool

    var body: some View {
        if reader.loading, reader.body.isEmpty {
            LoadFeedback(title: "Loading the message…", compact: true)
                .padding(.horizontal, 16).padding(.top, 10)
                .accessibilityIdentifier("mail.reader.loading")
        } else if !reader.unavailable.isEmpty {
            DieterCallout(text: reader.unavailable, tint: DieterTheme.subtle, symbol: "icloud.slash")
                .padding(.horizontal, 24).padding(.top, 14)
                .accessibilityIdentifier("mail.reader.unavailable")
                .e2eTarget("mail.reader.unavailable", text: reader.unavailable)
        } else {
            MailMessageBody(
                markdown: reader.body, documentID: "mail:\(reader.ref.daemonID)/\(reader.ref.id)",
                diagramImages: diagramImages, openLink: openLink
            )
            .id("\(reader.ref.daemonID)/\(reader.ref.id)")
            .e2eTarget("mail.reader.body", text: reader.body)
        }
    }
}
