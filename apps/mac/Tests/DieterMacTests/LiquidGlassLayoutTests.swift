import AppKit
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
