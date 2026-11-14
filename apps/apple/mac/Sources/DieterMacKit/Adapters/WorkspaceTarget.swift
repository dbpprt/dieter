import Foundation

/// A command destination, independent of the currently presented surface:
/// a machine (`origin#daemon`), a project checkout on it, or a conversation.
package struct WorkspaceTarget: Hashable, Codable, Sendable {
    package var endpointID: String
    package var projectID: String
    package var conversationID: String
    package var checkoutID: String

    package init(endpointID: String, projectID: String, conversationID: String = "", checkoutID: String = "") {
        self.endpointID = endpointID
        self.projectID = projectID
        self.conversationID = conversationID
        self.checkoutID = checkoutID
    }

    /// The daemon of a machine target (`origin#daemon`); the core addresses
    /// machines by daemon.
    package var daemonID: String {
        endpointID.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }
}
