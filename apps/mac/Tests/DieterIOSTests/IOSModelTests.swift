import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import Testing
@testable import DieterIOS

@Suite("iOS remote session policies")
struct IOSModelTests {
    @Test func taskLabelSelectionKeepsOnlyCurrentBoardLabelsInStableOrder() {
        var first = Dieter_V1_Label()
        first.id = "label-a"
        var second = Dieter_V1_Label()
        second.id = "label-b"

        #expect(
            IOSCreateTaskLabels.normalized(
                selected: ["stale-label", "label-b", "label-a"], available: [second, first])
                == ["label-a", "label-b"])
        #expect(IOSCreateTaskLabels.normalized(selected: ["stale-label"], available: []) == [])
    }

    @Test func taskFastModeOnlyAppearsForSupportedModelsAndHasStableIdentity() {
        var fastMode = Dieter_V1_ProviderOption()
        fastMode.id = "fast_mode"
        fastMode.name = "Fast mode"
        fastMode.type = "boolean"
        fastMode.defaultValue = "false"
        fastMode.models = ["fast-model"]
        var harness = Dieter_V1_Harness()
        harness.options = [fastMode]

        #expect(IOSCreateTaskProviderOptions.fastModeOption(for: harness, model: "fast-model")?.id == "fast_mode")
        #expect(IOSCreateTaskProviderOptions.fastModeOption(for: harness, model: "other-model") == nil)
        #expect(
            IOSCreateTaskProviderOptions.normalized(
                for: harness, model: "fast-model", saved: ["fast_mode": "true"])
                == ["fast_mode": "true"])
        #expect(
            IOSCreateTaskProviderOptions.normalized(
                for: harness, model: "other-model", saved: ["fast_mode": "true"]
            ).isEmpty)
        #expect(
            IOSCreateTaskProviderOptions.identity(["z": "last", "a": "first"])
                == ["a=first", "z=last"])
    }

    @Test func authenticationSurvivesSuspensionButDefersTheDataPlaneConnection() {
        var ownership = IOSAuthenticationOwnership()
        let attempt = ownership.begin(gatewayID: "https://gateway.example:443")
        // Suspending/replacing the data plane must not invalidate the separate
        // auth owner: an authenticator app can deliver the result in background.
        #expect(ownership.accepts(attempt, gatewayID: attempt.gatewayID))
        #expect(!ownership.shouldConnect(attempt, gatewayID: attempt.gatewayID, foreground: false))
        #expect(ownership.shouldConnect(attempt, gatewayID: attempt.gatewayID, foreground: true))
    }

    @Test func acceptedAuthenticationRetiresBeforeTheFirstConnectionCanSuspend() {
        var ownership = IOSAuthenticationOwnership()
        let attempt = ownership.begin(gatewayID: "https://gateway.example:443")
        let shouldConnect = ownership.shouldConnect(attempt, gatewayID: attempt.gatewayID, foreground: true)
        let accepted = ownership.finish(attempt)
        #expect(accepted && shouldConnect)
        // The first connection can suspend and be replaced without an active
        // auth flow blocking resume. A later sign-in still owns its cleanup.
        #expect(ownership.active == nil)
        let newer = ownership.begin(gatewayID: attempt.gatewayID)
        let staleCleanup = ownership.finish(attempt)
        #expect(!staleCleanup)
        #expect(ownership.accepts(newer, gatewayID: newer.gatewayID))
    }

    @Test func changingGatewayOrSigningOutRejectsTheAuthenticationResult() {
        var ownership = IOSAuthenticationOwnership()
        let attempt = ownership.begin(gatewayID: "https://first.example:443")
        #expect(!ownership.accepts(attempt, gatewayID: "https://second.example:443"))
        ownership.invalidate()
        #expect(!ownership.accepts(attempt, gatewayID: attempt.gatewayID))
        #expect(!ownership.shouldConnect(attempt, gatewayID: attempt.gatewayID, foreground: true))
    }

    @Test func oldAuthenticationCleanupCannotClearANewerWebOrTokenLogin() {
        var ownership = IOSAuthenticationOwnership()
        let previous = ownership.begin(gatewayID: "https://gateway.example:443")
        ownership.invalidate()
        let current = ownership.begin(gatewayID: previous.gatewayID)
        let clearedPrevious = ownership.finish(previous)
        #expect(!clearedPrevious)
        #expect(!ownership.accepts(previous, gatewayID: previous.gatewayID))
        #expect(ownership.accepts(current, gatewayID: current.gatewayID))
        let clearedCurrent = ownership.finish(current)
        #expect(clearedCurrent)
        #expect(ownership.active == nil)
    }

    @Test func rpcErrorsPreserveGatewayAuthenticationMessage() {
        let error = RPCError(code: .unauthenticated, message: "authentication required")
        #expect(IOSUserError.message(error) == "authentication required")
    }

    @Test func rpcErrorsPreserveUnavailableReasonAndExplainEmptyErrors() {
        let error = RPCError(code: .unavailable, message: "The selected daemon is offline.")
        #expect(IOSUserError.message(error) == "The selected daemon is offline.")
        let empty = RPCError(code: .unavailable, message: " ")
        #expect(IOSUserError.message(empty).contains("unavailable"))
        #expect(!IOSUserError.message(empty).contains("GRPCCore.RPCError"))
    }

    @Test func localErrorsRetainActionableDescription() {
        let error = NSError(
            domain: "Fixture", code: 4, userInfo: [NSLocalizedDescriptionKey: "The saved file changed."])
        #expect(IOSUserError.message(error) == "The saved file changed.")
    }

    @Test func authorizationUsesPKCEAndFixedRegisteredCallback() throws {
        let endpoint = DieterEndpoint(name: "Test", host: "gateway.example", port: 8443, secure: true)
        let url = try IOSAuthenticationRequest.authorizationURL(
            endpoint: endpoint, verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "gateway.example")
        #expect(components.port == 8443)
        #expect(components.path == "/auth/github/start")
        #expect(
            components.queryItems?.first(where: { $0.name == "native_code_challenge" })?.value
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(
            components.queryItems?.first(where: { $0.name == "native_redirect_uri" })?.value
                == "dieter-mac://oauth/callback")
    }

    @Test func authorizationRejectsPlaintext() {
        let endpoint = DieterEndpoint(name: "Test", host: "example.com", port: 4242)
        #expect(throws: IOSAuthenticationError.self) {
            try IOSAuthenticationRequest.authorizationURL(endpoint: endpoint, verifier: "secret")
        }
    }

    @Test func exchangeStaysOnInitiatingGatewayAndVerifierIsOnlyInBody() throws {
        let endpoint = DieterEndpoint(name: "Test", host: "gateway.example", port: 443, secure: true)
        let callback = try #require(URL(string: "dieter-mac://oauth/callback?code=one-time&host=attacker.example"))
        let request = try IOSAuthenticationRequest.exchangeRequest(
            endpoint: endpoint, callback: callback, verifier: "verifier")
        #expect(request.url?.absoluteString == "https://gateway.example/auth/native/exchange")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 30)
        let data = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["code": "one-time", "verifier": "verifier"])
    }

    @Test(arguments: [
        "https://oauth/callback?code=x", "dieter-mac://wrong/callback?code=x", "dieter-mac://oauth/other?code=x",
        "dieter-mac://oauth/callback?code=", "dieter-mac://oauth/callback?code=x&error=denied",
    ])
    func exchangeRejectsUnrelatedOrRejectedCallbacks(_ callback: String) throws {
        let endpoint = DieterEndpoint(name: "Test", host: "example.com", port: 443, secure: true)
        let url = try #require(URL(string: callback))
        #expect(throws: IOSAuthenticationError.self) {
            try IOSAuthenticationRequest.exchangeRequest(endpoint: endpoint, callback: url, verifier: "v")
        }
    }

    @Test func uncertainMutationRetainsIdentityAndDoesNotCrossNodes() {
        var identity = IOSMutationIdentity()
        let first = identity.command(for: ["node-a", "card", "message"])
        let retry = identity.command(for: ["node-a", "card", "message"])
        #expect(retry == first)
        let next = identity.command(for: ["node-b", "card", "message"])
        #expect(next != first)
        identity.acknowledge(command: first)
        let retryAfterOldAck = identity.command(for: ["node-b", "card", "message"])
        #expect(retryAfterOldAck == next)
        identity.acknowledge(command: next)
        let afterAck = identity.command(for: ["node-b", "card", "message"])
        #expect(afterAck != next)
    }

    @Test func mutationFingerprintPreservesInputBoundaries() {
        var identity = IOSMutationIdentity()
        let first = identity.command(for: ["node|task", "prompt"])
        let second = identity.command(for: ["node", "task|prompt"])
        #expect(second != first)
    }

    @Test func staleRemoteAndNavigationResponsesAreRejected() {
        let connection = UUID(), selection = UUID()
        let scope = IOSRequestScope(connection: connection, selection: selection)
        #expect(scope.accepts(connection: connection, selection: selection, active: true))
        #expect(!scope.accepts(connection: UUID(), selection: selection, active: true))
        #expect(!scope.accepts(connection: connection, selection: UUID(), active: true))
        #expect(!scope.accepts(connection: connection, selection: selection, active: false))
    }

    @Test func remoteDesktopCoordinatesRespectAspectFitLetterboxing() throws {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let video = CGSize(width: 300, height: 150)
        #expect(
            IOSRemoteDesktopGeometry.contentRect(bounds: bounds, videoSize: video)
                == CGRect(
                    x: 0, y: 75, width: 300, height: 150))
        let center = try #require(
            IOSRemoteDesktopGeometry.normalized(
                point: CGPoint(x: 150, y: 150), bounds: bounds, videoSize: video))
        #expect(center == CGPoint(x: 0.5, y: 0.5))
        #expect(
            IOSRemoteDesktopGeometry.normalized(
                point: CGPoint(x: 150, y: 20), bounds: bounds, videoSize: video) == nil)
        let clamped = try #require(
            IOSRemoteDesktopGeometry.normalized(
                point: CGPoint(x: 400, y: -20), bounds: bounds, videoSize: video, clamp: true))
        #expect(clamped == CGPoint(x: 1, y: 0))
    }

    @Test func remoteDesktopZoomPreservesCoordinatesAndStaysBounded() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let video = CGSize(width: 300, height: 150)
        let contentPoint = CGPoint(x: 75, y: 112.5)
        let displayed = IOSRemoteDesktopGeometry.zoomed(
            point: contentPoint, bounds: bounds, zoomScale: 2, zoomOffset: .zero)
        #expect(displayed == CGPoint(x: 0, y: 75))
        #expect(
            IOSRemoteDesktopGeometry.unzoomed(
                point: displayed, bounds: bounds, zoomScale: 2, zoomOffset: .zero) == contentPoint)
        #expect(IOSRemoteDesktopGeometry.clampedZoomScale(0.5) == 1)
        #expect(IOSRemoteDesktopGeometry.clampedZoomScale(8) == 4)
        #expect(
            IOSRemoteDesktopGeometry.clampedZoomOffset(
                CGPoint(x: 200, y: 100), bounds: bounds, videoSize: video, zoomScale: 2)
                == CGPoint(x: 150, y: 0))
    }

    @Test func remoteDesktopZoomedClicksMapToTheVisibleRemotePoint() throws {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let video = CGSize(width: 300, height: 150)
        let centered = try #require(
            IOSRemoteDesktopGeometry.normalizedDisplayedPoint(
                CGPoint(x: 150, y: 150),
                bounds: bounds,
                videoSize: video,
                zoomScale: 2,
                zoomOffset: CGPoint(x: 150, y: 0)))
        #expect(centered == CGPoint(x: 0.25, y: 0.5))

        let oppositePan = try #require(
            IOSRemoteDesktopGeometry.normalizedDisplayedPoint(
                CGPoint(x: 150, y: 150),
                bounds: bounds,
                videoSize: video,
                zoomScale: 2,
                zoomOffset: CGPoint(x: -150, y: 0)))
        #expect(oppositePan == CGPoint(x: 0.75, y: 0.5))
    }

    @Test func remoteDesktopReceiverHeartbeatRetainsItsEpochAndAdvances() {
        let epoch = Data(repeating: 7, count: 16)
        var heartbeat = IOSRemoteDesktopFeedbackHeartbeat(inputEpoch: epoch)
        let first = heartbeat.next(inputActive: false)
        let second = heartbeat.next(inputActive: true)

        #expect(first.protocolVersion == 2)
        #expect(first.inputEpoch == epoch)
        #expect(first.sequence == 1)
        #expect(!first.inputActive)
        #expect(second.protocolVersion == 2)
        #expect(second.inputEpoch == epoch)
        #expect(second.sequence == 2)
        #expect(second.inputActive)
    }

    @Test func remoteDesktopOnlyPresentsSoftwareKeyboardForTextInput() {
        #expect(!IOSRemoteDesktopInputMode.pointer.presentsSoftwareKeyboard)
        #expect(IOSRemoteDesktopInputMode.text.presentsSoftwareKeyboard)
        #expect(IOSRemoteDesktopInputMode(textInputActive: false) == .pointer)
        #expect(IOSRemoteDesktopInputMode(textInputActive: true) == .text)
    }

    @Test func remoteDesktopFramesWithOnlyRTPTimestampsRemainRenderable() {
        let first = IOSRemoteDesktopFrameTimestamp.nanoseconds(decodedNanoseconds: 0, rtpTimestamp: 0)
        let second = IOSRemoteDesktopFrameTimestamp.nanoseconds(decodedNanoseconds: 0, rtpTimestamp: 1_500)
        #expect(first > 0)
        #expect(second > first)
        #expect(
            IOSRemoteDesktopFrameTimestamp.nanoseconds(
                decodedNanoseconds: 42_000,
                rtpTimestamp: 1_500) == 42_000)
    }

    @Test func remoteDesktopFrameRateIsCappedAtThirty() {
        #expect(IOSRemoteDesktopFrameRate.available(hostMaximum: 0) == [30])
        #expect(IOSRemoteDesktopFrameRate.available(hostMaximum: 60) == [30])
        #expect(IOSRemoteDesktopFrameRate.available(hostMaximum: 24).isEmpty)
        #expect(IOSRemoteDesktopFrameRate.capped(60, hostMaximum: 60) == 30)
        #expect(IOSRemoteDesktopFrameRate.capped(30, hostMaximum: 24) == 24)
    }

    @Test func mixedFleetSelectionSkipsLegacyAndOfflineNodes() {
        let legacy = machine(id: "legacy", api: "2")
        let offline = machine(id: "offline", api: "3", online: false)
        let current = machine(id: "current", api: "3")
        #expect(
            IOSMachinePolicy.preferred(in: [legacy, offline, current], preferredID: "legacy")?.daemonID == "current")
        #expect(IOSMachinePolicy.preferred(in: [legacy, offline], preferredID: nil) == nil)
        #expect(!IOSMachinePolicy.isCompatible(legacy))
    }

    @Test(arguments: ["127.0.0.1", "127.50.0.2", "::1", "localhost"])
    func debugPlaintextExceptionIsLimitedToLoopback(_ host: String) {
        #expect(IOSMachinePolicy.isLoopbackTestEndpoint(.init(name: "Test", host: host, port: 4242)))
    }

    @Test(arguments: [
        "192.168.1.2", "127.example.com", "127.0.0.1.example.com", "127.0.0.999", "example.com", "0.0.0.0",
    ])
    func debugPlaintextExceptionRejectsRemoteHosts(_ host: String) {
        #expect(!IOSMachinePolicy.isLoopbackTestEndpoint(.init(name: "Test", host: host, port: 4242)))
    }

    @Test func olderPagePrependsWithoutLosingTailOrMessageIdentity() {
        var transcript = IOSTranscript()
        transcript.reset(snapshot(range: 60..<120, sequence: 4, total: 120))
        let accepted = transcript.prepend(snapshot(range: 0..<60, sequence: 4, total: 120), expectedSequence: 4)
        #expect(accepted)
        #expect(transcript.conversation?.messages.map(\.id) == (0..<120).map { "m\($0)" })
        #expect(transcript.page.start == 0)
        #expect(!transcript.page.hasMore_p)
        #expect(transcript.conversation?.lastSeq == 4)
    }

    @Test func racingOlderPageCannotReplaceNewerLiveRevision() {
        var transcript = IOSTranscript()
        transcript.reset(snapshot(range: 60..<120, sequence: 4, total: 120))
        var update = Dieter_V1_ConversationUpdate()
        update.lastSeq = 5
        update.changedMessages = [message(119, text: "new")]
        transcript.apply(update)
        let accepted = transcript.prepend(snapshot(range: 0..<60, sequence: 4, total: 120), expectedSequence: 4)
        #expect(!accepted)
        #expect(transcript.conversation?.messages.last?.parts.first?.text == "new")
        #expect(transcript.conversation?.messages.count == 60)
    }

    @Test func liveDeltaReplacesRemovesAndAppendsOnce() {
        var transcript = IOSTranscript()
        transcript.reset(snapshot(range: 0..<3, sequence: 4, total: 3))
        var update = Dieter_V1_ConversationUpdate()
        update.lastSeq = 5
        update.removedMessageIds = ["m0"]
        update.changedMessages = [message(1, text: "edited"), message(3, text: "new")]
        update.status = "running"
        transcript.apply(update)
        transcript.apply(update)
        #expect(transcript.conversation?.messages.map(\.id) == ["m1", "m2", "m3"])
        #expect(transcript.conversation?.messages.first?.parts.first?.text == "edited")
        #expect(transcript.conversation?.status == "running")
    }

    @Test func reconnectSnapshotDropsStaleMessagesAndBoundsRetainedHistory() {
        var transcript = IOSTranscript()
        transcript.reset(snapshot(range: 0..<400, sequence: 9, total: 400))
        #expect(transcript.conversation?.messages.count == 240)
        #expect(transcript.conversation?.messages.first?.id == "m160")
        #expect(transcript.page.start == 160)
        let didTrim = transcript.trimToLatest()
        #expect(didTrim)
        #expect(transcript.conversation?.messages.count == 60)
        #expect(transcript.page.start == 340)
        let didTrimAgain = transcript.trimToLatest()
        #expect(!didTrimAgain)
        transcript.reset(snapshot(range: 380..<400, sequence: 11, total: 400))
        #expect(transcript.conversation?.messages.count == 20)
        #expect(transcript.conversation?.lastSeq == 11)
    }

    @Test func adjacentRoutineActivityCollapsesLikeTheMacTimeline() {
        let messages = [
            conversationMessage("user", role: "user", parts: [conversationPart("text", text: "Investigate")]),
            conversationMessage("reasoning", parts: [conversationPart("reasoning", text: "Inspect")]),
            conversationMessage("command", parts: [conversationPart("tool-call", tool: "exec_command")]),
            conversationMessage("edit", parts: [conversationPart("tool-apply_patch")]),
            conversationMessage("answer", parts: [conversationPart("text", text: "Done")]),
        ]

        let items = IOSConversationPresentation.timelineItems(messages)
        #expect(items.count == 3)
        #expect(items.map(\.isActivity) == [false, true, false])
        #expect(items[1].messages.map(\.id) == ["reasoning", "command", "edit"])
        #expect(IOSConversationActivitySummary(steps: items[1].steps).title == "Reasoning · 1 edit · 1 command")
        #expect(IOSConversationPresentation.anchorItem(containing: "command", in: items) == items[1].id)
    }

    @Test func queuedSteeringRecognizesProviderWorkingStatuses() {
        #expect(IOSConversationPresentation.isAgentWorking(conversationStatus: "streaming", cardRuntime: ""))
        #expect(IOSConversationPresentation.isAgentWorking(conversationStatus: "", cardRuntime: "working"))
        #expect(!IOSConversationPresentation.isAgentWorking(conversationStatus: "idle", cardRuntime: "stopped"))
        #expect(!IOSConversationPresentation.isAgentWorking(conversationStatus: "queued", cardRuntime: "waiting"))
    }

    @Test func runningTurnTimeUsesTheLatestUserMessageAndFallsBackToRuntimeTime() throws {
        var first = conversationMessage("first", role: "user", parts: [conversationPart("text", text: "First")])
        first.metadataJson = Data(#"{"createdAt":"2026-09-10T10:00:00Z"}"#.utf8)
        var latest = conversationMessage("latest", role: "human", parts: [conversationPart("text", text: "Latest")])
        latest.metadataJson = Data(#"{"createdAt":"2026-09-10T10:04:00Z"}"#.utf8)
        let assistant = conversationMessage("assistant", parts: [conversationPart("text", text: "Working")])

        #expect(
            IOSConversationPresentation.turnStart(
                messages: [first, latest, assistant], runtimeUpdatedAt: "2026-09-10T10:05:00Z")
                == DieterTimestamp.date(from: "2026-09-10T10:04:00Z"))
        latest.metadataJson = Data(#"{"createdAt":"invalid"}"#.utf8)
        #expect(
            IOSConversationPresentation.turnStart(
                messages: [latest, assistant], runtimeUpdatedAt: "2026-09-10T10:05:00Z")
                == DieterTimestamp.date(from: "2026-09-10T10:05:00Z"))
    }

    @Test func conversationBottomDetectionAccountsForTheComposerInset() {
        #expect(
            IOSConversationScrollBehavior.isAtLatest(
                visibleMaxY: 1_120, contentHeight: 1_000, bottomInset: 120))
        #expect(
            !IOSConversationScrollBehavior.isAtLatest(
                visibleMaxY: 1_117, contentHeight: 1_000, bottomInset: 120))
    }

    @Test func mixedMessagesCollapseOnlyTheirRoutineActivityAndKeepFailuresVisible() {
        var failed = conversationPart("tool-call", tool: "exec_command")
        failed.state = "failed"
        failed.errorText = "Exited with status 1"
        let mixed = conversationMessage(
            "mixed",
            parts: [
                conversationPart("text", text: "Starting"),
                conversationPart("tool-call", tool: "exec_command"),
                conversationPart("thinking", text: "Checking"),
                conversationPart("text", text: "Continuing"), failed,
            ])

        let groups = IOSConversationPresentation.partGroups(in: mixed)
        #expect(groups.map(\.isActivity) == [false, true, false, false])
        #expect(groups[1].steps.count == 2)
        let failedItems = IOSConversationPresentation.timelineItems([
            conversationMessage("failed", parts: [failed])
        ])
        #expect(!failedItems[0].isActivity)
    }

    @Test func queuedEditingRestoresTextAndAttachmentsAndLocalRemovalIsImmediate() {
        var text = Dieter_V1_MessagePart(); text.type = "text"; text.text = "Revise this"
        var attachment = Dieter_V1_MessagePart()
        attachment.type = "file"; attachment.filename = "notes.md"; attachment.mediaType = "text/markdown"
        var selection = Dieter_V1_HarnessSelection()
        selection.provider = "codex"; selection.model = "gpt-6-astra"; selection.effort = "high"
        selection.providerOptions = ["fast_mode": "true"]
        var queued = Dieter_V1_QueuedMessage()
        queued.id = "queued"; queued.parts = [text, attachment]; queued.selection = selection
        let restored = IOSConversationPresentation.queuedDraft(for: queued)
        #expect(restored.text == "Revise this")
        #expect(restored.attachments.map(\.filename) == ["notes.md"])
        #expect(restored.selection == selection)

        var value = snapshot(range: 0..<1, sequence: 1, total: 1)
        value.conversation.queue = [queued]
        var transcript = IOSTranscript(); transcript.reset(value)
        #expect(transcript.removeQueuedMessage(id: queued.id)?.id == queued.id)
        #expect(transcript.conversation?.queue.isEmpty == true)
    }

    private func machine(id: String, api: String, online: Bool = true) -> DieterEndpoint {
        .init(name: id, host: "example.com", port: 443, secure: true, daemonID: id, online: online, apiVersion: api)
    }

    private func message(_ number: Int, text: String = "message") -> Dieter_V1_UiMessage {
        var message = Dieter_V1_UiMessage()
        message.id = "m\(number)"
        message.role = "assistant"
        var part = Dieter_V1_MessagePart(); part.type = "text"; part.text = text
        message.parts = [part]
        return message
    }

    private func conversationMessage(
        _ id: String, role: String = "assistant", parts: [Dieter_V1_MessagePart]
    ) -> Dieter_V1_UiMessage {
        var message = Dieter_V1_UiMessage()
        message.id = id; message.role = role; message.parts = parts
        return message
    }

    private func conversationPart(_ type: String, text: String = "", tool: String = "")
        -> Dieter_V1_MessagePart
    {
        var part = Dieter_V1_MessagePart()
        part.type = type; part.text = text; part.toolName = tool
        return part
    }

    private func snapshot(range: Range<Int>, sequence: Int64, total: Int32) -> Dieter_V1_ConversationSnapshot {
        var value = Dieter_V1_ConversationSnapshot()
        value.conversation.cardID = "card"
        value.conversation.messages = range.map { message($0) }
        value.conversation.lastSeq = sequence
        value.page.start = Int32(range.lowerBound)
        value.page.end = Int32(range.upperBound)
        value.page.total = total
        value.page.hasMore_p = range.lowerBound > 0
        return value
    }
}
