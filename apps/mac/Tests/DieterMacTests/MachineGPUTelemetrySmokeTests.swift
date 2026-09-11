#if DEBUG
    import DieterAPI
    import Testing
    @testable import DieterMac

    @Suite struct MachineGPUTelemetrySmokeTests {
        @Test func virtualMacWithoutGPUPassthroughIsAnExplicitValidResult() {
            var information = Dieter_V1_MachineInformation()
            information.gpu.state = .noDevices
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information) == "passed: no GPU devices reported")
        }

        @Test func unavailableTelemetryMustExplainWhy() {
            var information = Dieter_V1_MachineInformation()
            information.gpu.state = .unavailable
            information.gpu.unavailableReason = "system_profiler is unavailable"
            #expect(
                MachineGPUTelemetrySmokeCheck.result(for: information)
                    == "passed: GPU telemetry unavailable (system_profiler is unavailable)")

            information.gpu.unavailableReason = " \n"
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information).hasPrefix("failed:"))
        }

        @Test(arguments: [Dieter_V1_GPUTelemetryState.partial, .available])
        func reportedDevicesRetainOptionalMetrics(state: Dieter_V1_GPUTelemetryState) {
            var information = Dieter_V1_MachineInformation()
            information.gpu.state = state
            information.gpu.devices = [Self.device()]
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information) == "passed")
            #expect(!information.gpu.devices[0].hasUtilizationPercent)

            information.gpu.devices[0].utilizationPercent = 0
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information) == "passed")
        }

        @Test func missingOrUnknownTelemetryStillFails() {
            var information = Dieter_V1_MachineInformation()
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information).hasPrefix("failed:"))
            information.gpu = Dieter_V1_GPUTelemetry()
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information).hasPrefix("failed:"))
            information.gpu.state = .UNRECOGNIZED(100)
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information).hasPrefix("failed:"))
        }

        @Test(arguments: [Dieter_V1_GPUTelemetryState.noDevices, .unavailable])
        func absenceStatesCannotContainDevices(state: Dieter_V1_GPUTelemetryState) {
            var information = Dieter_V1_MachineInformation()
            information.gpu.state = state
            information.gpu.unavailableReason = "GPU information is not available"
            information.gpu.devices = [Self.device()]
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information).hasPrefix("failed:"))
        }

        @Test(arguments: [Dieter_V1_GPUTelemetryState.partial, .available])
        func activeStatesRequireIdentifiableDevices(state: Dieter_V1_GPUTelemetryState) {
            var information = Dieter_V1_MachineInformation()
            information.gpu.state = state
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information).hasPrefix("failed:"))

            information.gpu.devices = [Self.device()]
            information.gpu.devices[0].id = ""
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information).hasPrefix("failed:"))

            information.gpu.devices = [Self.device()]
            information.gpu.devices[0].name = ""
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information).hasPrefix("failed:"))

            information.gpu.devices = [Self.device(), Self.device()]
            #expect(MachineGPUTelemetrySmokeCheck.result(for: information).hasPrefix("failed:"))
        }

        private static func device() -> Dieter_V1_GPUDevice {
            var device = Dieter_V1_GPUDevice()
            device.id = "gpu0"
            device.name = "Apple M4"
            device.vendor = .apple
            device.memoryKind = .unified
            return device
        }
    }
#endif
