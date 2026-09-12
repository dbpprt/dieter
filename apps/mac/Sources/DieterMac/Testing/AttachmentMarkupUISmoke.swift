#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import ImageIO
    @preconcurrency import ScreenCaptureKit
    import UniformTypeIdentifiers

    @MainActor enum AttachmentMarkupUISmoke {
        static func composer(
            store: DieterStore, window: NSWindow, results: inout [String: String], output: URL
        ) async {
            guard let original = store.composerAttachments.first else {
                results["attachment-markup"] = "failed: image-paste fixture missing"; return
            }
            for apply in [false, true] {
                let opened = NativeUIAccessibility.click("attachment.annotate.\(original.filename)", in: window)
                let mounted = await NativeUIAccessibility.wait {
                    NSApp.windows.contains { $0.isVisible && $0.isSheet && canvas(in: $0.contentView) != nil }
                }
                guard opened, mounted,
                    let sheet = NSApp.windows.first(where: {
                        $0.isVisible && $0.isSheet && canvas(in: $0.contentView) != nil
                    }),
                    let editor = canvas(in: sheet.contentView)
                else { results["attachment-markup"] = "failed: native annotate button did not open canvas"; return }
                let tool = NativeUIAccessibility.click("attachment.markup.tool.arrow", in: sheet)
                let color = NativeUIAccessibility.click("attachment.markup.color.blue", in: sheet)
                let configured = await NativeUIAccessibility.wait {
                    editor.document.tool == .arrow && editor.document.color == .blue
                }
                postStroke(in: editor)
                let drawn = await NativeUIAccessibility.wait { editor.document.strokes.count == 1 }
                results["attachment-markup-gesture"] =
                    tool && color && configured && drawn && store.composerAttachments.first == original
                    ? "passed" : "failed: native drawing/tools changed staging before Apply or did not draw"
                if !apply {
                    let undo = NativeUIAccessibility.click("attachment.markup.undo", in: sheet)
                    let undone = await NativeUIAccessibility.wait {
                        editor.document.strokes.isEmpty && editor.document.canRedo
                    }
                    results["attachment-markup-undo"] =
                        undo && undone ? "passed" : "failed: native Undo did not remove mark"
                    postStroke(in: editor)
                    _ = await NativeUIAccessibility.wait { editor.document.hasChanges }
                }
                capture(sheet, to: output.appending(path: "04d-attachment-markup.png"))
                if apply { await captureStage(sheet, output: output, phase: "markup") }
                let action = NativeUIAccessibility.click("attachment.markup.\(apply ? "apply" : "cancel")", in: sheet)
                let dismissed = await NativeUIAccessibility.wait { !sheet.isVisible && window.attachedSheet == nil }
                if apply {
                    let changed = await NativeUIAccessibility.wait {
                        store.composerAttachments.count == 1 && store.composerAttachments[0].data != original.data
                    }
                    let current = store.composerAttachments.first
                    results["attachment-markup-apply"] =
                        action && dismissed && changed && current?.mediaType == "image/png"
                            && current.flatMap({ NSBitmapImageRep(data: $0.data) }) != nil
                        ? "passed" : "failed: Apply did not replace the staged attachment with a valid marked PNG"
                } else {
                    results["attachment-markup-cancel"] =
                        action && dismissed && store.composerAttachments == [original]
                        ? "passed" : "failed: Cancel changed the original staged image or left the editor open"
                }
            }
        }

        static func captureInspector(window: NSWindow, output: URL) async -> [String: String] {
            var results: [String: String] = [:]
            let ready = await NativeUIAccessibility.wait { canvas(in: window.contentView) != nil }
            guard ready, let editor = canvas(in: window.contentView),
                let story = NativeUIAccessibility.find("quick-task.story", in: window)?.recordedFrame
            else { return ["capture-markup": "failed: capture inspector or task input missing"] }
            let original = editor.document.original
            let editorFrame = window.convertToScreen(editor.convert(editor.bounds, to: nil))
            results["capture-markup-right-pane"] =
                editorFrame.minX > story.maxX
                ? "passed" : "failed: screenshot canvas is not to the right of task inputs"
            postStroke(in: editor)
            let drawn = await NativeUIAccessibility.wait { editor.document.hasChanges }
            let originalSize = window.frame.size
            window.setContentSize(.init(width: 454, height: 720))
            let retained = await NativeUIAccessibility.wait {
                guard let current = canvas(in: window.contentView) else { return false }
                return current === editor && current.document.hasChanges && current.frame.width < 454
            }
            results["capture-markup-adaptive"] =
                drawn && retained
                ? "passed" : "failed: narrow layout dropped the canvas or pending marks"
            window.setFrame(CGRect(origin: window.frame.origin, size: originalSize), display: true)
            _ = await NativeUIAccessibility.wait { (canvas(in: window.contentView)?.frame.width ?? 0) > 400 }
            let applied = NativeUIAccessibility.click("attachment.markup.apply", in: window)
            let updated = await NativeUIAccessibility.wait {
                guard let current = canvas(in: window.contentView) else { return false }
                return current.document.original.data != original.data && !current.document.hasChanges
            }
            results["capture-markup-apply"] =
                applied && updated
                ? "passed" : "failed: capture Apply did not update the attachment bytes"
            capture(window, to: output.appending(path: "capture-task-annotated.png"))
            await captureStage(window, output: output, phase: "quick-task-capture")
            return results
        }

        private static func captureStage(_ window: NSWindow, output: URL, phase: String) async {
            guard ProcessInfo.processInfo.environment["DIETER_CONTENT_CAPTURE"] == "1" else { return }
            if phase == "quick-task-capture" {
                await captureOwnWindow(window, output: output)
            }
            let request = output.appending(path: "capture-request.json")
            let marker = ["phase": phase, "windowNumber": String(window.windowNumber)]
            if let data = try? JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: request, options: .atomic)
            }
            defer { try? FileManager.default.removeItem(at: request) }
            _ = await NativeUIAccessibility.wait(timeout: 30) {
                FileManager.default.fileExists(atPath: output.appending(path: "capture-ack-\(phase)").path)
            }
        }

        /// ScreenCaptureKit includes the window-server material composition that
        /// cacheDisplay omits. Capture only this process's exact visible fixture
        /// window, with previously granted permission and no consent request.
        private static func captureOwnWindow(_ window: NSWindow, output: URL) async {
            let diagnostic = output.appending(path: "external-quick-task-capture.txt")
            guard CGPreflightScreenCaptureAccess() else {
                try? "skipped: existing Screen Recording permission unavailable".write(
                    to: diagnostic, atomically: true, encoding: .utf8)
                return
            }
            let windowID = CGWindowID(window.windowNumber)
            let processID = ProcessInfo.processInfo.processIdentifier
            var completed = false
            var outcome = "failed: own-window screenshot timed out"
            let attempt = Task { @MainActor in
                defer { completed = true }
                do {
                    let content = try await SCShareableContent.currentProcess
                    guard !Task.isCancelled, window.isVisible, window.windowNumber == Int(windowID),
                        let target = content.windows.first(where: {
                            $0.windowID == windowID && $0.owningApplication?.processID == processID && $0.isOnScreen
                        })
                    else {
                        outcome = "failed: exact visible fixture window unavailable"
                        return
                    }
                    let filter = SCContentFilter(desktopIndependentWindow: target)
                    let configuration = SCStreamConfiguration()
                    let scale = CGFloat(filter.pointPixelScale)
                    configuration.width = max(1, Int((filter.contentRect.width * scale).rounded(.up)))
                    configuration.height = max(1, Int((filter.contentRect.height * scale).rounded(.up)))
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    configuration.captureResolution = .best
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: configuration)
                    guard !Task.isCancelled, window.isVisible, window.windowNumber == Int(windowID) else { return }
                    let url = output.appending(path: "external-quick-task-capture.png")
                    guard
                        let destination = CGImageDestinationCreateWithURL(
                            url as CFURL, UTType.png.identifier as CFString, 1, nil)
                    else {
                        outcome = "failed: could not create own-window PNG"
                        return
                    }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else {
                        outcome = "failed: could not encode own-window PNG"
                        return
                    }
                    outcome =
                        "captured: process=\(processID), window=\(windowID), pixels=\(image.width)x\(image.height)"
                } catch {
                    outcome = "failed: \(error.localizedDescription)"
                }
            }
            _ = await NativeUIAccessibility.wait(timeout: 8) { completed }
            if !completed { attempt.cancel() }
            try? outcome.write(to: diagnostic, atomically: true, encoding: .utf8)
        }

        private static func canvas(in view: NSView?) -> AttachmentMarkupCanvasView? {
            guard let view else { return nil }
            if let canvas = view as? AttachmentMarkupCanvasView { return canvas }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }

        private static func postStroke(in canvas: AttachmentMarkupCanvasView) {
            guard let window = canvas.window else { return }
            let rect = canvas.imageRect
            for (type, fraction) in [
                (NSEvent.EventType.leftMouseDown, CGPoint(x: 0.2, y: 0.3)),
                (.leftMouseDragged, CGPoint(x: 0.5, y: 0.4)),
                (.leftMouseDragged, CGPoint(x: 0.75, y: 0.7)),
                (.leftMouseUp, CGPoint(x: 0.75, y: 0.7)),
            ] {
                let point = CGPoint(x: rect.minX + rect.width * fraction.x, y: rect.minY + rect.height * fraction.y)
                if let event = NSEvent.mouseEvent(
                    with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }

        private static func capture(_ window: NSWindow, to url: URL) {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
#endif
