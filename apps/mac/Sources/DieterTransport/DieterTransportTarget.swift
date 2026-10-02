import Darwin
import GRPCNIOTransportHTTP2

/// gRPC resolver targets for a host and port. IP literals stay addresses so
/// they are never sent as TLS server names.
package enum DieterTransportTarget {
    package enum HostKind: Equatable {
        case ipv4
        case ipv6
        case dns
    }

    package static func hostKind(_ host: String) -> HostKind {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return .ipv4
        }

        // A scoped IPv6 address (for example, fe80::1%en0) is still a literal
        // address. inet_pton validates the address portion while the resolver
        // receives the original value including its interface scope.
        let ipv6Host =
            host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(
                String.init) ?? host
        var ipv6 = in6_addr()
        if ipv6Host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return .ipv6
        }

        return .dns
    }

    package static func make(host: String, port: Int) -> any ResolvableTarget {
        switch hostKind(host) {
        case .ipv4:
            ResolvableTargets.IPv4(addresses: [.init(host: host, port: port)])
        case .ipv6:
            ResolvableTargets.IPv6(addresses: [.init(host: host, port: port)])
        case .dns:
            ResolvableTargets.DNS(host: host, port: port)
        }
    }
}
