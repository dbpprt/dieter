import AppKit
import DieterAPI
import DieterCore
import Foundation
import Observation

struct ConversationContentScope {
    let target: WorkspaceTarget
    let rootPath: String
    let client: any FilesRPC
    var card: Dieter_V1_Card? = nil
    var doneLaneID: String? = nil
    var machineName = "Machine"
    var terminalsClient: (any TerminalsRPC)? = nil
    var worktreeClient: (any WorktreeRPC)? = nil
    var projectChangesClient: (any ProjectChangesRPC)? = nil
    var processesClient: (any ProcessesRPC)? = nil
    var workspaceMode = "worktree"
    var projectName = "Project"
}

enum ConversationPanelKind: String, CaseIterable, Identifiable {
    case review, terminal, browser, files, processes
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .review: "arrow.triangle.branch"
        case .terminal: "terminal"
        case .browser: "globe"
        case .files: "folder"
        case .processes: "gearshape.2"
        }
    }
}

/// Each tab owns its editor, browser and scoped transport state. Moving between
/// tabs never replaces another document's live buffer or native undo history.
@MainActor @Observable
final class ConversationContentTab: Identifiable {
    let id = UUID()
    let kind: ConversationPanelKind
    let conversationID: String
    let files = FilesModel()
    let tree = ConversationFileTreeModel()
    let browser = ConversationBrowserModel()
    let terminals = TerminalsModel()
    let review = WorktreeChangesModel()
    let projectReview = ProjectChangesModel()
    let processes = ConversationProcessesModel()
    var usesProjectReview = false
    var transportRevision = 0
    var transportsLive = false
    var selection: ConversationContentLink?
    var presentationTitle: String?
    var sourceURL: URL?
    var rootPath = ""
    var navigationID = UUID()
    var loading = false
    var error: String?
    var showFileNavigator = true
    @ObservationIgnored var scope: ConversationContentScope?

    init(kind: ConversationPanelKind, conversationID: String) {
        self.kind = kind
        self.conversationID = conversationID
    }

    var title: String {
        if let presentationTitle, !presentationTitle.isEmpty { return presentationTitle }
        return switch selection {
        case .file(let path, _): (path as NSString).lastPathComponent
        case .web(let url): browser.currentURL?.host ?? url.host ?? "Browser"
        case nil: kind.title
        }
    }
    var dirty: Bool { files.fileEditorSession.isDirty }
    var symbol: String {
        if case .file(let path, _) = selection {
            return ProjectFileLanguage.detect(filename: path) == .markdown ? "doc.richtext" : "doc.text"
        }
        return kind.symbol
    }
}

