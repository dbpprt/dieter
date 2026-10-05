#if os(iOS)
    import DieterAPI
    import SwiftUI

    /// The app's root: a DEBUG preview the UI tests asked for, or the app on
    /// the shared core.
    @MainActor
    public struct DieterIOSRootView: View {
        public init() {}

        public var body: some View {
            #if DEBUG
                if let preview = IOSLaunchConfiguration.shared.preview {
                    IOSPreviewRoot(preview: preview)
                } else {
                    IOSAppRoot()
                }
            #else
                IOSAppRoot()
            #endif
        }
    }

    /// Sign-in or the workspace, as the core's session says, plus the scene
    /// lifecycle and the share extension's handoff.
    private struct IOSAppRoot: View {
        @Environment(\.scenePhase) private var scenePhase
        @State private var app = IOSAppModel.live
        @State private var navigation = IOSWorkspaceNavigation()
        @State private var pendingShare: IOSShareInbox.Request?
        @State private var loadingShareID: String?

        var body: some View {
            Group {
                if !app.launched {
                    IOSWorkspaceBackdrop()
                        .overlay { ProgressView().controlSize(.large) }
                        .accessibilityIdentifier("ios.launching")
                } else if app.signedIn {
                    IOSWorkspaceView()
                } else {
                    NavigationStack { IOSGatewayView() }
                }
            }
            .environment(app)
            .environment(navigation)
            .tint(.blue)
            .task {
                await app.start()
                receivePendingShare()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    app.setForeground(true)
                    receivePendingShare()
                case .background:
                    app.setForeground(false)
                    // Unsent text is saved in short batches; keep the last one.
                    Task { await app.drafts.save() }
                default:
                    break
                }
            }
            .onChange(of: app.signedIn) { _, signedIn in
                // Another account's selection and sheets never carry over.
                if !signedIn { navigation = IOSWorkspaceNavigation() }
            }
            .onChange(of: shareReady) { _, ready in
                if ready { presentPendingShare() }
            }
            .alert(
                "Couldn’t complete the request",
                isPresented: Binding(
                    get: { app.errorMessage != nil },
                    set: { if !$0 { app.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { app.errorMessage = nil }
            } message: {
                Text(app.errorMessage ?? "")
            }
        }

        // MARK: - Share extension handoff

        /// A shared item opens once every reachable machine's view is current.
        private var shareReady: Bool {
            pendingShare != nil && app.signedIn && app.session.synced
        }

        private func receivePendingShare() {
            guard pendingShare == nil, loadingShareID == nil, let request = IOSShareInbox.pendingRequest() else {
                return
            }
            pendingShare = request
            presentPendingShare()
        }

        private func presentPendingShare() {
            guard shareReady, let request = pendingShare, loadingShareID == nil else { return }
            loadingShareID = request.id
            Task {
                defer { if loadingShareID == request.id { loadingShareID = nil } }
                do {
                    let attachments = try await IOSShareInbox.consume(id: request.id)
                    guard pendingShare == request else { return }
                    IOSShareInbox.clearPendingRequest(request)
                    pendingShare = nil
                    switch request.destination {
                    case .newTask:
                        navigation.create(chat: false, attachments: attachments)
                    case .task, .chat:
                        navigation.sheet = .shareTarget(
                            IOSShareTargetRequest(kind: request.destination, attachments: attachments))
                    }
                } catch {
                    if pendingShare == request {
                        IOSShareInbox.clearPendingRequest(request)
                        pendingShare = nil
                        app.show(error)
                    }
                }
            }
        }
    }

    #if DEBUG
        /// The fixed screens the UI tests launch into.
        private struct IOSPreviewRoot: View {
            let preview: IOSLaunchConfiguration.Preview

            var body: some View {
                switch preview {
                case .connecting:
                    NavigationStack {
                        IOSWorkspaceBackdrop()
                            .overlay(alignment: .bottom) {
                                IOSConnectionBanner(
                                    title: "Connecting…", detail: "Your draft will stay here.", isConnecting: true,
                                    retry: {}
                                )
                                .padding(12)
                            }
                            .navigationTitle("Conversation")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .tint(.blue)
                case .screen:
                    IOSScreenFixtureView()
                }
            }
        }
    #endif
#endif
