import Foundation

/// A command destination, independent of the currently presented surface.
public struct WorkspaceTarget: Hashable, Codable, Sendable {
    public var endpointID: String
    public var projectID: String
    public var conversationID: String

    public init(endpointID: String, projectID: String, conversationID: String = "") {
        self.endpointID = endpointID
        self.projectID = projectID
        self.conversationID = conversationID
    }

    public func documentKey(path: String) -> String {
        // Length-prefixed components cannot collide when paths contain separators.
        [endpointID, projectID, conversationID, path].map { "\($0.utf8.count):\($0)" }.joined()
    }
}
