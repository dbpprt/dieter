import DieterAPI
import Foundation
import GRPCCore
import Testing
@testable import DieterIOS

@Suite("iOS remote session policies")
struct IOSModelTests {
    @Test func machineInformationPresentationFormatsAndBoundsTelemetry() {
        #expect(IOSMachineInformationPresentation.bytes(11_200_000_000).contains("GB"))
        #expect(IOSMachineInformationPresentation.rate(1_250_000).hasSuffix("/s"))
        #expect(IOSMachineInformationPresentation.uptime(14 * 86_400 + 6 * 3_600) == "14d 6h")
        #expect(IOSMachineInformationPresentation.uptime(2 * 3_600 + 41 * 60) == "2h 41m")
        #expect(IOSMachineInformationPresentation.percentage(37.6) == "38%")
        #expect(IOSMachineInformationPresentation.fraction(3, of: 2) == 1)
        #expect(IOSMachineInformationPresentation.fraction(1, of: 0) == 0)
        #expect(IOSMachineInformationPresentation.shortRevision("0123456789abcdef") == "0123456789")
        #expect(IOSMachineInformationPresentation.shortRevision("unknown") == nil)
    }

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

    @Test func timelineAdapterGroupsNativeActivityAndPreservesAnchors() {
        let reasoning = conversationMessage(
            "reasoning", parts: [conversationPart("reasoning", text: "Inspect")])
        let command = conversationMessage(
            "command", parts: [conversationPart("tool-call", tool: "exec_command")])

        let items = IOSConversationPresentation.timelineItems([reasoning, command])
        #expect(items.count == 1)
        #expect(items[0].isActivity)
        #expect(items[0].messages.map(\.id) == ["reasoning", "command"])
        #expect(items[0].summary == "Reasoning · 1 command")
        #expect(items[0].steps.map(\.toolName).filter { !$0.isEmpty } == ["exec_command"])
        #expect(IOSConversationPresentation.anchorItem(containing: "command", in: items) == "activity:reasoning")
    }

    @Test func conversationBottomDetectionAccountsForTheComposerInset() {
        #expect(
            IOSConversationScrollBehavior.isAtLatest(
                visibleMaxY: 1_120, contentHeight: 1_000, bottomInset: 120))
        #expect(
            !IOSConversationScrollBehavior.isAtLatest(
                visibleMaxY: 1_117, contentHeight: 1_000, bottomInset: 120))
    }

    @Test func queuedEditingRestoresTextAttachmentsAndSelection() {
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

}
