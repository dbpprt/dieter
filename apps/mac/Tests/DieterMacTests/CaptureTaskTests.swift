import Testing
@testable import DieterMac

@Test func captureBrowserURLKeepsOnlyWebPageURLs() {
    #expect(CaptureBrowserContext.validatedURL(" https://example.com/path?q=task#issue ") == "https://example.com/path?q=task#issue")
    #expect(CaptureBrowserContext.validatedURL("http://localhost:3000/issue") == "http://localhost:3000/issue")
    for value in ["", "Search or enter address", "file:///private/data", "javascript:alert(1)", "chrome://settings", "https://", "not a URL"] {
        #expect(CaptureBrowserContext.validatedURL(value) == nil)
    }
}

@Test func captureFromNonBrowserHasNoURL() async {
    let result = await CaptureBrowserContext.read(bundleID: "com.apple.finder", pid: nil)
    #expect(!result.browser)
    #expect(result.url.isEmpty)
}
