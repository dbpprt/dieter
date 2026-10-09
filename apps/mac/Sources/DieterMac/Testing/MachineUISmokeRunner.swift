#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import Foundation

    /// Machine smoke validates the daemon's telemetry contract, including the
    /// explicit absence reported by virtual Macs without a GPU passthrough.
    enum MachineGPUTelemetrySmokeCheck {
        static func result(for information: Dieter_V1_MachineInformation) -> String {
            guard information.hasGpu else { return "failed: GPU telemetry was absent" }
            let telemetry = information.gpu
            switch telemetry.state {
            case .unavailable:
                guard telemetry.devices.isEmpty else {
                    return "failed: unavailable GPU telemetry contained devices"
                }
                guard !telemetry.unavailableReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return "failed: unavailable GPU telemetry omitted its reason"
                }
                return "passed: GPU telemetry unavailable (\(telemetry.unavailableReason))"
            case .noDevices:
                return telemetry.devices.isEmpty
                    ? "passed: no GPU devices reported" : "failed: no-devices GPU telemetry contained devices"
            case .partial, .available:
                guard !telemetry.devices.isEmpty else { return "failed: GPU telemetry state required devices" }
                guard
                    telemetry.devices.allSatisfy({
                        !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
                else { return "failed: GPU device identity was incomplete" }
                guard Set(telemetry.devices.map(\.id)).count == telemetry.devices.count else {
                    return "failed: GPU device identities were duplicated"
                }
                return "passed"
            case .unspecified, .UNRECOGNIZED:
                return "failed: GPU telemetry state was unspecified or unrecognized"
            }
        }
    }

    /// Focused packaged-app verification for the authenticated machine path. Its
    /// restart check requires the owned fixture's daemon ID and loopback gateway;
    /// it never invokes a power operation on an operator daemon.
    @MainActor
    enum MachineUISmokeRunner {
        static func isOwnedFixture(
            machine: MachineEndpoint, expectedDaemonID: String?, fixtureEndpoint: String?
        ) -> Bool {
            guard let expectedDaemonID, !expectedDaemonID.isEmpty,
                let fixtureEndpoint, let gateway = MachineEndpoint(address: fixtureEndpoint, name: "Fixture"),
                !gateway.secure, gateway.host == "127.0.0.1" || gateway.host == "::1"
            else { return false }
            return machine.daemonID == expectedDaemonID && machine.credentialID == gateway.credentialID
        }

        static func run(store: DieterStore) async {
            let output = outputDirectory()
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            guard
                await waitUntil(
                    timeout: 25,
                    condition: {
                        store.workspaceIsLive && store.machines.contains(where: \.online)
                    })
            else {
                writeReport(
                    ["connection": "failed: no live enrolled machine (\(store.session.phaseLabel))"], to: output)
                return
            }
            guard let machine = store.machines.first(where: \.online) else {
                writeReport(["connection": "failed: machine directory was empty"], to: output)
                return
            }

            let sectionBeforeOpening = store.section
            await store.fleet.openMachine(machine.id)
            guard
                await waitUntil(
                    timeout: 15,
                    condition: {
                        store.fleet.selectedMachineID == machine.id && store.fleet.machineInformation[machine.id] != nil
                    }), let information = store.fleet.machineInformation[machine.id]
            else {
                writeReport(
                    [
                        "connection": "passed",
                        "machine-rpc": "failed: \(store.fleet.machineInformationError ?? "telemetry unavailable")",
                    ], to: output)
                return
            }

            guard
                let window = NSApp.windows.first(where: {
                    $0.isVisible && $0.contentView != nil && $0.title == "Dieter"
                })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            else {
                writeReport(["window": "failed: Dieter window not found"], to: output)
                return
            }
            // SwiftUI publishes its real accessibility nodes lazily when an
            // assistive client requests the enhanced interface. This runner is
            // in-process, so make that AppKit request before observing labels.
            NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            window.setContentSize(NSSize(width: 1_380, height: 780))
            window.center()
            window.makeKeyAndOrderFront(nil)
            try? await DieterTaskSleep.seconds(3)

            var results: [String: String] = [
                "connection": "passed",
                "presentation": store.section == sectionBeforeOpening && store.fleet.selectedMachineID == machine.id
                    ? "passed" : "failed: machine information replaced the current page",
                "machine-rpc": information.hostname.isEmpty || information.osName.isEmpty
                    ? "failed: host identity was incomplete" : "passed",
                "telemetry": information.logicalCpuCount == 0 || information.cpuCoreUsagePercent.isEmpty
                    || information.memoryTotalBytes == 0 || information.diskTotalBytes == 0
                    ? "failed: telemetry was incomplete" : "passed",
                "dieter-processes": information.processes.contains(where: { $0.kind == "daemon" })
                    ? "passed" : "failed: daemon process was absent",
                "gpu": MachineGPUTelemetrySmokeCheck.result(for: information),
                "daemon-version": information.hasDaemonBuild && !information.daemonBuild.releaseVersion.isEmpty
                    ? "passed" : "failed: daemon build identity was absent",
                "gateway-version": store.gatewayInformation[machine.credentialID]?.releaseVersion.isEmpty == false
                    ? "passed" : "failed: gateway build identity was absent",
                "host-controls": [.restart, .shutdown].allSatisfy { action in
                    store.fleet.machineOperations[machine.id]?.contains { $0.action == action && $0.available } == true
                } ? "passed" : "failed: restart/shutdown were unavailable",
                "daemon-update-capability": information.operationCapabilities.contains {
                    $0.action == .updateDaemon && $0.supported && $0.authorized
                } ? "passed" : "failed: daemon update was unavailable",
                "route": store.machineEntry(machine)?.route.isEmpty != false
                    ? "failed: no authenticated route measurement" : "passed",
            ]
            if ProcessInfo.processInfo.environment["DIETER_TEST_CONTROL_WEBRTC"] == "1" {
                results["webrtc-route"] =
                    store.machineEntry(machine)?.route == "WebRTC · Direct"
                    ? "passed" : "failed: fixture did not select direct WebRTC"
            }
            results["render"] =
                capture(window: window, to: output.appendingPathComponent("machine-information.png"))
                ? "passed" : "failed: could not capture machine popup"
            if isOwnedFixture(
                machine: machine,
                expectedDaemonID: NativeTestSupport.argument("--ui-smoke-fixture-daemon"),
                fixtureEndpoint: NativeTestSupport.argument("--dieter-endpoint")),
                store.fleet.selectedMachineID == machine.id
            {
                let setupAction = await performPrivacyThroughUI(
                    .privacySetup, store: store, window: window, output: output)
                results["privacy-setup"] = setupAction ? "passed" : "failed: native setup action was not accepted"
                _ = await waitUntil(timeout: 10) {
                    store.fleet.machineOperations[machine.id]?.contains { $0.action == .privacyOn && $0.available }
                        == true
                }
                let lockAction = await performPrivacyThroughUI(.privacyOn, store: store, window: window, output: output)
                let closed = NativeUIAccessibility.press("machine.close", in: window)
                let locked = await waitUntil(timeout: 10) {
                    store.machineEntry(machine)?.privacyActive == true
                        && store.machineEntry(machine)?.privacyStale == false
                }
                results["privacy-lock"] =
                    lockAction && closed && locked
                    ? "passed" : "failed: native Lock action or sidebar stream after closing details failed"
                let badge = await waitUntil(timeout: 5) {
                    NativeUIAccessibility.find("machine.\(machine.daemonID ?? machine.id)", in: window)?.text.contains(
                        "Privacy mode on") == true
                }
                let rendered = capture(window: window, to: output.appendingPathComponent("privacy-sidebar.png"))
                let accessibility = NativeUIAccessibility.elements(in: window).map {
                    "\($0.identifier ?? "") \($0.text)"
                }.joined(separator: "\n")
                try? accessibility.write(
                    to: output.appendingPathComponent("privacy-accessibility.txt"), atomically: true, encoding: .utf8)
                results["privacy-render"] =
                    badge && rendered
                    ? "passed" : "failed: privacy sidebar badge was absent from accessibility or capture"
                let reopened = NativeUIAccessibility.press("machine.\(machine.daemonID ?? machine.id)", in: window)
                let unlockAction = await performPrivacyThroughUI(
                    .privacyOff, store: store, window: window, output: output)
                let unlocked = await waitUntil(timeout: 10) {
                    store.machineEntry(machine)?.privacyActive == false
                        && store.machineEntry(machine)?.privacyWarning == false
                }
                results["privacy-unlock"] =
                    reopened && unlockAction && unlocked
                    ? "passed" : "failed: native Unlock action or sidebar update failed"
                await store.fleet.performMachineOperation(.updateDaemon)
                results["daemon-update"] =
                    store.fleet.machineOperationMessage?.contains("reconnect") == true
                    ? "passed" : "failed: isolated daemon update was not accepted"
                store.fleet.machineOperationMessage = nil
                try? await DieterTaskSleep.seconds(1)
                guard store.fleet.selectedMachineID == machine.id else {
                    results["power-control"] = "failed: selected machine changed before isolated restart"
                    writeReport(results, to: output)
                    return
                }
                await store.fleet.performMachineOperation(.restart)
                results["power-control"] =
                    store.fleet.machineOperationMessage?.isEmpty == false
                    ? "passed" : "failed: isolated restart was not accepted"
                store.fleet.machineOperationMessage = nil
            } else {
                results["power-control"] = "failed: target does not match the owned isolated fixture"
            }
            writeReport(results, to: output)
        }

        private static func outputDirectory() -> URL {
            NativeTestSupport.outputDirectory(flag: "--machine-ui-smoke-output")
        }

        private static func performPrivacyThroughUI(
            _ action: Dieter_V1_MachineOperationAction, store: DieterStore, window: NSWindow, output: URL
        ) async -> Bool {
            let menuTitle =
                action == .privacySetup
                ? "Set Up Privacy Mode…" : (action == .privacyOn ? "Lock Local Screen…" : "Unlock Local Screen…")
            let tracker = NativeContentMenuTracker()
            defer { tracker.stop(); tracker.menu?.cancelTrackingWithoutAnimation() }
            let ready = await NativeUIAccessibility.waitForInteractiveTarget(
                "machine.actions", in: window, requiresEnabled: true)
            let clicked = ready && NativeUIAccessibility.click("machine.actions", in: window)
            let opened = await waitUntil(timeout: 5) {
                tracker.menu?.items.contains { $0.title == menuTitle && $0.isEnabled } == true
            }
            guard clicked, opened, let menu = tracker.menu,
                let index = menu.items.firstIndex(where: { $0.title == menuTitle && $0.isEnabled })
            else {
                let items = tracker.menu?.items.map { "\($0.title) enabled=\($0.isEnabled)" } ?? []
                try? "ready=\(ready) clicked=\(clicked) items=\(items)".write(
                    to: output.appendingPathComponent("privacy-menu-\(action.rawValue).txt"),
                    atomically: true, encoding: .utf8)
                return false
            }
            // Invoke the native menu item's action, just as accessibility does;
            // it must present the actual confirmation before dispatching RPCs.
            menu.cancelTrackingWithoutAnimation()
            menu.performActionForItem(at: index)
            let confirmation = await waitUntil(timeout: 5) {
                NativeUIAccessibility.find("machine.confirm-operation", in: window.attachedSheet ?? window) != nil
            }
            guard confirmation,
                NativeUIAccessibility.press("machine.confirm-operation", in: window.attachedSheet ?? window)
            else { return false }
            let accepted = await waitUntil(timeout: 10) {
                store.fleet.machineOperationMessage?.contains(
                    action == .privacySetup
                        ? "Privacy helper setup requested"
                        : (action == .privacyOn ? "Privacy mode is on" : "Privacy mode is off")) == true
            }
            let alert = await waitUntil(timeout: 5) {
                NativeUIAccessibility.find("machine.operation-ok", in: window.attachedSheet ?? window) != nil
            }
            guard accepted, alert,
                NativeUIAccessibility.press("machine.operation-ok", in: window.attachedSheet ?? window)
            else { return false }
            return await waitUntil(timeout: 5) {
                store.fleet.machineOperationMessage == nil && window.attachedSheet == nil
            }
        }

        private static func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await DieterTaskSleep.milliseconds(100)
            }
            return condition()
        }

        private static func capture(window: NSWindow, to destination: URL) -> Bool {
            guard let view = window.contentView,
                let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return false }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { return false }
            do {
                try data.write(to: destination, options: .atomic)
                return true
            } catch {
                return false
            }
        }

        private static func writeReport(_ results: [String: String], to output: URL) {
            NativeTestSupport.writeReport(results, to: output)
        }
    }
#endif
