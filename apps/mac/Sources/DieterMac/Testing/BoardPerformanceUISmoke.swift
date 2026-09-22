#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import Foundation

    extension NativeUISmokeRunner {
        static func runChatSwitchMeasurements(
            store: DieterStore, window: NSWindow, results: inout [String: String], output: URL
        ) async {
            await store.openChats()
            let cards = Array(store.chats.filter { $0.pinned && $0.title.hasPrefix("Performance chat ") }.prefix(2))
            guard cards.count == 2 else {
                results["chat-switch-workload"] = "failed: expected two pinned performance chats"
                return
            }
            try? await DieterTaskSleep.milliseconds(500)
            var samples: [[String: Any]] = []
            for index in 0..<30 {
                let card = cards[index % cards.count]
                let stateReads = store.stateRequestGeneration
                let chatReads = store.chatsRequestGeneration
                BoardRenderingDiagnostics.start()
                let start = ProcessInfo.processInfo.systemUptime
                let clicked = NativeUIAccessibility.click("chat.\(card.id)", in: window)
                let dispatchMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                let deadline = start + 10
                while store.selectedChatID != card.id, ProcessInfo.processInfo.systemUptime < deadline {
                    try? await DieterTaskSleep.milliseconds(5)
                }
                let selectionMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                while (store.conversation?.detail.card.id != card.id || store.conversation?.page.total != 300),
                    ProcessInfo.processInfo.systemUptime < deadline
                {
                    try? await DieterTaskSleep.milliseconds(5)
                }
                let contentMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                while BoardRenderingDiagnostics.readyConversationID != card.id,
                    ProcessInfo.processInfo.systemUptime < deadline
                {
                    try? await DieterTaskSleep.milliseconds(5)
                }
                let displayed = BoardRenderingDiagnostics.readyConversationID == card.id
                let presentationMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                try? await DieterTaskSleep.milliseconds(200)
                let counters = BoardRenderingDiagnostics.stop()
                let ready =
                    store.conversation?.detail.card.id == card.id
                    && store.conversation?.page.total == 300 && store.conversation?.conversation.messages.count == 30
                samples.append([
                    "index": index, "first_selection": index < 2, "clicked": clicked, "ready": ready,
                    "dispatch_ms": dispatchMS, "selection_ms": selectionMS, "content_ms": contentMS,
                    "presentation_ms": presentationMS, "displayed": displayed,
                    "project_generation": store.stateRequestGeneration - stateReads,
                    "chat_generation": store.chatsRequestGeneration - chatReads,
                    "footprint_bytes": performancePhysicalFootprint(), "rendering": counters,
                ])
                if !clicked || !ready || !displayed {
                    results["chat-switch-workload"] =
                        "failed: sample \(index) click=\(clicked) ready=\(ready) displayed=\(displayed)"
                    break
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appending(path: "chat-switch-samples.json"))
            }
            if results["chat-switch-workload"] == nil { results["chat-switch-workload"] = "passed" }
            results["chat-switch-metric-definition"] =
                "30 alternating native row clicks across two 300-message tool-heavy chats. Dispatch, selection, bounded 30-message snapshot readiness and timeline-ready state sampled every 5 ms; none is compositor presentation. Rendering/physical footprint include 200 ms settling. First two samples are first selections, which may already have Live cache coverage; remaining 28 revisit the selected chats."
            capture(window, to: output.appending(path: "performance-chat.png"))
            await measureQuietSurface(store: store, section: .chats, name: "chat-conversation", results: &results)
            let lastChatID = store.selectedChatID
            var returns: [[String: Any]] = []
            for index in 0..<5 {
                store.openScreens()
                try? await DieterTaskSleep.milliseconds(500)
                let probe = NativeUINavigationProbe(window: window, section: .chats)
                BoardRenderingDiagnostics.start()
                let generation = store.chatsRequestGeneration
                let start = ProcessInfo.processInfo.systemUptime
                probe.start()
                let clicked = NativeUIAccessibility.click("sidebar.all-chats", in: window)
                let deadline = start + 10
                while (probe.firstDrawMS == nil || BoardRenderingDiagnostics.readyConversationID != lastChatID),
                    ProcessInfo.processInfo.systemUptime < deadline
                {
                    try? await DieterTaskSleep.milliseconds(5)
                }
                let ready =
                    store.selectedChatID == lastChatID && probe.firstDrawMS != nil
                    && BoardRenderingDiagnostics.readyConversationID == lastChatID
                let readyMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                probe.stop()
                let counters = BoardRenderingDiagnostics.stop()
                returns.append([
                    "index": index, "clicked": clicked, "ready": ready,
                    "draw_ms": probe.firstDrawMS ?? -1, "presentation_ms": readyMS,
                    "chat_generation": store.chatsRequestGeneration - generation, "rendering": counters,
                ])
                if !clicked || !ready {
                    results["chat-return-workload"] = "failed: last conversation did not return on sample \(index)"
                    break
                }
            }
            if results["chat-return-workload"] == nil { results["chat-return-workload"] = "passed" }
            if let data = try? JSONSerialization.data(withJSONObject: returns, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appending(path: "chat-return-samples.json"))
            }
            store.closeConversation()
        }

        static func performancePhysicalFootprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }

        static func measureQuietSurface(
            store: DieterStore, section: AppSection, name: String? = nil, results: inout [String: String]
        ) async {
            try? await DieterTaskSleep.milliseconds(1_000)
            let stateReads = store.stateRequestGeneration
            let chatReads = store.chatsRequestGeneration
            let footprint = performancePhysicalFootprint()
            let start = ProcessInfo.processInfo.systemUptime
            var before = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &before)
            BoardRenderingDiagnostics.start()
            try? await DieterTaskSleep.milliseconds(10_000)
            var after = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &after)
            let wall = ProcessInfo.processInfo.systemUptime - start
            let cpu = Double(after.tv_sec - before.tv_sec) + Double(after.tv_nsec - before.tv_nsec) / 1e9
            let counts = BoardRenderingDiagnostics.stop()
            let metric = "quiet-\(name ?? section.rawValue.lowercased())"
            results[metric] =
                String(format: "cpu_s=%.6f wall_s=%.3f core_percent=%.3f", cpu, wall, 100 * cpu / wall)
                + " footprint_start=\(footprint) footprint_end=\(performancePhysicalFootprint())"
                + " project_generation=\(store.stateRequestGeneration - stateReads) chat_generation=\(store.chatsRequestGeneration - chatReads)"
                + " " + counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: " ")
        }

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
