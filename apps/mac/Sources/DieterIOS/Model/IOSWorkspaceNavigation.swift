#if os(iOS)
    import DieterAPI
    import Foundation
    import Observation
    import SwiftUI

    /// What the workspace's middle column lists (D3: Inbox, Projects, Chats,
    /// plus the machine tools).
    enum IOSWorkspaceDestination: Hashable {
        case inbox
        case chats
        case terminals
        case screens
        /// A project's boards.
        case project(String)
        /// One board's lanes, through the core's board view.
        case board(String)
    }

    /// A new task or chat to compose, from a toolbar or a share.
    struct IOSCreateRequest: Identifiable {
        let id = UUID()
        let chat: Bool
        let projectID: String
        let boardID: String
        let attachments: [Dieter_V1_MessagePart]
    }

    /// Shared attachments waiting for a person to pick their conversation.
    struct IOSShareTargetRequest: Identifiable {
        let id = UUID()
        let kind: IOSShareInbox.Destination
        let attachments: [Dieter_V1_MessagePart]
    }

    /// The modal surfaces the workspace presents.
    enum IOSWorkspaceSheet: Identifiable {
        case settings
        case machines
        case machineState
        case providerQuotas
        case create(IOSCreateRequest)
        case shareTarget(IOSShareTargetRequest)
        case files(IOSFileScope)

        var id: String {
            switch self {
            case .settings: "settings"
            case .machines: "machines"
            case .machineState: "machine-state"
            case .providerQuotas: "provider-quotas"
            case .create(let request): "create-\(request.id)"
            case .shareTarget(let request): "share-\(request.id)"
            case .files(let scope): "files-\(scope.id)"
            }
        }
    }

    /// Where the person is in the workspace: the destination, the open
    /// conversation, and the presented sheet. Feature screens read it from the
    /// environment to open conversations and sheets.
    @MainActor
    @Observable
    final class IOSWorkspaceNavigation {
        var destination: IOSWorkspaceDestination? = .inbox
        /// The conversation (card or chat) the detail column shows.
        var selectedCardID: String?
        var preferredColumn: NavigationSplitViewColumn = .sidebar
        /// The machine whose terminals the detail column shows.
        var terminalMachineID: String?
        /// The machine whose screen the detail column shows.
        var screenMachineID: String?
        var sheet: IOSWorkspaceSheet?
        /// Attachments shared into a conversation, keyed by card ID, for its
        /// composer to take when it opens.
        var sharedAttachments: [String: [Dieter_V1_MessagePart]] = [:]

        /// Shows `destination` in the middle column.
        func show(_ destination: IOSWorkspaceDestination) {
            if self.destination != destination {
                selectedCardID = nil
                terminalMachineID = nil
                screenMachineID = nil
            }
            self.destination = destination
            preferredColumn = .content
        }

        /// Opens a conversation in the detail column.
        func openConversation(_ cardID: String) {
            selectedCardID = cardID
            preferredColumn = .detail
        }

        /// Opens a machine's terminals in the detail column.
        func openTerminals(_ machineID: String) {
            terminalMachineID = machineID
            preferredColumn = .detail
        }

        /// Opens a machine's screen in the detail column.
        func openScreen(_ machineID: String) {
            screenMachineID = machineID
            preferredColumn = .detail
        }

        /// Closes the open screen, back to the machine list.
        func closeScreen() {
            screenMachineID = nil
            preferredColumn = .content
        }

        /// Closes the open conversation, back to the list.
        func closeConversation() {
            selectedCardID = nil
            preferredColumn = .content
        }

        /// Composes a new task, or a chat, preferring `boardID`'s board.
        func create(chat: Bool, projectID: String = "", boardID: String = "", attachments: [Dieter_V1_MessagePart] = [])
        {
            sheet = .create(
                IOSCreateRequest(chat: chat, projectID: projectID, boardID: boardID, attachments: attachments))
        }
    }
#endif
