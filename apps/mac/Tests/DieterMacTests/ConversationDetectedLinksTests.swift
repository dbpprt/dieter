import AppKit
import Testing
@testable import DieterMac

@MainActor struct ConversationDetectedLinksTests {
    @Test func bareDevelopmentAddressesRemainMonospacedAndOpenAsWebLinks() throws {
        let text = MessageTextView.attributedText(
            source: "API at `127.0.0.1:14010` and UI at `127.0.0.1:4018`. Also localhost:3000/path?q=1 and [::1]:8080.",
            color: .labelColor)
        for (label, destination) in [
            ("127.0.0.1:14010", "http://127.0.0.1:14010"),
            ("127.0.0.1:4018", "http://127.0.0.1:4018"),
            ("localhost:3000/path?q=1", "http://localhost:3000/path?q=1"),
            ("[::1]:8080", "http://[::1]:8080"),
        ] {
            let index = (text.string as NSString).range(of: label).location
            #expect((text.attribute(.link, at: index, effectiveRange: nil) as? URL)?.absoluteString == destination)
        }
        let font = try #require(
            text.attribute(
                .font, at: (text.string as NSString).range(of: "127.0.0.1:4018").location, effectiveRange: nil)
                as? NSFont)
        #expect(font.isFixedPitch)
    }

    @Test func preservesExplicitLinksAndTrimsSentencePunctuation() {
        let text = MessageTextView.attributedText(
            source: "[localhost:4018](https://example.com/actual) and (https://example.com/path?q=1).",
            color: .labelColor)
        let explicit = (text.string as NSString).range(of: "localhost:4018")
        #expect(
            (text.attribute(.link, at: explicit.location, effectiveRange: nil) as? URL)?.absoluteString
                == "https://example.com/actual")
        let detected = (text.string as NSString).range(of: "https://example.com/path?q=1")
        #expect(
            (text.attribute(.link, at: detected.location, effectiveRange: nil) as? URL)?.absoluteString
                == "https://example.com/path?q=1")
        #expect(text.attribute(.link, at: NSMaxRange(detected), effectiveRange: nil) == nil)
    }

    @Test func doesNotTurnSourceLocationsOrMalformedAddressesIntoLinks() {
        for source in [
            "App.swift:42", "README.md", "999.0.0.1:4018", "localhost:99999", "localhost:0", "thing127.0.0.1:4018",
            "```\n127.0.0.1:4018\n```",
        ] {
            let text = MessageTextView.attributedText(source: source, color: .labelColor)
            var links = 0
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if value != nil { links += 1 }
            }
            #expect(links == 0, "Unexpected web link in \(source)")
        }
    }
}
