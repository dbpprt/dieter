import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@Test func activeChatRuntimeAliasesReceiveTheRunningTreatment() {
    for runtime in ["running", "RUNNING", "starting", "working", "streaming"] {
        #expect(ChatRuntimePresentation.isActive(runtime))
    }
    for runtime in ["", "idle", "waiting_for_user", "completed", "failed"] {
        #expect(!ChatRuntimePresentation.isActive(runtime))
    }
}

@Test @MainActor func runningIndicatorUsesCompositorAnimationsAndHonorsReducedMotion() {
    let view = ChatRunningIndicatorView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
    view.layoutSubtreeIfNeeded()

    view.configure(color: .blue, animates: true)
    #expect(view.layer?.sublayers?.filter { !($0.animationKeys() ?? []).isEmpty }.count == 2)
    #expect(view.appliedConfigurationCount == 1)

    view.configure(color: .blue, animates: true)
    #expect(view.appliedConfigurationCount == 1)

    view.configure(color: .blue, animates: false)
    #expect(view.layer?.sublayers?.allSatisfy { ($0.animationKeys() ?? []).isEmpty } == true)
    #expect(view.appliedConfigurationCount == 2)

    view.configure(color: .blue, animates: false)
    #expect(view.appliedConfigurationCount == 2)

    view.configure(color: .red, animates: false)
    #expect(view.appliedConfigurationCount == 3)
}
