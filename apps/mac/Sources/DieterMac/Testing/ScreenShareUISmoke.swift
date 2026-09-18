#if DIETER_UI_SMOKE
    import AppKit

    @MainActor enum ScreenShareUISmoke {
        static func run(store: DieterStore, session: ScreenShareSession, window: NSWindow, output: URL) async
            -> [String: String]
        {
            var results: [String: String] = [:]
            let surface = session.videoSurface
            let renderer = session.controller.renderer
            let clicked = NativeUIAccessibility.click("screens.undock", in: window)
            let entered = await wait {
                guard let viewer = store.screensModel.detachedWindows[session.id], let detached = viewer.window else {
                    return false
                }
                return detached.styleMask.contains(.fullScreen) && !viewer.transitioning && surface.window === detached
            }
            guard clicked, entered, let viewer = store.screensModel.detachedWindows[session.id],
                let detached = viewer.window
            else {
                return [
                    "01a-screen-undock": "failed: expand button did not move the live surface into native full screen"
                ]
            }
            defer { session.controller.controlActive = false; store.screensModel.dock(session.id) }
            results["01a-screen-undock"] =
                session.controller.renderer === renderer && renderer.superview === surface
                    && session.controller.clipboardWindow === detached
                ? "passed" : "failed: undocking replaced the renderer or left clipboard in the main window"
            let active = await wait { NSApp.isActive && detached.isKeyWindow }
            detached.makeFirstResponder(nil)
            // This fixture deliberately has no peer. Test real AppKit activation
            // and cursor presentation without sending input to an unowned host.
            session.controller.remoteCursorState.visible = true
            session.controller.remoteCursorState.normalizedX = 100_000
            session.controller.remoteCursorState.normalizedY = 100_000
            session.controller.remoteCursor = .crosshair
            session.controller.controlActive = true
            let center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
            let began = ProcessInfo.processInfo.systemUptime
            surface.refreshCursor(at: center)
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
            results["01a-screen-local-cursor"] =
                active && !session.controller.inputFocused && surface.cursorPresentation == .local
                    && !surface.hostCursorVisible && NSCursor.current === session.controller.remoteCursor
                ? "passed"
                : "failed: active=\(active), presentation=\(surface.cursorPresentation), overlay=\(surface.hostCursorVisible)"
            results["01a-screen-cursor-local-update-ms"] = String(format: "%.3f", elapsed)
            surface.refreshCursor(at: CGPoint(x: -1, y: -1))
            results["01a-screen-cursor-leave"] =
                surface.cursorPresentation == .remote && surface.hostCursorVisible
                ? "passed" : "failed: leaving the video did not restore the host-position cursor"
            session.controller.controlActive = false
            surface.refreshCursor(at: center)
            results["01a-screen-view-only-cursor"] =
                surface.cursorPresentation == .remote && surface.hostCursorVisible
                ? "passed" : "failed: view-only mode did not show exactly the host cursor"
            session.controller.sessionState.embeddedCursor = true
            surface.refreshCursor(at: center)
            results["01a-screen-embedded-cursor"] =
                surface.cursorPresentation == .embedded && !surface.hostCursorVisible
                ? "passed" : "failed: embedded cursor also displayed an overlay"
            session.controller.sessionState.embeddedCursor = false
            capture(detached, to: output.appending(path: "01a-screen-fullscreen.png"))

            detached.makeFirstResponder(surface)
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: detached.windowNumber, context: nil,
                characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)
            {
                detached.sendEvent(event)
            }
            let exited = await wait { !detached.styleMask.contains(.fullScreen) && !viewer.transitioning }
            results["01a-screen-fullscreen-shortcut"] =
                exited && session.isDetached && surface.window === detached
                ? "passed" : "failed: Control-Command-F did not leave full screen in the same window"
            capture(detached, to: output.appending(path: "01a-screen-floating.png"))
            store.openSettings()
            try? await Task.sleep(for: .milliseconds(300))
            let dockButton = detached.toolbar?.items.first { $0.itemIdentifier.rawValue == "screen.dock" }
            let returned =
                dockButton?.action.map { NSApp.sendAction($0, to: dockButton?.target, from: dockButton) } ?? false
            let docked = await wait { !session.isDetached && surface.window === window && store.section == .screens }
            results["01a-screen-return-to-dieter"] =
                returned && docked && session.controller.phase == .streaming
                    && session.controller.clipboardWindow === window && !detached.isVisible
                ? "passed" : "failed: Return to Dieter did not reopen Screens with the same live session"
            return results
        }

        private static func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<120 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }

        private static func capture(_ window: NSWindow, to url: URL) {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
        }
    }
#endif
