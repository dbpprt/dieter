import AppKit
import DieterAPI
import DieterShared
import Foundation

/// Links web destinations the shared core recognizes in rendered prose and
/// inline code, keeping authored Markdown links and their labels unchanged.
@MainActor enum ConversationDetectedLinks {
    static func apply(to text: NSMutableAttributedString) {
        let detected = ClientDetectedLinks(rules: SharedRules.shared.detectLinks(text: text.string))
        let length = text.length
        for link in detected.links {
            let range = NSRange(location: Int(link.start), length: Int(link.length))
            guard range.location >= 0, NSMaxRange(range) <= length, let url = URL(string: link.url) else { continue }
            add(url, range: range, to: text)
        }
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
