import DieterAPI
import Testing
@testable import DieterMacKit

@Test func htmlDocumentsRenderAsSandboxedPreviews() {
    var document = Dieter_V1_FileDocument()
    document.name = "Landing page.html"
    #expect(FilePresentation.renderer(document) == .html)
    document.name = "notes.md"
    #expect(FilePresentation.renderer(document) == .markdown)
    #expect(HTMLFileMode.allCases == [.preview, .source])
}
