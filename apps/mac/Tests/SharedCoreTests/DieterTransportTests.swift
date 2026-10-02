import DieterTransport
import GRPCNIOTransportHTTP2
import Testing

@Test func transportTargetsDoNotSendIPAddressesAsTLSServerNames() {
    #expect(DieterTransportTarget.hostKind("127.0.0.1") == .ipv4)
    #expect(DieterTransportTarget.hostKind("::1") == .ipv6)
    #expect(DieterTransportTarget.hostKind("fe80::1%en0") == .ipv6)
    #expect(DieterTransportTarget.hostKind("gateway.getdieter.com") == .dns)

    #expect(DieterTransportTarget.make(host: "127.0.0.1", port: 4242) is ResolvableTargets.IPv4)
    #expect(DieterTransportTarget.make(host: "::1", port: 4242) is ResolvableTargets.IPv6)
    #expect(DieterTransportTarget.make(host: "gateway.getdieter.com", port: 443) is ResolvableTargets.DNS)
}
