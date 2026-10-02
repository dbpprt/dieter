import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@Test @MainActor func boardMergeHoverArmsAfterTwoSecondsAndCancelsOnExit() async throws {
    let state = BoardCardDropState()
    let provider = NSItemProvider(object: "board-card|board|todo|source" as NSString)
    state.enter(provider) { _ in true }
    try await Task.sleep(for: .milliseconds(300))
    #expect(state.payload != nil)
    #expect(!state.mergeReady)
    state.reset()
    try await Task.sleep(for: .seconds(2))
    #expect(!state.mergeReady)
    state.enter(provider) { _ in true }
    try await Task.sleep(for: .milliseconds(2300))
    #expect(state.mergeReady)
    state.reset()
    #expect(!state.mergeReady)
    state.enter(provider) { _ in false }
    try await Task.sleep(for: .milliseconds(2300))
    #expect(!state.mergeReady)
    state.reset()
}
