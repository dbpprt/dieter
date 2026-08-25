import Foundation

struct DieterEndpoint: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { credentialID + (daemonID.map { "#\($0)" } ?? "") }
    var credentialID: String { "\(secure ? "https" : "http")://\(host):\(port)" }
    var name: String
    var host: String
    var port: Int
    var secure: Bool
    var daemonID: String?
    var online: Bool
    var lastSeenAt: String
    var version: String
	var remoteDesktopReady: Bool
	var remoteDesktopReason: String
	var remoteDesktopPlatform: String

    var address: String { "\(secure ? "https" : "http")://\(host):\(port)" }
    var gatewayEndpoint: DieterEndpoint {
        guard daemonID != nil else { return self }
        return DieterEndpoint(name: "Dieter Gateway", host: host, port: port, secure: secure)
    }

    static let defaults = [
        DieterEndpoint(name: "Dieter Gateway", host: "board.dbpprt.com", port: 443, secure: true),
    ]

    static func parse(_ value: String, name: String = "Custom") -> DieterEndpoint? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let secure = lower.hasPrefix("https://") || lower.hasPrefix("grpcs://")
        for prefix in ["grpcs://", "https://", "grpc://", "http://"] where trimmed.lowercased().hasPrefix(prefix) { trimmed.removeFirst(prefix.count) }
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let suffix = String(trimmed[trimmed.index(after: close)...])
            guard !host.isEmpty, suffix.isEmpty || suffix.hasPrefix(":") else { return nil }
            let port = suffix.isEmpty ? (secure ? 443 : 4242) : Int(suffix.dropFirst())
            guard let port, (1...65_535).contains(port) else { return nil }
            return DieterEndpoint(name: name, host: host, port: port, secure: secure)
        }
        let colonCount = trimmed.filter { $0 == ":" }.count
        guard colonCount <= 1 else { return nil }
        if let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<colon])
            guard let port = Int(trimmed[trimmed.index(after: colon)...]), !host.isEmpty, (1...65_535).contains(port) else { return nil }
            return DieterEndpoint(name: name, host: host, port: port, secure: secure)
        }
        return DieterEndpoint(name: name, host: trimmed, port: secure ? 443 : 4242, secure: secure)
    }

	private enum CodingKeys: String, CodingKey {
		case name, host, port, secure, daemonID, online, lastSeenAt, version
		case remoteDesktopReady, remoteDesktopReason, remoteDesktopPlatform
	}
    init(
        name: String,
        host: String,
        port: Int,
        secure: Bool = false,
        daemonID: String? = nil,
        online: Bool = true,
        lastSeenAt: String = "",
		version: String = "",
		remoteDesktopReady: Bool = false,
		remoteDesktopReason: String = "",
		remoteDesktopPlatform: String = ""
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.secure = secure
        self.daemonID = daemonID
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.version = version
		self.remoteDesktopReady = remoteDesktopReady
		self.remoteDesktopReason = remoteDesktopReason
		self.remoteDesktopPlatform = remoteDesktopPlatform
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name); host = try values.decode(String.self, forKey: .host); port = try values.decode(Int.self, forKey: .port)
        secure = try values.decodeIfPresent(Bool.self, forKey: .secure) ?? false
        daemonID = try values.decodeIfPresent(String.self, forKey: .daemonID)
        online = try values.decodeIfPresent(Bool.self, forKey: .online) ?? true
        lastSeenAt = try values.decodeIfPresent(String.self, forKey: .lastSeenAt) ?? ""
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? ""
		remoteDesktopReady = try values.decodeIfPresent(Bool.self, forKey: .remoteDesktopReady) ?? false
		remoteDesktopReason = try values.decodeIfPresent(String.self, forKey: .remoteDesktopReason) ?? ""
		remoteDesktopPlatform = try values.decodeIfPresent(String.self, forKey: .remoteDesktopPlatform) ?? ""
    }
}

enum ConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(version: String)
    case authenticationRequired
    case incompatible(found: String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .authenticationRequired: "Sign in required"
        case .incompatible: "Update required"
        case .failed: "Connection failed"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var needsConnectionOverlay: Bool {
        self == .authenticationRequired
    }
}

enum MachinePresenceText {
    static let offlineAfter: TimeInterval = 30

    static func online(serverOnline: Bool, lastSeenAt: String, relativeTo now: Date = Date()) -> Bool {
        guard serverOnline else { return false }
        guard parse(lastSeenAt) != nil else { return true }
        return isFresh(lastSeenAt, relativeTo: now)
    }

    static func isFresh(_ value: String, relativeTo now: Date = Date()) -> Bool {
        guard let date = parse(value) else { return false }
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < offlineAfter
    }

    static func freshestAge(_ values: [String], relativeTo now: Date = Date()) -> String? {
        guard let date = values.compactMap(parse).max() else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s ago"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    static func lastSeen(_ value: String, relativeTo now: Date = Date()) -> String {
        guard let date = parse(value) else { return "Last seen unknown" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "Last seen just now"
        case ..<3_600: return "Last seen \(seconds / 60)m ago"
        case ..<86_400: return "Last seen \(seconds / 3_600)h ago"
        default: return "Last seen \(seconds / 86_400)d ago"
        }
    }

    private static func parse(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
