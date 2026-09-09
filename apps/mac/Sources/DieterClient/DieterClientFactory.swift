import DieterCore

/// A construction seam shared by gateway and direct/relay route admission.
package struct DieterClientFactory: Sendable {
    package var make: @Sendable (DieterEndpoint, String?, DieterRPC.Route, DieterRPC.DirectRoute?) throws -> DieterRPC

    package init(
        make: @escaping @Sendable (DieterEndpoint, String?, DieterRPC.Route, DieterRPC.DirectRoute?) throws -> DieterRPC
    ) {
        self.make = make
    }

    package func client(
        endpoint: DieterEndpoint, accessToken: String? = nil,
        route: DieterRPC.Route = .gateway, direct: DieterRPC.DirectRoute? = nil
    ) throws -> DieterRPC {
        try make(endpoint, accessToken, route, direct)
    }

    package static let live = DieterClientFactory {
        try DieterRPC(endpoint: $0, accessToken: $1, route: $2, direct: $3)
    }
}
