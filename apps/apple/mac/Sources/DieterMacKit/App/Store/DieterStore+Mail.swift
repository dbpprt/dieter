import AppKit
import DieterClientAPI
import Foundation

extension DieterStore {
    /// Agent mail.
    func openMail() {
        guard section != .mail else { return }
        stopTerminalWatch()
        closeConversation()
        section = .mail
    }

    /// Opens Mail with `key` selected, e.g. from a notification.
    func openMail(ref key: MailMessageKey) {
        openMail()
        Task { await mailModel.reveal(key) }
    }

    /// Brings the workspace window forward, e.g. from a message window, the
    /// menu bar or a notification.
    func revealWorkspaceWindow() {
        reopenWorkspaceWindow()
        NSApp?.activate(ignoringOtherApps: true)
    }

    /// Open conversation: the message's sender, in the workspace window.
    func openMailConversation(cardID: String) {
        guard !cardID.isEmpty else { return }
        revealWorkspaceWindow()
        Task { await openConversation(cardID: cardID) }
    }

    /// A link in a message. Web and mail links open in their apps; a
    /// workspace link opens its file in Files on the sender's machine (when
    /// the message has a checkout); anything else does nothing. Always
    /// handled, so the engine never opens a link itself.
    func openMailLink(_ url: URL, checkoutID: String, daemonID: String) -> Bool {
        let checkout = checkoutID.isEmpty ? nil : mailCheckout(id: checkoutID, daemonID: daemonID)
        switch MailLink.classify(url, workspaceRoot: checkout?.path) {
        case .external(let url):
            NSWorkspace.shared.open(url)
        case .workspaceFile(let path, _):
            guard let checkout else { break }
            revealWorkspaceWindow()
            Task { await openMailFile(projectID: checkout.projectID, checkoutID: checkoutID, path: path) }
        case .ignored:
            break
        }
        return true
    }

    /// Shows `path` of the sender's checkout in Files.
    func openMailFile(projectID: String, checkoutID: String, path: String) async {
        // Files and their workspace follow this Mac's checkout choice for the
        // project; point it at the sender's without remembering it.
        creationCheckoutIDs[projectID] = checkoutID
        await openProjectPath(projectID, path: path, directory: false)
    }

    /// A tap on, or an action of, one of the core's notifications: the core
    /// runs the action and says where to go.
    func respondToNotification(key: String, action: String) async {
        do {
            let result = try await core.dispatch {
                $0.notificationResponse = .with {
                    $0.key = key
                    $0.action = action
                }
            }
            guard case .notificationTarget(let target)? = result.result else { return }
            switch target.target {
            case .cardID(let cardID)?:
                revealWorkspaceWindow()
                await openConversation(cardID: cardID)
            case .mail(let ref)?:
                revealWorkspaceWindow()
                openMail(ref: MailMessageKey(ref))
            case .inbox?:
                revealWorkspaceWindow()
                await openInbox()
            case .none?, nil:
                return
            }
        } catch {
            show(error)
        }
    }

    /// The Dock icon's badge: the core's label while the preference is on.
    static func applyAppBadge(_ label: String) {
        NSApp?.dockTile.badgeLabel = label.isEmpty ? nil : label
    }
}
