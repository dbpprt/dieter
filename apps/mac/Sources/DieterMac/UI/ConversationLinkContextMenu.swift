import AppKit
import Foundation

/// The resolver owns machine/workspace validation. Menu actions validate again
/// so a menu left open during navigation cannot operate on another workspace.
struct ConversationLinkExternalTarget {
    var isFile = true
    var applications: [FileOpeningApplication] = []
    var unavailableReason: String?
    var revalidate: @MainActor () -> URL?

    static func unavailable(_ reason: String, isFile: Bool = true) -> Self {
        Self(isFile: isFile, unavailableReason: reason, revalidate: { nil })
    }

    @MainActor static func open(_ url: URL, application: URL?) {
        Task { @MainActor in
            do {
                if let application {
                    _ = try await NSWorkspace.shared.open(
                        [url], withApplicationAt: application, configuration: .init())
                } else if !NSWorkspace.shared.open(url) {
                    throw CocoaError(.fileReadUnknown)
                }
            } catch { NSApp.presentError(error) }
        }
    }
}

@MainActor final class ConversationLinkMenuSession: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private(set) var loadingTask: Task<Void, Never>?
    private let applications = NSMenu(title: "Open in…")
    private let finder = NSMenuItem(title: "Show in Finder", action: nil, keyEquivalent: "")
    private var closed = false

    init(
        url: URL, textView: NSTextView, openInDieter: ConversationLinkHandler?,
        resolver: @escaping ConversationLinkExternalResolver,
        openExternal: @escaping @MainActor (URL, URL?) -> Void,
        reveal: @escaping @MainActor (URL) -> Void
    ) {
        super.init()
        menu.autoenablesItems = false
        applications.autoenablesItems = false
        menu.delegate = self
        let open = item("Open in Dieter") { _ = openInDieter?(url) }
        open.isEnabled = openInDieter != nil
        menu.addItem(open)
        let submenu = NSMenuItem(title: "Open in…", action: nil, keyEquivalent: "")
        submenu.submenu = applications
        menu.addItem(submenu)
        status("Loading…")
        let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        if !isWeb { finder.isEnabled = false; menu.addItem(finder) }
        menu.addItem(.separator())
        menu.addItem(item("Copy Link") { FileExternalActions.copy(url.relativeString) })
        let copy = item("Copy") { [weak textView] in textView?.copy(nil) }
        copy.isEnabled = textView.selectedRange().length > 0
        menu.addItem(copy)
        loadingTask = Task { [weak self] in
            let target = await resolver(url)
            guard let self, !Task.isCancelled, !closed else { return }
            applications.removeAllItems()
            if let reason = target.unavailableReason {
                status(reason)
            } else {
                if target.applications.isEmpty {
                    applications.addItem(
                        item("Default App") {
                            guard let url = target.revalidate() else { return }
                            openExternal(url, nil)
                        })
                }
                for application in target.applications {
                    let choice = item(application.name + (application.isDefault ? " (Default)" : "")) {
                        guard let url = target.revalidate() else { return }
                        openExternal(url, application.url)
                    }
                    let icon = NSWorkspace.shared.icon(forFile: application.url.path)
                    icon.size = NSSize(width: 16, height: 16)
                    choice.image = icon
                    applications.addItem(choice)
                }
                if target.isFile, menu.items.contains(finder) {
                    finder.isEnabled = true
                    setAction(on: finder) {
                        guard let url = target.revalidate() else { return }
                        reveal(url)
                    }
                }
            }
            if !target.isFile, menu.items.contains(finder) { menu.removeItem(finder) }
            menu.update()
        }
    }

    func menuDidClose(_ menu: NSMenu) { cancel() }
    func cancel() { closed = true; loadingTask?.cancel() }

    private func status(_ title: String) {
        let value = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        value.isEnabled = false
        applications.addItem(value)
    }

    private func item(_ title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        setAction(on: value, action: action)
        return value
    }

    private func setAction(on item: NSMenuItem, action: @escaping @MainActor () -> Void) {
        let handler = ConversationLinkMenuAction(action)
        item.target = handler
        item.action = #selector(ConversationLinkMenuAction.invoke(_:))
        // NSMenuItem's target is weak; retain this action with its own item.
        item.representedObject = handler
    }
}

@MainActor private final class ConversationLinkMenuAction: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func invoke(_ sender: NSMenuItem) { action() }
}
