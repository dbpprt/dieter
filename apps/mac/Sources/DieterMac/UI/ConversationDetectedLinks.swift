import AppKit
import Foundation

/// Recognizes web destinations in rendered prose and inline code while keeping
/// authored Markdown links and their labels unchanged.
@MainActor enum ConversationDetectedLinks {
    private static let localAddress = try? NSRegularExpression(
        pattern:
            #"(?i)(?<![a-z0-9_./@:\-])(?:localhost|\[::1\]|(?:[0-9]{1,3}\.){3}[0-9]{1,3}):[0-9]{1,5}(?![a-z0-9_])(?:[/?#][^\s<>"`]+)?"#
    )
    private static let webLinks = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func apply(to text: NSMutableAttributedString) {
        let source = text.string as NSString
        let whole = NSRange(location: 0, length: source.length)
        for match in localAddress?.matches(in: text.string, range: whole) ?? [] {
            let range = trimmedRange(match.range, in: source)
            let address = source.substring(with: range)
            guard let components = URLComponents(string: "http://" + address),
                let host = components.host, let port = components.port, (1...65535).contains(port),
                validLocalAddressHost(host), let url = components.url
            else { continue }
            add(url, range: range, to: text)
        }
        for match in webLinks?.matches(in: text.string, range: whole) ?? [] {
            let range = trimmedRange(match.range, in: source)
            let value = source.substring(with: range)
            // Plain hostnames can also be filenames. Only infer a scheme for
            // the explicit host:port address forms handled above.
            guard value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://"),
                let components = URLComponents(string: value), components.host?.isEmpty == false,
                components.user == nil, components.password == nil,
                components.port.map({ (1...65535).contains($0) }) ?? true,
                let url = components.url
            else { continue }
            add(url, range: range, to: text)
        }
    }

    private static func validLocalAddressHost(_ host: String) -> Bool {
        if ["localhost", "[::1]", "::1"].contains(host.lowercased()) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private static func trimmedRange(_ range: NSRange, in text: NSString) -> NSRange {
        var value = text.substring(with: range)
        var balance: [Character: Int] = [")": 0, "]": 0, "}": 0]
        for character in value {
            switch character {
            case "(": balance[")", default: 0] -= 1
            case "[": balance["]", default: 0] -= 1
            case "{": balance["}", default: 0] -= 1
            case ")", "]", "}": balance[character, default: 0] += 1
            default: break
            }
        }
        while let last = value.last {
            if ".,;!".contains(last) { value.removeLast(); continue }
            if balance[last, default: 0] > 0 {
                balance[last, default: 0] -= 1
                value.removeLast(); continue
            }
            break
        }
        return NSRange(location: range.location, length: (value as NSString).length)
    }

    private static func add(_ url: URL, range: NSRange, to text: NSMutableAttributedString) {
        guard range.length > 0 else { return }
        var hasAuthoredLink = false
        text.enumerateAttribute(.link, in: range) { value, _, stop in
            if value != nil { hasAuthoredLink = true; stop.pointee = true }
        }
        if !hasAuthoredLink { text.addAttribute(.link, value: url, range: range) }
    }
}
