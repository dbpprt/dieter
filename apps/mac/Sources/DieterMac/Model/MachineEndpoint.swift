import DieterShared
import Foundation

/// A gateway, or one of its machines (`origin#daemon`), as the Mac's views key
/// and show it. The session fold builds it from the core's gateway and machine
/// entries; it holds no rules of its own.
struct MachineEndpoint: Equatable, Hashable, Identifiable, Sendable {
    var id: String { credentialID + (daemonID.map { "#\($0)" } ?? "") }
    /// The gateway's origin, `https://host:port`, which keys its session.
    var credentialID: String { "\(secure ? "https" : "http")://\(host):\(port)" }
    var address: String { credentialID }
    var name: String
    var host: String
    var port: Int
    var secure: Bool
    var daemonID: String?
    var online: Bool
    var lastSeenAt: String
    var releaseVersion: String
    var minimumReleaseVersion: String
    var remoteDesktopReady: Bool
    var remoteDesktopReason: String
    var remoteDesktopPlatform: String

    init(
        name: String, host: String, port: Int, secure: Bool = false, daemonID: String? = nil, online: Bool = true,
        lastSeenAt: String = "", releaseVersion: String = "", minimumReleaseVersion: String = "",
        remoteDesktopReady: Bool = false, remoteDesktopReason: String = "", remoteDesktopPlatform: String = ""
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.secure = secure
        self.daemonID = daemonID
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.releaseVersion = releaseVersion
        self.minimumReleaseVersion = minimumReleaseVersion
        self.remoteDesktopReady = remoteDesktopReady
        self.remoteDesktopReason = remoteDesktopReason
        self.remoteDesktopPlatform = remoteDesktopPlatform
    }

    /// The gateway at an origin as the core writes it (`scheme://host:port`,
    /// e.g. `SessionSlice.gateway_origin` or `SharedRules.gatewayOrigin`);
    /// nil for an empty or other value.
    init?(origin: String, name: String) {
        let secure = origin.hasPrefix("https://")
        guard secure || origin.hasPrefix("http://") else { return nil }
        let authority = origin.dropFirst(secure ? 8 : 7)
        guard let colon = authority.lastIndex(of: ":"), let port = Int(authority[authority.index(after: colon)...]),
            colon > authority.startIndex
        else { return nil }
        self.init(name: name, host: String(authority[..<colon]), port: port, secure: secure)
    }

    /// A gateway address as typed, when the core accepts it.
    init?(address: String, name: String) {
        self.init(origin: SharedRules.shared.gatewayOrigin(address: address), name: name)
    }

    /// The built-in gateway, before the core reports the configured ones.
    static var defaultGateway: MachineEndpoint {
        let origin = SharedRules.shared.defaultGatewayOrigin()
        return MachineEndpoint(origin: origin, name: SharedRules.shared.defaultGatewayName())
            ?? MachineEndpoint(name: SharedRules.shared.defaultGatewayName(), host: origin, port: 443, secure: true)
    }

    /// Whether this is the built-in gateway, which lists mark as primary.
    var isPrimaryGateway: Bool { credentialID == SharedRules.shared.defaultGatewayOrigin() }
}

/// The connection as the Mac's views branch on it, folded from the core's
/// session phase.
enum ConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case authenticationRequired
    /// The core's reason this client must update before it can connect.
    case incompatible(String)
    case failed(String)

    var isConnected: Bool { self == .connected }

    /// The onboarding overlay covers the window only to ask for sign-in.
    var needsConnectionOverlay: Bool { self == .authenticationRequired }
}
