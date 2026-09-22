#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import Foundation

    extension NativeUISmokeRunner {
        static func runBoardCardOpeningMeasurements(
            store: DieterStore, window: NSWindow, results: inout [String: String], output: URL
        ) async {
            guard let card = BoardCardOrdering.sorted(store.displayedCards.filter { $0.lane == "todo" }).first else {
                results["board-card-open-measurement"] = "failed: no card"
                return
            }
            var measurements: [String] = []
            var readCounts: [String] = []
            for sample in 1...3 {
                store.closeConversation()
                try? await DieterTaskSleep.milliseconds(300)
                let requests = store.stateRequestGeneration
                BoardRenderingDiagnostics.start()
                let start = ProcessInfo.processInfo.systemUptime
                let clicked = NativeUIAccessibility.click("card.\(card.id)", in: window)
                let deadline = start + 5
                while store.selectedCardID != card.id, ProcessInfo.processInfo.systemUptime < deadline {
                    try? await DieterTaskSleep.milliseconds(5)
                }
                let selectedMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                while store.conversation?.detail.card.id != card.id, ProcessInfo.processInfo.systemUptime < deadline {
                    try? await DieterTaskSleep.milliseconds(5)
                }
                let readyMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                try? await DieterTaskSleep.milliseconds(300)
                let counts = BoardRenderingDiagnostics.stop()
                let metrics = counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: " ")
                let loaded = store.conversation?.detail.card.id == card.id
                measurements.append(
                    "sample=\(sample) clicked=\(clicked) loaded=\(loaded) selection_ms=\(String(format: "%.1f", selectedMS)) content_ms=\(String(format: "%.1f", readyMS)) \(metrics)"
                )
                readCounts.append(String(store.stateRequestGeneration - requests))
                results["board-card-open-\(sample)"] =
                    clicked && loaded && counts["fullReload"] == 0 && counts["tableCreated"] == 0
                        && store.stateRequestGeneration == requests
                    ? "passed" : "failed: card opening rebuilt lanes, fetched the project, or failed to load"
                if sample == 1 { capture(window, to: output.appending(path: "04-card-open-board.png")) }
            }
            results["board-card-open-measurements"] = measurements.joined(separator: "; ")
            results["board-card-open-project-reads"] = readCounts.joined(separator: ", ")
            results["board-card-open-measurement-definition"] =
                "Native click invocation to observed selection and loaded snapshot, sampled every 5 ms. Rendering counters include 300 ms settling. Not compositor presentation."
            store.closeConversation()
            try? await DieterTaskSleep.milliseconds(500)
            let rightLane = store.selectedBoard?.lanes.last?.id ?? "done"
            let rightCard = BoardCardOrdering.sorted(store.displayedCards.filter { $0.lane == rightLane }).first
            for (index, target) in [card, rightCard].compactMap({ $0 }).enumerated() {
                let doubleClicked = await NativeUIAccessibility.doubleClickAcrossLayout("card.\(target.id)", in: window)
                let edited = await waitUntil(timeout: 4) {
                    guard let sheet = window.attachedSheet else { return false }
                    return NativeUIAccessibility.find("card-editor.\(target.id)", in: sheet) != nil
                }
                results["board-card-double-click-edit-\(index)"] =
                    doubleClicked && edited ? "passed" : "failed: immediate card opening prevented double-click editing"
                if let sheet = window.attachedSheet {
                    let cancelled = NativeUIAccessibility.click("card-editor.cancel", in: sheet)
                    let dismissed = await waitUntil(timeout: 3) { window.attachedSheet == nil }
                    results["board-card-editor-dismiss-\(index)"] =
                        cancelled && dismissed ? "passed" : "failed: editor remained open"
                    if !dismissed { return }
                }
                store.closeConversation()
                try? await DieterTaskSleep.milliseconds(500)
            }
            try? await DieterTaskSleep.milliseconds(1_000)
            BoardRenderingDiagnostics.start()
            let idleStart = ProcessInfo.processInfo.systemUptime
            var cpuStart = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpuStart)
            try? await DieterTaskSleep.milliseconds(10_000)
            var cpuEnd = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpuEnd)
            let idleSeconds = ProcessInfo.processInfo.systemUptime - idleStart
            let cpuSeconds = Double(cpuEnd.tv_sec - cpuStart.tv_sec) + Double(cpuEnd.tv_nsec - cpuStart.tv_nsec) / 1e9
            let idleCounts = BoardRenderingDiagnostics.stop()
            results["board-idle-cpu"] = String(
                format: "%.3f CPU seconds / %.3f wall seconds = %.2f%% of one core", cpuSeconds, idleSeconds,
                cpuSeconds / idleSeconds * 100)
            results["board-idle-rendering"] = idleCounts.keys.sorted().map { "\($0)=\(idleCounts[$0]!)" }.joined(
                separator: " ")
        }

    }
#endif
