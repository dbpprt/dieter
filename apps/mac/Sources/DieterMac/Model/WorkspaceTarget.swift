import Foundation

/// A command destination, independent of the currently presented surface.
struct WorkspaceTarget: Hashable, Codable, Sendable {
    var endpointID: String
    var projectID: String
    var conversationID: String
    var checkoutID: String

    init(endpointID: String, projectID: String, conversationID: String = "", checkoutID: String = "") {
        self.endpointID = endpointID
        self.projectID = projectID
        self.conversationID = conversationID
        self.checkoutID = checkoutID
    }
}
