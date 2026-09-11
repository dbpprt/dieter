import AppKit
import DieterAPI
import PDFKit
import Testing
@testable import DieterMac

@Test @MainActor func markdownExportSnapshotsCurrentDraftWithoutSavingOrUsingAnotherFile() throws {
    var document = Dieter_V1_FileDocument()
    document.name = "Report.final.md"
    document.content = "# Saved version"
    let session = FileEditorSession()
    session.prepare(documentKey: "project:report", text: document.content)
    #expect(session.applyReplacement("# Unsaved draft\n\nWith **formatting** 👋", documentKey: "project:report"))
    let revision = session.revision
    let snapshot = try #require(
        FileExternalActions.markdownExportDocument(document: document, session: session, documentKey: "project:report"))
    #expect(snapshot.source == session.currentText())
    #expect(snapshot.filename(for: .pdf) == "Report.final.pdf")
    #expect(snapshot.filename(for: .html) == "Report.final.html")
    #expect(session.isDirty && session.revision == revision)
    #expect(session.applyReplacement("A later edit", documentKey: "project:report"))
    #expect(snapshot.source == "# Unsaved draft\n\nWith **formatting** 👋")
    #expect(
        FileExternalActions.markdownExportDocument(document: document, session: session, documentKey: "other") == nil)
    document.binary = true
    #expect(
        FileExternalActions.markdownExportDocument(document: document, session: session, documentKey: "project:report")
            == nil)
    document.binary = false
    document.name = "report.txt"
    #expect(
        FileExternalActions.markdownExportDocument(document: document, session: session, documentKey: "project:report")
            == nil)
}

@Suite(.serialized)
@MainActor
struct MarkdownFileExportRenderingTests {
    @Test func markdownExportHTMLContainsFinishedOfflineSVGsAndMalformedBlockDiagnostics() async throws {
        let source =
            exportDiagramFixture + """

                ```vega-lite
                {malformed JSON}
                ```

                <script>alert('must remain text')</script>
                """
        let data = try await MarkdownFileExport.data(
            for: .init(name: "Report <final>.md", source: source), format: .html)
        let html = try #require(String(data: data, encoding: .utf8))
        #expect(html.contains("<title>Report &lt;final&gt;.md</title>"))
        #expect(html.contains("data-theme=\"light\""))
        #expect(html.components(separatedBy: "<svg").count == 3)
        #expect(html.contains("data-kind=\"mermaid\"") && html.contains("data-kind=\"vega-lite\""))
        #expect(html.contains("data-state=\"error\"") && html.contains("diagram-error"))
        #expect(html.contains("{malformed JSON}") && html.contains("<details open="))
        #expect(!html.contains("data-state=\"rendering\""))
        #expect(!html.contains("<script") && !html.contains("<link") && !html.contains("<iframe"))
        #expect(!html.contains(" src=") && !html.contains("dieter-markdown://"))
        #expect(html.contains("default-src 'none'") && html.contains("style-src 'unsafe-inline'"))
        #expect(html.contains("print-color-adjust: exact"))
    }

    @Test func markdownExportPDFPaginatesLongReportsWithRenderedChartsOnLightPages() async throws {
        let paragraphs = (1...65).map { index in
            "Report paragraph \(index). This text must remain readable and selectable across native PDF pages. "
                + "A longer report should continue onto another page instead of shrinking to a single image."
        }.joined(separator: "\n\n")
        let source = exportDiagramFixture + "\n\n" + paragraphs + "\n\nFinal report marker."
        let data = try await MarkdownFileExport.data(for: .init(name: "Long report.md", source: source), format: .pdf)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount >= 3)
        #expect(pdf.string?.contains("Export report") == true)
        #expect(pdf.string?.contains("Final report marker.") == true)
        for index in 0..<pdf.pageCount {
            let page = try #require(pdf.page(at: index))
            let bounds = page.bounds(for: .mediaBox)
            #expect(abs(bounds.width - 595.28) < 2)
            #expect(abs(bounds.height - 841.89) < 2)
        }
        // The unprinted page margin must be light regardless of the app theme.
        let page = try #require(pdf.page(at: 0))
        let thumbnail = page.thumbnail(of: NSSize(width: 300, height: 425), for: .mediaBox)
        let representation = try #require(thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let corner = try #require(representation.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
        #expect(corner.redComponent > 0.95 && corner.greenComponent > 0.95 && corner.blueComponent > 0.95)
    }
}

private let exportDiagramFixture = """
    # Export report

    Current **draft** with inline diagrams and chart data.

    ```mermaid
    flowchart LR
      Capture --> Review
    ```

    ```vega-lite
    {"width":1200,"height":240,"data":{"values":[{"name":"Alpha","value":3},{"name":"Beta","value":7}]},"mark":"bar","encoding":{"x":{"field":"name","type":"nominal"},"y":{"field":"value","type":"quantitative"}}}
    ```
    """
