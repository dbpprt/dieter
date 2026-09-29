#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI

    @MainActor enum BoardDeletionUISmoke {
        static func run(
            store: DieterStore, window: NSWindow, board: Dieter_V1_Board, results: inout [String: String], output: URL
        ) async {
            do {
                guard let rpc = store.rpc,
                    let canceledBoard = try await store.createBoard(
                        projectID: board.projectID, name: "Cancel board deletion smoke", workflow: "review",
                        doneArchivePolicy: "never"),
                    let empty = try await store.createBoard(
                        projectID: board.projectID, name: "Delete board smoke", workflow: "review",
                        doneArchivePolicy: "never")
                else { throw CocoaError(.fileReadUnknown) }
                store.acceptBoard(canceledBoard)
                store.acceptBoard(empty)
                // acceptBoard updates the selected-board replica, while the
                // sidebar is rendered from the navigation projection. Refresh
                // that projection before driving either new native row.
                await store.refreshNavigation()
                let navigation = store.sidebarProjectNavigation
                defer { store.sidebarProjectNavigation = navigation }
                if !navigation.isExpanded(board.projectID) {
                    var expanded = navigation
                    expanded.toggleExpanded(board.projectID)
                    store.sidebarProjectNavigation = expanded
                }
                await store.openBoard(board.id, projectID: board.projectID)
                _ = await NativeUIAccessibility.wait { store.selectedBoardID == board.id }
                NativeUISmokeRunner.capture(window, to: output.appending(path: "board-delete-before-context.png"))

                // Exercise cancellation and confirmation on different rows. A
                // dismissed SwiftUI confirmationDialog can retain its first
                // modifier host briefly even after AppKit detaches the sheet;
                // immediately reopening that same host makes the second native
                // context-menu action race the stale presentation state.
                let cancelPrompt = await chooseDelete(canceledBoard, window: window)
                let prompted = cancelPrompt.presented
                if let sheet = window.attachedSheet {
                    NativeUISmokeRunner.capture(sheet, to: output.appending(path: "board-delete-confirmation.png"))
                }
                let canceled = prompted && pressDialog("Cancel", window: window)
                let dismissed = await NativeUIAccessibility.wait { window.attachedSheet == nil }
                let afterCancel = try await rpc.getBoard(canceledBoard.id)
                results["board-delete-cancel"] =
                    canceled && dismissed && !afterCancel.retired && store.selectedBoardID == board.id
                    ? "passed"
                    : "failed: prompted=\(prompted), canceled=\(canceled), dismissed=\(dismissed), retired=\(afterCancel.retired), selected=\(store.selectedBoardID), target=\(cancelPrompt.diagnostic)"

                let deletePrompt = await chooseDelete(empty, window: window)
                let confirmed = deletePrompt.presented && pressDialog("Delete board", window: window)
                let removed = await NativeUIAccessibility.wait {
                    store.replica.retiredBoards[empty.id]?.retired == true
                        && !store.boards(for: board.projectID).contains { $0.id == empty.id }
                        && NativeUIAccessibility.find("sidebar.board.\(empty.id)", in: window) == nil
                }
                let afterDelete = try await rpc.getBoard(empty.id)
                results["board-delete-right-click-target"] =
                    confirmed && removed && afterDelete.retired && store.selectedBoardID == board.id
                    ? "passed"
                    : "failed: confirmed=\(confirmed), removed=\(removed), retired=\(afterDelete.retired), selected=\(store.selectedBoardID), target=\(deletePrompt.diagnostic)"

                await store.retireBoard(canceledBoard)

                await store.restoreBoard(empty.id)
                let restored = await NativeUIAccessibility.wait {
                    store.boards(for: board.projectID).contains { $0.id == empty.id && !$0.retired }
                }
                results["board-delete-restore"] = restored ? "passed" : "failed: board could not be restored"
                await store.openBoard(empty.id, projectID: board.projectID)
                await store.retireBoard(empty)
                let selectedRetired = await NativeUIAccessibility.wait {
                    store.selectedBoard?.retired == true
                        && NativeUIAccessibility.find("board.restore", in: window) != nil
                }
                results["board-delete-selected"] =
                    selectedRetired ? "passed" : "failed: selected deleted board did not offer restoration"
                NativeUISmokeRunner.capture(window, to: output.appending(path: "board-delete-selected.png"))
                await store.openBoard(board.id, projectID: board.projectID)

                // The original isolated fixture has cards and a paused schedule.
                // A rejected deletion must retain both the board and its selection.
                await store.retireBoard(board)
                let rejected = store.errorMessage != nil
                store.errorMessage = nil
                let protected = try await rpc.getBoard(board.id)
                results["board-delete-in-use"] =
                    rejected && !protected.retired && store.boards(for: board.projectID).contains { $0.id == board.id }
                    ? "passed" : "failed: in-use board was removed or rejection was hidden"
            } catch {
                results["board-delete"] = "failed: \(DieterRPCFailure.message(for: error))"
            }
        }

        private struct DeletePromptResult {
            let presented: Bool
            let diagnostic: String
        }

        private static func chooseDelete(_ board: Dieter_V1_Board, window: NSWindow) async -> DeletePromptResult {
            let identifier = "sidebar.board.\(board.id)"
            guard await NativeUIAccessibility.waitForInteractiveTarget(identifier, in: window),
                let frame = NativeUIAccessibility.find(identifier, in: window)?.recordedFrame
            else {
                return DeletePromptResult(
                    presented: false,
                    diagnostic: "target unavailable: \(NativeUIAccessibility.targetDiagnostics(identifier, in: window))"
                )
            }
            let screenPoint = NSPoint(x: frame.midX, y: frame.midY)
            guard NativeUIAccessibility.movePointer(to: screenPoint) else {
                return DeletePromptResult(
                    presented: false,
                    diagnostic:
                        "pointer move failed; \(NativeUIAccessibility.targetDiagnostics(identifier, in: window))"
                )
            }
            let pointerReady = await NativeUIAccessibility.wait(timeout: 2) {
                hypot(NSEvent.mouseLocation.x - screenPoint.x, NSEvent.mouseLocation.y - screenPoint.y) <= 4
            }
            guard pointerReady else {
                return DeletePromptResult(
                    presented: false,
                    diagnostic:
                        "pointer did not settle at \(screenPoint); actual=\(NSEvent.mouseLocation); \(NativeUIAccessibility.targetDiagnostics(identifier, in: window))"
                )
            }
            let point = window.convertPoint(fromScreen: screenPoint)
            let localPoint = window.contentView?.convert(point, from: nil) ?? point
            let hitType = window.contentView?.hitTest(localPoint).map { String(reflecting: type(of: $0)) } ?? "none"
            var attempts: [String] = []
            for attempt in 1...3 {
                let tracker = NativeContentMenuTracker()
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .rightMouseDown ? 1 : 0)
                    {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                let menuReady = await NativeUIAccessibility.wait(until: {
                    tracker.menu?.items.contains { $0.title == "Delete board…" && $0.isEnabled } == true
                })
                let titles = tracker.menu?.items.map { "\($0.title):\($0.isEnabled)" } ?? []
                guard menuReady, let menu = tracker.menu,
                    let index = menu.items.firstIndex(where: { $0.title == "Delete board…" && $0.isEnabled })
                else {
                    tracker.menu?.cancelTrackingWithoutAnimation()
                    tracker.stop()
                    attempts.append("attempt \(attempt) menu unavailable items=\(titles)")
                    try? await DieterTaskSleep.milliseconds(200)
                    continue
                }
                menu.cancelTrackingWithoutAnimation()
                menu.performActionForItem(at: index)
                tracker.stop()
                if await NativeUIAccessibility.wait { window.attachedSheet != nil } {
                    return DeletePromptResult(
                        presented: true,
                        diagnostic: "attempt \(attempt) presented; hit=\(hitType); items=\(titles)")
                }
                attempts.append("attempt \(attempt) action produced no sheet items=\(titles)")
                try? await DieterTaskSleep.milliseconds(200)
            }
            return DeletePromptResult(
                presented: false,
                diagnostic:
                    "hit=\(hitType); \(attempts.joined(separator: "; ")); \(NativeUIAccessibility.targetDiagnostics(identifier, in: window))"
            )
        }

        private static func pressDialog(_ title: String, window: NSWindow) -> Bool {
            guard let sheet = window.attachedSheet, let root = sheet.contentView else { return false }
            var pending = [root]
            while let view = pending.popLast() {
                if let button = view as? NSButton, button.title == title, button.isEnabled {
                    button.performClick(nil)
                    return true
                }
                pending.append(contentsOf: view.subviews)
            }
            return false
        }
    }
#endif
