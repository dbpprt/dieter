import DieterAPI
import Foundation
import Testing
@testable import DieterMacKit

/// File documents as the editor reads their bytes.
struct FileDocumentTests {
    @Test func fileDocumentsPreserveTheirBytes() {
        var document = Dieter_V1_FileDocument()
        document.binary = true
        document.content = "ignored"
        document.data = Data([0, 1, 2])
        #expect(document.bytes == Data([0, 1, 2]))
        document.binary = false
        document.content = "hello"
        #expect(document.bytes == Data("hello".utf8))
    }
}
