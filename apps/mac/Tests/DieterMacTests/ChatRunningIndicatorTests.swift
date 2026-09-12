import AppKit
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

    view.configure(color: .systemBlue, animates: true)
    #expect(view.layer?.sublayers?.filter { !($0.animationKeys() ?? []).isEmpty }.count == 2)

    view.configure(color: .systemBlue, animates: false)
    #expect(view.layer?.sublayers?.allSatisfy { ($0.animationKeys() ?? []).isEmpty } == true)
}
