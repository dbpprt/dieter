#if DIETER_UI_SMOKE
    import AppKit
    import SwiftUI

    @MainActor
    enum RequiredPermissionsUISmoke {
        static func run(output: URL) async -> String {
            var grants: Set<RequiredPermissions.Permission> = []
            var requested: [RequiredPermissions.Permission] = []
            var opened: [RequiredPermissions.Permission] = []
            let permissions = RequiredPermissions(
                check: { grants.contains($0) }, request: { requested.append($0) },
                openSettings: {
                    opened.append($0); return true
                })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Dieter Permission Setup Test"
            window.contentView = NSHostingView(
                rootView:
                    RequiredPermissionsGate {
                        Text("Workspace available").accessibilityIdentifier("permissions.workspace")
                            .smokeTarget("permissions.workspace")
                    }
                    .environment(permissions))
            window.center()
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try? await DieterTaskSleep.milliseconds(400)
            snapshot(window, output.appending(path: "00-permissions-required.png"))
            guard NativeUIAccessibility.click("permissions.grant.accessibility", in: window) else {
                return "failed: Accessibility grant button missing"
            }
            try? await DieterTaskSleep.milliseconds(200)
            guard requested == [.accessibility], opened == [.accessibility], !permissions.isReady else {
                return "failed: opening System Settings bypassed verification"
            }
            grants.insert(.accessibility)
            permissions.refresh()  // The same verification runs on return from System Settings.
            try? await DieterTaskSleep.milliseconds(200)
            guard permissions.accessibility && !permissions.isReady else {
                return "failed: one permission bypassed setup"
            }
            snapshot(window, output.appending(path: "00-permissions-partial.png"))
            guard NativeUIAccessibility.click("permissions.grant.screenRecording", in: window) else {
                return "failed: Screen Recording button missing"
            }
            try? await DieterTaskSleep.milliseconds(200)
            guard requested == [.accessibility, .screenRecording], !permissions.isReady else {
                return "failed: screen grant not verified"
            }
            grants.insert(.screenRecording)
            permissions.refresh()
            let unlocked = await waitUntil { NativeUIAccessibility.find("permissions.workspace", in: window) != nil }
            snapshot(window, output.appending(path: "00-permissions-ready.png"))
            guard permissions.isReady && unlocked else { return "failed: verified grants did not show workspace" }
            grants.remove(.accessibility)
            permissions.refresh()
            try? await DieterTaskSleep.milliseconds(200)
            guard !permissions.isReady,
                NativeUIAccessibility.find("permissions.grant.accessibility", in: window) != nil
            else { return "failed: revoked permission did not restore setup" }
            guard await NativeUIAccessibility.waitForInteractiveTarget("permissions.skip", in: window),
                NativeUIAccessibility.click("permissions.skip", in: window)
            else {
                return "failed: Skip for Now button missing"
            }
            let skipped = await waitUntil { NativeUIAccessibility.find("permissions.workspace", in: window) != nil }
            guard skipped, permissions.canUseApp, !permissions.isReady else {
                return
                    "failed: skip did not reveal workspace (visible=\(skipped), canUseApp=\(permissions.canUseApp), ready=\(permissions.isReady))"
            }
            snapshot(window, output.appending(path: "00-permissions-skipped.png"))
            return "passed"
        }

        private static func waitUntil(_ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if predicate() { return true }
                try? await DieterTaskSleep.milliseconds(25)
            }
            return false
        }

        private static func snapshot(_ window: NSWindow, _ url: URL) {
            guard let view = window.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url) }
        }
    }
#endif
