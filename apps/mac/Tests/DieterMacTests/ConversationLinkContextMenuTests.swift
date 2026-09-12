import AppKit
import Foundation
import Testing
@testable import DieterMac

@Test @MainActor func nativeLinkMenuTargetsTheClickedLinkAndPreservesSelection() async throws {
    let text = MessageTextView()
    text.update(source: "Read [plan](docs/plan.md) or [source](Sources/App.swift#L42).", color: .labelColor)
    let selection = NSRange(location: 0, length: 4)
    text.setSelectedRange(selection)
    let destination = URL(fileURLWithPath: "/workspace/Sources/App.swift")
    let application = URL(fileURLWithPath: "/Applications/Test Editor.app")
    var resolved = [URL]()
    var opened = [(URL, URL?)]()
    var revealed = [URL]()
    text.linkDelegate.externalResolver = { url in
        resolved.append(url)
        return ConversationLinkExternalTarget(
            applications: [.init(url: application, name: "Test Editor", isDefault: true)],
            revalidate: { destination })
    }
    text.linkDelegate.handler = { _ in true }
    text.linkDelegate.openExternal = { opened.append(($0, $1)) }
    text.linkDelegate.revealExternal = { revealed.append($0) }
    let original = NSMenu()
    original.addItem(withTitle: "Open Link", action: nil, keyEquivalent: "")
    let index = (text.string as NSString).range(of: "source").location + 2
    let menu = text.linkDelegate.contextMenu(original, textView: text, at: index)
    await text.linkDelegate.waitForExternalMenu()
    #expect(menu !== original)
    #expect(menu.item(withTitle: "Open Link") == nil, "System opening must not bypass workspace validation")
    #expect(resolved.map(\.relativeString) == ["Sources/App.swift#L42"])
    #expect(text.selectedRange() == selection)
    let applications = try #require(menu.item(withTitle: "Open in…")?.submenu)
    let choice = try #require(applications.item(withTitle: "Test Editor (Default)"))
    #expect(choice.image != nil)
    activateLinkMenuItem(choice)
    activateLinkMenuItem(try #require(menu.item(withTitle: "Show in Finder")))
    #expect(opened.count == 1 && opened.first?.0 == destination && opened.first?.1 == application)
    #expect(revealed == [destination])
    #expect(text.linkDelegate.contextMenu(original, textView: text, at: 0) === original)
    #expect(text.linkDelegate.contextMenu(original, textView: text, at: text.string.utf16.count) === original)
    #expect(text.linkDelegate.responds(to: NSSelectorFromString("textView:menu:forEvent:atIndex:")))
}

@Test @MainActor func remoteLinkMenuKeepsPaneAndCopyActionsButDisablesExternalOpening() async throws {
    let text = MessageTextView()
    text.update(source: "[Remote report](reports/result.md)", color: .labelColor)
    var presented = [URL]()
    text.linkDelegate.handler = {
        presented.append($0); return true
    }
    text.linkDelegate.externalResolver = { _ in
        .unavailable("This file is on another machine. Open in Dieter to save a local copy.")
    }
    let menu = text.linkDelegate.contextMenu(NSMenu(), textView: text, at: 5)
    await text.linkDelegate.waitForExternalMenu()
    #expect(menu.item(withTitle: "Show in Finder")?.isEnabled == false)
    let submenu = try #require(menu.item(withTitle: "Open in…")?.submenu)
    #expect(submenu.items.count == 1 && submenu.items[0].isEnabled == false)
    #expect(submenu.items[0].title.contains("another machine"))
    #expect(menu.item(withTitle: "Copy Link")?.isEnabled == true)
    activateLinkMenuItem(try #require(menu.item(withTitle: "Open in Dieter")))
    #expect(presented.map(\.relativeString) == ["reports/result.md"])
}

@Test @MainActor func linkMenuRevalidatesBeforeExternalActionsAndWebTargetsHaveNoFinder() async throws {
    let text = MessageTextView()
    text.update(source: "[Report](report.md)", color: .labelColor)
    var current = true
    var effects = 0
    text.linkDelegate.openExternal = { _, _ in effects += 1 }
    text.linkDelegate.revealExternal = { _ in effects += 1 }
    text.linkDelegate.externalResolver = { _ in
        ConversationLinkExternalTarget(revalidate: { current ? URL(fileURLWithPath: "/workspace/report.md") : nil })
    }
    let menu = text.linkDelegate.contextMenu(NSMenu(), textView: text, at: 3)
    await text.linkDelegate.waitForExternalMenu()
    current = false
    let applications = try #require(menu.item(withTitle: "Open in…")?.submenu)
    activateLinkMenuItem(try #require(applications.item(withTitle: "Default App")))
    activateLinkMenuItem(try #require(menu.item(withTitle: "Show in Finder")))
    #expect(effects == 0)

    text.update(source: "[Website](https://example.com)", color: .labelColor)
    text.linkDelegate.externalResolver = { url in
        ConversationLinkExternalTarget(isFile: false, revalidate: { url })
    }
    let webMenu = text.linkDelegate.contextMenu(NSMenu(), textView: text, at: 3)
    await text.linkDelegate.waitForExternalMenu()
    #expect(webMenu.item(withTitle: "Show in Finder") == nil)
}

@MainActor private func activateLinkMenuItem(_ item: NSMenuItem) {
    guard item.isEnabled, let action = item.action else { return }
    _ = NSApp.sendAction(action, to: item.target, from: item)
}
