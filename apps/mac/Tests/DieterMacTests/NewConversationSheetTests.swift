import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@MainActor
struct NewConversationSheetTests {
    @Test func taskEditorSupportsNativeMultilineEditingAndScrollsLongTasks() async throws {
        let fixture = NewConversationSheetFixture()
        defer { fixture.window.close() }
        await fixture.settle()

        let editor = try #require(fixture.taskEditor)
        #expect(editor.isEditable && editor.isSelectable && !editor.isFieldEditor)
        #expect(fixture.window.makeFirstResponder(editor))
        editor.insertText("First line", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        editor.insertText("Second line", replacementRange: editor.selectedRange())
        await fixture.settle()
        #expect(editor.string == "First line\nSecond line")
        #expect(fixture.window.firstResponder === editor)

        let extra = (3...45).map { "\nTask line \($0) with enough detail to review." }.joined()
        editor.insertText(extra, replacementRange: editor.selectedRange())
        await fixture.settle()
        let scroll = try #require(editor.enclosingScrollView)
        #expect(editor.string.components(separatedBy: "\n").count == 45)
        #expect(editor.bounds.height > scroll.contentView.bounds.height)
        editor.scrollRangeToVisible(NSRange(location: (editor.string as NSString).length, length: 0))
        #expect(scroll.documentVisibleRect.maxY > scroll.contentView.bounds.height)

        // A surrounding form update must keep the TextEditor binding, content,
        // and caret rather than replacing it with a fresh native editor.
        fixture.store.state.project.name = "Renamed fixture project"
        fixture.store.state.projects = [fixture.store.state.project]
        await fixture.settle()
        let retainedEditor = try #require(fixture.taskEditor)
        #expect(retainedEditor.string == "First line\nSecond line" + extra)
        #expect(retainedEditor.selectedRange().location == (retainedEditor.string as NSString).length)
        #expect(fixture.window.firstResponder === retainedEditor)

        let form = try #require(
            fixture.views.compactMap { $0 as? NSScrollView }.filter { $0 !== scroll }.max {
                $0.bounds.height < $1.bounds.height
            })
        let formFrame = form.convert(form.bounds, to: fixture.root)
        #expect(abs(fixture.root.bounds.width - 600) < 1)
        #expect(abs(fixture.root.bounds.height - 680) < 1)
        #expect(formFrame.maxY <= fixture.root.bounds.maxY - 48)
    }

}

@MainActor
private final class NewConversationSheetFixture {
    let store: DieterStore
    let root: NSView
    let window: NSWindow

    init() {
        let store = DieterStore(restoreSync: false)
        var project = Dieter_V1_Project()
        project.id = "native-creation-project"
        project.name = "Native creation fixture"
        var board = Dieter_V1_Board()
        board.id = "native-creation-board"
        board.projectID = project.id
        board.name = "Main"
        var todo = Dieter_V1_Lane()
        todo.id = "todo"; todo.name = "Todo"
        var running = Dieter_V1_Lane()
        running.id = "running"; running.name = "Running"
        board.lanes = [todo, running]
        store.state.project = project
        store.state.projects = [project]
        store.state.boards = [board]
        store.selectedProjectID = project.id
        store.selectedBoardID = board.id
        let endpointID = "native-creation-machine"
        store.projectEndpointIDs[project.id] = endpointID
        store.harnessCatalogsByEndpoint[endpointID] = Self.catalog
        self.store = store

        let host = NSHostingView(rootView: NewConversationSheet().environment(store))
        host.sizingOptions = []
        root = host
        window = NSWindow(
            contentRect: NSRect(x: -3_000, y: -3_000, width: 600, height: 680),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    var views: [NSView] { descendants(of: root) }

    var taskEditor: NSTextView? {
        views.compactMap { $0 as? NSTextView }.first { $0.isEditable && !$0.isFieldEditor }
    }

    func settle() async {
        root.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(160))
        root.layoutSubtreeIfNeeded()
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private static var catalog: Dieter_V1_HarnessCatalog {
        var thinking = Dieter_V1_HarnessModel()
        thinking.id = "native-thinking"; thinking.name = "Thinking model"
        thinking.efforts = ["low", "high"]; thinking.defaultEffort = "high"
        var instant = Dieter_V1_HarnessModel()
        instant.id = "native-instant"; instant.name = "Instant model"
        var provider = Dieter_V1_Harness()
        provider.id = "native-creation-provider"; provider.name = "Fixture provider"
        provider.defaultModel = thinking.id; provider.models = [thinking, instant]
        provider.effort.options = thinking.efforts.map { id in
            var option = Dieter_V1_EffortOption()
            option.id = id; option.name = id.capitalized
            return option
        }
        var alternate = Dieter_V1_HarnessModel()
        alternate.id = "native-alternate"; alternate.name = "Alternate model"
        var alternateProvider = Dieter_V1_Harness()
        alternateProvider.id = "native-alternate-provider"; alternateProvider.name = "Alternate provider"
        alternateProvider.defaultModel = alternate.id; alternateProvider.models = [alternate]
        var catalog = Dieter_V1_HarnessCatalog()
        catalog.harnesses = [provider, alternateProvider]
        return catalog
    }
}
