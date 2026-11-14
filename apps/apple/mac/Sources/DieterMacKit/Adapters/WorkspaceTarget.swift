import Foundation

/// A command destination, independent of the currently presented surface:
/// a machine (`origin#daemon`), a project checkout on it, a conversation, or
/// a synced folder member's directory on it (`folderID`, without a project).
package struct WorkspaceTarget: Hashable, Codable, Sendable {
    package var endpointID: String
    package var projectID: String
    package var conversationID: String
    package var checkoutID: String
    package var folderID: String

    package init(
        endpointID: String, projectID: String, conversationID: String = "", checkoutID: String = "",
        folderID: String = ""
    ) {
        self.endpointID = endpointID
        self.projectID = projectID
        self.conversationID = conversationID
        self.checkoutID = checkoutID
        self.folderID = folderID
    }

    private enum CodingKeys: String, CodingKey {
        case endpointID, projectID, conversationID, checkoutID, folderID
    }

    /// Targets encoded before folders decode without one.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpointID = try container.decode(String.self, forKey: .endpointID)
        projectID = try container.decode(String.self, forKey: .projectID)
        conversationID = try container.decode(String.self, forKey: .conversationID)
        checkoutID = try container.decode(String.self, forKey: .checkoutID)
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID) ?? ""
    }

    /// The daemon of a machine target (`origin#daemon`); the core addresses
    /// machines by daemon.
    package var daemonID: String {
        endpointID.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }
}
