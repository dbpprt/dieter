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
            machine: DieterEndpoint, expectedDaemonID: String?, fixtureEndpoint: String?
        ) -> Bool {
            guard let expectedDaemonID, !expectedDaemonID.isEmpty,
                let fixtureEndpoint, let gateway = DieterEndpoint.parse(fixtureEndpoint),
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
                writeReport(["connection": "failed: no live enrolled machine (\(store.phase.label))"], to: output)
                return
            }
            guard let machine = store.machines.first(where: \.online) else {
                writeReport(["connection": "failed: machine directory was empty"], to: output)
                return
            }

            let sectionBeforeOpening = store.section
            await store.fleet.openMachine(machine)
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
