import SwiftUI

struct ConversationContentPane: View {
    @Bindable var model: ConversationContentModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                    if case .file(let path, let line) = model.selection {
                        Text(path + (line.map { " · Line \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if model.files.fileEditorSession.isDirty {
                    Text("Edited").font(.caption).foregroundStyle(.secondary)
                    Button("Save") { Task { await model.files.saveCurrentDocument() } }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(model.files.saving)
                        .accessibilityIdentifier("conversation.content.save")
                }
                Button {
                    Task { await model.close() }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(DieterIconButtonStyle())
                .help("Close content pane").accessibilityLabel("Close content pane")
                .accessibilityIdentifier("conversation.content.close")
                .smokeTarget("conversation.content.close")
                .disabled(model.confirming || model.files.saving)
            }
            .padding(12)
            Divider()
            if model.loading || model.files.fileLoading {
                LoadFeedback(title: "Opening…")
            } else {
                if let error = model.error ?? model.files.fileError {
                    LoadFeedback(
                        title: "Content", error: error,
                        retry: {
                            if let url = model.sourceURL {
                                model.requestOpen(url, conversationID: model.conversationID)
                            }
                        }, compact: model.files.fileDocument != nil)
                }
                // Keep the renderer mounted, including its undo and selection,
                // when a revision conflict prevents saving.
                renderer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DieterTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.content-pane")
        .smokeTarget("conversation.content-pane")
    }

    @ViewBuilder private var renderer: some View {
        switch model.selection {
        case .web(let url):
            ConversationBrowserView(url: url, allowsLoopback: model.browserAllowsLoopback).id(model.navigationID)
        case .file(_, let line):
            ConversationContentRenderer(files: model.files, line: line, navigationID: model.navigationID)
        case nil: Color.clear
        }
    }

    private var title: String {
        switch model.selection {
        case .web(let url): url.host ?? url.absoluteString
        case .file(let path, _): (path as NSString).lastPathComponent
        case nil: model.sourceURL?.lastPathComponent ?? "Content"
        }
    }
    private var symbol: String {
        if case .web = model.selection { return "globe" }
        return "doc"
    }
}

/// Keeps the transcript subtree mounted as the secondary column appears. The
/// native split divider supplies resizing, keyboard access and pointer feedback.
struct ConversationContentSplit<Chat: View, Content: View>: View {
    let presented: Bool
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                chat()
                    .frame(
                        minWidth: presented ? min(280, geometry.size.width * 0.4) : 0,
                        idealWidth: presented ? geometry.size.width * 0.45 : geometry.size.width,
                        maxWidth: .infinity, maxHeight: .infinity
                    )
                    .clipped()
                if presented {
                    content()
                        .frame(
                            minWidth: min(300, geometry.size.width * 0.45),
                            idealWidth: geometry.size.width * 0.55,
                            maxWidth: .infinity, maxHeight: .infinity
                        )
                        .clipped()
                }
            }
        }
    }
}
