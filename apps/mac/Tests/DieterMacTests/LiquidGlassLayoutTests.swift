import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func glassQuickTaskKeepsCompactLayoutAcrossAppearancesAndControlSizes() {
    let suite = "glass-layout-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DieterStore(restoreSync: false)
    let draft = QuickTaskFormState(defaults: defaults)
    draft.initialized = true
    draft.story = "Investigate the selected browser page"

    for scheme in [ColorScheme.light, .dark] {
        for controlSize in [ControlSize.regular, .large] {
            let host = NSHostingView(
                rootView: QuickTaskPopover(isPresented: .constant(true), draft: draft, chooseDestination: true)
                    .environment(store)
                    .environment(\.colorScheme, scheme)
                    .controlSize(controlSize))
            let size = host.fittingSize
            // The popover must remain content-sized when native glass controls
            // change metrics, including the larger control-size variant.
            #expect(abs(size.width - 430) < 1)
            #expect(size.height > 300 && size.height < 580)
            #expect(draft.story == "Investigate the selected browser page")
        }
    }
}

@Test @MainActor func allChatsContinuousCanvasRendersAcrossAppearances() {
    defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }

    for scheme in [ColorScheme.light, .dark] {
        DieterTheme.install(palette: .monochrome, colorScheme: scheme)
        let fixture = HStack(spacing: 0) {
            VStack {
                DieterSearchField(text: .constant(""), placeholder: "Search chats")
                    .padding(16)
                Spacer()
            }
            .frame(width: 320)
            .background { DieterPaneBackground(role: .navigation) }

            Color.clear
                .frame(width: 600)
                .background { DieterPaneBackground(role: .content) }
        }
        .frame(height: 600)
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: fixture)
        renderer.proposedSize = .init(width: 920, height: 600)
        let image = renderer.nsImage
        #expect(image != nil)
        #expect(image?.size == NSSize(width: 920, height: 600))
    }
}

@Test @MainActor func conversationInspectorHeaderWrapsLongTitlesAtMinimumWidth() {
    let store = DieterStore(restoreSync: false)
    var card = Dieter_V1_Card()
    card.id = "inspector-layout"
    card.scope = "board"
    card.title = "Short title"
    card.workspaceMode = "project"
    store.state.cards = [card]
    store.selectedCardID = card.id

    func height() -> CGFloat {
        let host = NSHostingView(
            rootView: ConversationChrome(compact: true, standalone: false, tab: .constant("Conversation"))
                .environment(store)
                .environment(store.conversationContext)
                .frame(width: 320))
        let size = host.fittingSize
        #expect(abs(size.width - 320) < 1)
        return size.height
    }

    let shortHeight = height()
    card.title =
        "A long conversation title that needs several lines while keeping workspace and status controls readable"
    store.state.cards = [card]
    let longHeight = height()
    #expect(longHeight > shortHeight)
    #expect(longHeight < 240)
}
