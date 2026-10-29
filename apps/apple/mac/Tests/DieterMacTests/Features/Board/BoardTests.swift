import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMacKit

/// Board drag payloads, label dragging, lane sizing and paging, presentation state, and selection.
struct BoardTests {
    @Test func cardDragPayloadRejectsUnrelatedText() {
        let encoded = BoardCardDragPayload(cardID: "c_123", boardID: "b_456", sourceLane: "todo").encoded
        #expect(BoardCardDragPayload(encoded)?.cardID == "c_123")
        #expect(BoardCardDragPayload("ordinary text") == nil)
    }

    @Test func labelDragPayloadIsScopedToItsBoard() {
        let encoded = BoardLabelDragPayload(labelID: "l_123", boardID: "b_456").encoded
        let payload = BoardLabelDragPayload(encoded)

        #expect(payload?.labelID == "l_123")
        #expect(payload?.boardID == "b_456")
        #expect(BoardLabelDragPayload("ordinary text") == nil)
        #expect(BoardLabelDragPayload("board-label||l_123") == nil)
    }

    /// Label segments sit in the title-bar strip, which the window server drags
    /// unless the window is immovable while the pointer is over a segment.
    @MainActor @Test func labelDragSourceHoldsTheWindowStillAndForwardsClicks() throws {
        let source = BoardLabelDragSourceView(frame: NSRect(x: 0, y: 0, width: 60, height: 26))
        var selections = 0
        source.select = { selections += 1 }
        #expect(!source.mouseDownCanMoveWindow)
        #expect(source.acceptsFirstMouse(for: nil))

        let window = NSWindow(
            contentRect: NSRect(x: -3_000, y: -3_000, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(source)
        func hover(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.enterExitEvent(
                    with: type, location: NSPoint(x: 30, y: 13), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        source.mouseEntered(with: try hover(.mouseEntered))
        #expect(!window.isMovable)
        source.mouseExited(with: try hover(.mouseExited))
        #expect(window.isMovable)
        source.mouseEntered(with: try hover(.mouseEntered))
        source.removeFromSuperview()
        #expect(window.isMovable)

        func press(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 30, y: 13), modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        var pending = [try press(.leftMouseUp)]
        source.follow(try press(.leftMouseDown)) { pending.popLast() }
        #expect(selections == 1)
    }

    @Test func kanbanLanesFillTheBoardBeforeFallingBackToHorizontalScrolling() {
        #expect(KanbanLaneSizing.laneWidth(availableWidth: 1_255, laneCount: 4) == 300)
        #expect(KanbanLaneSizing.contentWidth(availableWidth: 1_255, laneCount: 4) == 1_255)
        #expect(KanbanLaneSizing.laneWidth(availableWidth: 680, laneCount: 4) == KanbanLaneSizing.minimumWidth)
        #expect(KanbanLaneSizing.contentWidth(availableWidth: 680, laneCount: 4) == 1_111)
    }

    @Test func laneCardPagesBoundTenThousandCardsAndClampAfterDeletion() {
        let first = LaneCardPage.resolve(total: 10_000, requestedPage: 0)
        #expect(first.lowerBound == 0)
        #expect(first.upperBound == LaneCardPage.defaultSize)
        #expect(first.pageCount == 250)
        #expect(first.rangeLabel == "1–40 of 10000")

        let last = LaneCardPage.resolve(total: 10_000, requestedPage: 249)
        #expect(last.lowerBound == 9_960)
        #expect(last.upperBound == 10_000)
        #expect(!last.canGoForward)

        let clamped = LaneCardPage.resolve(total: 3, requestedPage: 249)
        #expect(clamped.page == 0)
        #expect(clamped.lowerBound == 0)
        #expect(clamped.upperBound == 3)
    }

    @Test func boardPresentationUsesLoadingStateUntilASelectionCanBeResolved() {
        #expect(
            BoardPresentationState.resolve(
                hasLoadedWorkspace: false,
                selectedBoardID: "",
                hasSelectedBoard: false
            ) == .loading)
        #expect(
            BoardPresentationState.resolve(
                hasLoadedWorkspace: true,
                selectedBoardID: "b_loading",
                hasSelectedBoard: false
            ) == .loading)
        #expect(
            BoardPresentationState.resolve(
                hasLoadedWorkspace: true,
                selectedBoardID: "b_loaded",
                hasSelectedBoard: true
            ) == .loaded)
    }

    @Test func boardPresentationPreservesTheEmptyStateForABoardlessWorkspace() {
        #expect(
            BoardPresentationState.resolve(
                hasLoadedWorkspace: true,
                selectedBoardID: "",
                hasSelectedBoard: false
            ) == .empty)
    }

    @Test @MainActor func cachedBoardSelectionSwitchesTheVisibleProjectAtOnce() {
        let store = DieterStore(liveEnvironment: false)
        var firstProject = Dieter_V1_Project()
        firstProject.id = "p_first"
        firstProject.name = "First"
        var secondProject = Dieter_V1_Project()
        secondProject.id = "p_second"
        secondProject.name = "Second"
        var firstBoard = Dieter_V1_Board()
        firstBoard.id = "b_first"
        firstBoard.projectID = firstProject.id
        var secondBoard = Dieter_V1_Board()
        secondBoard.id = "b_second"
        secondBoard.projectID = secondProject.id
        var secondCard = Dieter_V1_Card()
        secondCard.id = "c_second"
        secondCard.projectID = secondProject.id
        secondCard.boardID = secondBoard.id

        store.projectDirectory = [firstProject.id: firstProject, secondProject.id: secondProject]
        store.navigationBoards = [firstProject.id: [firstBoard], secondProject.id: [secondBoard]]
        store.navigationCards = [firstProject.id: [], secondProject.id: [secondCard]]
        store.selectedProjectID = firstProject.id
        store.selectedBoardID = firstBoard.id
        store.state.project = firstProject
        store.state.boards = [firstBoard]

        store.selectCachedBoard(secondBoard.id, projectID: secondProject.id)

        #expect(store.selectedProjectID == secondProject.id)
        #expect(store.selectedBoard?.id == secondBoard.id)
        #expect(store.state.project.id == secondProject.id)
        #expect(store.state.cards.map(\.id) == [secondCard.id])
    }

    @Test func labelColorPaletteSerializesCustomColorsAsHex() {
        #expect(LabelColorPalette.hex(for: SwiftUI.Color(red: 1, green: 0.5, blue: 0)) == "#ff8000")
    }
}
