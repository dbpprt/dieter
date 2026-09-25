#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI

    @MainActor enum WorkspaceChromeUISmoke {
        static func run(store: DieterStore, window: NSWindow, output: URL) async -> [String: String] {
            let endpoints = store.endpoints
            let quotas = store.providerQuotaGroups
            let section = store.section
            let theme = store.themeSelection
            let size = window.contentView?.bounds.size ?? NSSize(width: 1380, height: 870)
            defer {
                store.endpoints = endpoints
                store.providerQuotaGroups = quotas
                store.section = section
                store.themeSelection = theme
                window.setContentSize(size)
            }
            var results: [String: String] = [:]
            var group = Dieter_Gateway_V1_ProviderQuotaGroup()
            group.provider = .openaiCodex
            group.accounts = (0..<3).map { index in
                var account = Dieter_Gateway_V1_ProviderQuotaSnapshot()
                account.accountKey = "chrome-\(index)"
                account.displayEmail = "account-\(index)@example.test"
                account.availability = .available
                var quota = Dieter_Gateway_V1_ProviderQuotaWindow()
                quota.remainingPercent = UInt32(45 + index * 20)
                account.windows = [quota]
                return account
            }
            store.providerQuotaGroups = [group]
            for count in [5, 20] {
                store.endpoints = (0..<count).map { index in
                    DieterEndpoint(
                        name: "Machine \(index + 1)", host: "127.0.0.1", port: 4242 + index,
                        daemonID: "chrome-machine-\(index)", online: false, version: "fixture")
                }
                window.setContentSize(NSSize(width: 1080, height: 680))
                for appearance in [DieterAppearance.dark, .light] {
                    store.themeSelection = .init(
                        appearance: appearance, palette: .monochrome, transparencyEnabled: true)
                    for destination in [AppSection.inbox, .screens, .settings, .chats] {
                        store.section = destination
                        try? await DieterTaskSleep.milliseconds(250)
                        // Scroll the shared status region to its end as a user would.
                        if let anchor = NativeUISmokeTargets.frames["sidebar.quotas-title"]?.compactMap(\.view).first(
                            where: { $0.window === window }),
                            let scroll = anchor.enclosingScrollView, let document = scroll.documentView
                        {
                            let end =
                                document.isFlipped ? max(0, document.bounds.height - scroll.contentSize.height) : 0
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                        try? await DieterTaskSleep.milliseconds(150)
                        let key = "chrome-\(count)-\(appearance.rawValue)-\(destination.rawValue)"
                        let ids =
                            ["sidebar.quotas-title"]
                            + (0..<3).map { "sidebar.quota.\(group.provider.rawValue):chrome-\($0)" } + [
                                "sidebar.settings"
                            ]
                        let frames = ids.compactMap { NativeUIAccessibility.find($0, in: window)?.recordedFrame }
                        let ordered = zip(frames, frames.dropFirst()).allSatisfy { upper, lower in
                            upper.minY >= lower.maxY - 1
                        }
                        results[key + "-quotas"] =
                            frames.count == ids.count && ordered && frames.allSatisfy { $0.height >= 9 }
                            ? "passed" : "failed: \(frames)"
                        let viewport = NativeUIAccessibility.find("sidebar.scroll-region", in: window)?.recordedFrame
                        let navigation = NativeUIAccessibility.find("sidebar.screens", in: window)?.recordedFrame
                        results[key + "-scroll-viewport"] =
                            viewport != nil && navigation != nil
                                && viewport!.maxY <= navigation!.minY + 1
                                && frames.dropLast().allSatisfy { viewport!.insetBy(dx: -1, dy: -1).contains($0) }
                            ? "passed"
                            : "failed: viewport=\(String(describing: viewport)) navigation=\(String(describing: navigation))"
                        let split = NativeUIAccessibility.navigationSplitController(in: window)
                        results[key + "-shared-backdrop"] =
                            split is WorkspaceSplitController ? "passed" : "failed: separate system sidebar material"
                        if count == 5 {
                            NativeUISmokeRunner.capture(window, to: output.appending(path: key + ".png"))
                        }
                    }
                }
            }
            return results
        }
    }
#endif