@MainActor @Observable
final class ConversationContentModel {
    static let maximumTabs = 12
    private(set) var tabs: [ConversationContentTab] = []
    private(set) var selectedTabID: UUID?
    private(set) var conversationID = ""
    private(set) var endpointID = ""
    private(set) var isOpen = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var confirming = false
    @ObservationIgnored private let emptyFiles = FilesModel()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var bindingTask: Task<Void, Never>?
    @ObservationIgnored private var bindingGeneration = 0
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var pendingTab: ConversationContentTab?
    @ObservationIgnored var currentEndpointID: @MainActor (String) -> String? = { _ in nil }
    @ObservationIgnored var validateWebURL: @MainActor (URL, String) throws -> Void = { _, _ in }
    @ObservationIgnored var onSaveFailure: (String) -> Void = { _ in }
    @ObservationIgnored var onReviewSendMessage: @MainActor (String, Dieter_V1_Card, WorkspaceTarget) async -> Bool = {
        _, _, _ in false
    }
    @ObservationIgnored var onReviewCard: @MainActor (Dieter_V1_Card) -> Void = { _ in }
    @ObservationIgnored var onReviewOperationFinished: @MainActor (WorkspaceTarget) async -> Void = { _ in }
    @ObservationIgnored var onReviewTransportFailure: @MainActor (Error, any WorktreeRPC) -> Void = { _, _ in }
    @ObservationIgnored var prepareScope: @MainActor (String) async throws -> ConversationContentScope = { _ in
        throw CocoaError(.fileReadNoPermission)
    }
    @ObservationIgnored var resolveExternalLink: @MainActor (URL, String) async -> ConversationLinkExternalTarget = {
        _, _ in
        .unavailable("This conversation's workspace is unavailable.")
    }
    @ObservationIgnored var confirmUnsaved: @MainActor (String) async -> UnsavedChoice = { name in
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(name)”?"
        alert.informativeText = "Save your edits before closing this document."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
    enum UnsavedChoice { case save, discard, cancel }

    var selectedTab: ConversationContentTab? { tabs.first { $0.id == selectedTabID } }
    var files: FilesModel { selectedTab?.files ?? emptyFiles }
    var selection: ConversationContentLink? { selectedTab?.selection }
    var sourceURL: URL? { selectedTab?.sourceURL }
    var rootPath: String { selectedTab?.rootPath ?? "" }
    var navigationID: UUID { selectedTab?.navigationID ?? selectedTabID ?? UUID() }
    var browserAllowsLoopback: Bool { selectedTab?.browser.allowsLoopback ?? false }
    func isPresented(for id: String?) -> Bool {
        isOpen && id == conversationID && endpointID == (currentEndpointID(conversationID) ?? "")
    }

    func requestOpen(
        _ url: URL, conversationID id: String, relativeTo documentPath: String? = nil, presentationTitle: String? = nil
    ) {
        guard !confirming else { return }
        cancelPending()
        openTask = Task {
            _ = await open(url, conversationID: id, relativeTo: documentPath, presentationTitle: presentationTitle)
        }
    }

    func requestPanel(_ kind: ConversationPanelKind, conversationID id: String) {
        guard !confirming else { return }
        cancelPending()
        openTask = Task { _ = await openPanel(kind, conversationID: id) }
    }

    func showEmpty(conversationID id: String) {
        guard !confirming, !id.isEmpty else { return }
        if conversationID == id, endpointID == (currentEndpointID(id) ?? "") { isOpen = true; resume(); return }
        cancelPending()
        openTask = Task {
            if await enterConversation(id) { isOpen = true; updateActivity() }
        }
    }

    func hide() {
        cancelPending()
        isOpen = false
        loading = false
        updateActivity()
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }), !confirming else { return }
        selectedTabID = id
        suspended = false
        isOpen = true
        error = nil
        updateActivity()
    }

    @discardableResult
    func open(
        _ url: URL, conversationID id: String, relativeTo documentPath: String? = nil, presentationTitle: String? = nil
    ) async -> Bool {
        guard !confirming, await enterConversation(id), !Task.isCancelled else { return false }
        generation &+= 1
        let request = generation
        loading = true; error = nil; isOpen = true
        defer { if request == generation { loading = false; pendingTab = nil } }
        do {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                try validateWebURL(url, id)
                let link = try ConversationContentLink.resolve(url, workspaceRoot: "")
                if let existing = tabs.first(where: { $0.selection == link }) {
                    existing.browser.reveal(url)
                    applyTitle(presentationTitle, to: existing)
                    selectTab(existing.id); return true
                }
                guard hasCapacity else { return false }
                let tab = ConversationContentTab(kind: .browser, conversationID: id)
                tab.browser.allowsLoopback = (try? validateWebURL(URL(string: "http://localhost")!, id)) != nil
                tab.selection = link; tab.sourceURL = url
                applyTitle(presentationTitle, to: tab)
                append(tab)
                return true
            }
            let scope = try await prepareScope(id)
            guard owns(request, id) else { return false }
            rebindRetainedTabs(scope: scope)
            let link = try ConversationContentLink.resolve(url, workspaceRoot: scope.rootPath, relativeTo: documentPath)
            guard case .file(let path, _) = link else { return false }
            if let existing = tabs.first(where: { tab in
                guard tab.files.target == scope.target, case .file(let existingPath, _) = tab.selection else {
                    return false
                }
                return existingPath == path
            }) {
                existing.selection = link; existing.sourceURL = url; existing.navigationID = UUID()
                applyTitle(presentationTitle, to: existing)
                selectTab(existing.id)
                if existing.files.fileDocument != nil, existing.files.fileError == nil { return true }
                existing.files.cancelContentRead()
                pendingTab = existing
                await existing.files.openFile(path: path)
                return owns(request, id)
            }
            guard hasCapacity else { return false }
            let tab = ConversationContentTab(kind: .files, conversationID: id)
            bind(tab, scope: scope)
            tab.selection = link; tab.sourceURL = url
            applyTitle(presentationTitle, to: tab)
            append(tab); pendingTab = tab
            await tab.files.openFile(path: path)
            return owns(request, id)
        } catch {
            guard owns(request, id) else { return false }
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func openPanel(_ kind: ConversationPanelKind, conversationID id: String) async -> Bool {
        guard !confirming, await enterConversation(id), !Task.isCancelled else { return false }
        if kind == .review || kind == .files || kind == .processes,
            let existing = tabs.first(where: { $0.kind == kind && (kind != .files || $0.selection == nil) })
        {
            await refreshBindings()
            selectTab(existing.id); return true
        }
        guard hasCapacity else { return false }
        generation &+= 1
        let request = generation
        loading = true; error = nil; isOpen = true
        defer { if request == generation { loading = false; pendingTab = nil } }
        let tab = ConversationContentTab(kind: kind, conversationID: id)
        do {
            if kind == .browser {
                tab.browser.allowsLoopback = (try? validateWebURL(URL(string: "http://localhost")!, id)) != nil
            } else {
                let scope = try await prepareScope(id)
                guard owns(request, id) else { return false }
                bind(tab, scope: scope)
                if kind == .terminal, scope.terminalsClient == nil { throw ConversationPanelUnavailable(kind: kind) }
                if kind == .processes, scope.processesClient == nil { throw ConversationPanelUnavailable(kind: kind) }
                if kind == .review,
                    (tab.usesProjectReview ? scope.projectChangesClient == nil : scope.worktreeClient == nil)
                {
                    throw ConversationPanelUnavailable(kind: kind)
                }
            }
            append(tab)
            if kind == .terminal {
                await tab.terminals.loadTerminals()
                guard owns(request, id) else { return false }
            }
            return true
        } catch {
            guard owns(request, id) else { return false }
            self.error = error.localizedDescription
            return false
        }
    }

    func openFile(_ path: String, from tab: ConversationContentTab) {
        // Root-relative encoded URL; literal '#' and spaces remain file names.
        let root = URL(fileURLWithPath: tab.rootPath, isDirectory: true)
        requestOpen(root.appendingPathComponent(path), conversationID: tab.conversationID)
    }

    func openLink(_ url: URL, from tab: ConversationContentTab) {
        let path: String?
        if case .file(let value, _) = tab.selection { path = value } else { path = nil }
        requestOpen(url, conversationID: tab.conversationID, relativeTo: path)
    }

    @discardableResult
    func closeTab(_ id: UUID) async -> Bool {
        guard !confirming, let tab = tabs.first(where: { $0.id == id }), !tab.files.saving else { return false }
        let request = generation
        guard await allowClosing([tab]), request == generation else { return false }
        tab.terminals.active = false
        tab.processes.active = false
        tab.files.cancelContentRead()
        tab.review.resetWorkspaceSurface()
        tab.projectReview.suspend()
        let index = tabs.firstIndex { $0.id == id } ?? 0
        tabs.removeAll { $0.id == id }
        if selectedTabID == id { selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        error = nil
        updateActivity()
        return true
    }

    @discardableResult
    func close() async -> Bool {
        guard !confirming, !tabs.contains(where: { $0.files.saving }) else { return false }
        let request = generation
        guard await allowClosing(tabs), generation == request else { return false }
        cancelPending()
        removeTabs()
        isOpen = false; loading = false; error = nil
        return true
    }

    /// Route changes stop UI transport watches without closing daemon shells or
    /// dropping edited files. Reopening the same conversation reveals its tabs.
    func suspend() {
        suspended = true
        bindingGeneration &+= 1
        bindingTask?.cancel(); bindingTask = nil
        let openingEmpty = loading && tabs.isEmpty
        cancelPending()
        loading = false
        if openingEmpty { isOpen = false }
        for tab in tabs { tab.terminals.active = false; tab.processes.active = false }
    }

    /// Connection replacement invalidates old clients immediately; rebinding a
    /// same-target FilesModel retains the native editor and unsaved revision.
    func invalidateTransports() {
        bindingGeneration &+= 1
        bindingTask?.cancel(); bindingTask = nil
        for tab in tabs {
            guard let scope = tab.scope else { continue }
            tab.files.bind(target: scope.target, client: nil)
            tab.files.isLive = false
            tab.terminals.active = false
            tab.terminals.bind(target: scope.target, client: nil)
            tab.terminals.isLive = false
            tab.processes.active = false
            tab.processes.bind(target: scope.target, client: nil)
            tab.review.bind(target: scope.target, client: nil, card: scope.card, doneLaneID: scope.doneLaneID)
            tab.projectReview.disconnect()
            tab.transportsLive = false
            tab.transportRevision += 1
        }
    }

    func resume() {
        suspended = false
        updateActivity()
        bindingTask?.cancel()
        bindingTask = Task { await refreshBindings() }
    }

    func refreshBindings() async {
        let id = conversationID
        guard !id.isEmpty, !tabs.isEmpty, tabs.contains(where: { $0.scope != nil }) else { updateActivity(); return }
        bindingGeneration &+= 1
        let token = bindingGeneration
        do {
            let scope = try await prepareScope(id)
            guard token == bindingGeneration, conversationID == id,
                endpointID == (currentEndpointID(id) ?? ""), !Task.isCancelled
            else { return }
            rebindRetainedTabs(scope: scope)
            self.error = nil
            updateActivity()
            if let tab = selectedTab, tab.kind == .terminal, tab.terminals.active {
                await tab.terminals.loadTerminals()
            }
        } catch {
            guard token == bindingGeneration, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func rebindRetainedTabs(scope: ConversationContentScope) {
        for tab in tabs where tab.scope?.target == scope.target {
            guard tab.rootPath == scope.rootPath else {
                tab.files.bind(target: tab.files.target, client: nil)
                tab.files.isLive = false; tab.terminals.active = false; tab.transportsLive = false
                tab.terminals.bind(target: tab.terminals.target, client: nil)
                tab.terminals.isLive = false
                tab.processes.active = false
                tab.processes.bind(target: scope.target, client: nil)
                tab.projectReview.disconnect()
                tab.review.bind(target: scope.target, client: nil, card: scope.card, doneLaneID: scope.doneLaneID)
                tab.error =
                    "The conversation workspace moved. Close this tab and reopen the file to use its new location."
                continue
            }
            bind(tab, scope: scope)
        }
        updateActivity()
    }

    private var hasCapacity: Bool {
        guard tabs.count < Self.maximumTabs else {
            error = "You have \(Self.maximumTabs) open tabs. Close a tab before opening another item."
            return false
        }
        return true
    }

    private func enterConversation(_ id: String) async -> Bool {
        guard !id.isEmpty else { return false }
        let endpoint = currentEndpointID(id) ?? ""
        if conversationID == id, endpointID == endpoint { return true }
        let request = generation
        guard !tabs.contains(where: { $0.files.saving }), await allowClosing(tabs), generation == request,
            !Task.isCancelled
        else { return false }
        removeTabs()
        conversationID = id
        endpointID = endpoint
        return true
    }

    private func bind(_ tab: ConversationContentTab, scope: ConversationContentScope) {
        tab.scope = scope; tab.rootPath = scope.rootPath
        tab.error = nil
        tab.transportsLive = true
        tab.transportRevision += 1
        tab.usesProjectReview = ConversationWorkspaceMode.projectMode(scope.workspaceMode) == .project
        if let client = scope.projectChangesClient {
            tab.projectReview.bind(projectID: scope.target.projectID, client: client)
        }
        tab.terminals.active = false
        tab.files.bind(target: scope.target, client: scope.client)
        tab.files.isLive = true; tab.files.fileScopeCardID = scope.target.conversationID
        tab.files.projectPath = scope.rootPath
        tab.tree.bind(target: scope.target, client: scope.client)
        tab.terminals.bind(target: scope.target, client: scope.terminalsClient)
        tab.processes.bind(target: scope.target, client: scope.processesClient)
        tab.terminals.terminalScopeCardID = scope.target.conversationID
        tab.terminals.machineName = scope.machineName
        tab.terminals.isLive = scope.terminalsClient != nil
        tab.review.bind(
            target: scope.target, client: scope.worktreeClient, card: scope.card, doneLaneID: scope.doneLaneID)
        tab.review.authorName = NSFullUserName()
        tab.review.onSendMessage = onReviewSendMessage
        tab.review.onCard = onReviewCard
        tab.review.onOperationFinished = onReviewOperationFinished
        tab.review.onTransportFailure = onReviewTransportFailure
        tab.review.onOpenFiles = { [weak self, weak tab] _, path in
            guard let self, let tab else { return }
            if let path {
                self.openFile(path, from: tab)
            } else {
                self.requestPanel(.files, conversationID: tab.conversationID)
            }
        }
        tab.review.onOpenTerminal = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            self.requestPanel(.terminal, conversationID: tab.conversationID)
        }
    }

    private func applyTitle(_ title: String?, to tab: ConversationContentTab) {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        tab.presentationTitle = value
    }

    private func append(_ tab: ConversationContentTab) {
        tabs.append(tab)
        suspended = false
        selectedTabID = tab.id
        isOpen = true
        updateActivity()
    }

    private func updateActivity() {
        for tab in tabs {
            tab.processes.active =
                !suspended && isOpen && tab.transportsLive && tab.id == selectedTabID && tab.kind == .processes
            let active = !suspended && isOpen && tab.transportsLive && tab.id == selectedTabID && tab.kind == .terminal
            let wasActive = tab.terminals.active
            tab.terminals.active = active
            if active && !wasActive { tab.terminals.startTerminalWatch() }
        }
    }

    private func owns(_ request: Int, _ id: String) -> Bool {
        generation == request && conversationID == id
            && endpointID == (currentEndpointID(id) ?? "") && !Task.isCancelled
    }

    private func cancelPending() {
        generation &+= 1
        openTask?.cancel(); openTask = nil
        pendingTab?.files.cancelContentRead(); pendingTab = nil
    }

    private func removeTabs() {
        for tab in tabs {
            tab.terminals.active = false
            tab.processes.active = false
            tab.files.cancelContentRead()
            tab.review.resetWorkspaceSurface()
            tab.projectReview.suspend()
        }
        tabs = []; selectedTabID = nil
    }

    private func allowClosing(_ candidates: [ConversationContentTab]) async -> Bool {
        guard candidates.contains(where: \.dirty) else { return true }
        confirming = true
        defer { confirming = false }
        for tab in candidates where tab.dirty {
            switch await confirmUnsaved(tab.title) {
            case .cancel: return false
            case .discard: continue
            case .save:
                await tab.files.saveCurrentDocument()
                if tab.dirty {
                    if let message = tab.files.fileError { onSaveFailure(message) }
                    selectedTabID = tab.id
                    return false
                }
            }
        }
        return true
    }
}

private struct ConversationPanelUnavailable: LocalizedError {
    let kind: ConversationPanelKind
    var errorDescription: String? {
        "\(kind.title) is unavailable on this conversation’s machine. Reconnect and try again."
    }
}
