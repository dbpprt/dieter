import DieterAPI
import Testing
@testable import DieterMacKit

/// Machine telemetry as the machine popover shows it.
struct MachineTelemetryTests {
    @Test func gpuTelemetryKeepsUnavailableValuesDistinctFromRealZeroes() {
        var gpu = Dieter_V1_GPUDevice()
        gpu.id = "gpu0"
        gpu.name = "Apple M4"
        gpu.vendor = .apple
        gpu.memoryKind = .unified
        #expect(!gpu.hasUtilizationPercent)
        #expect(!gpu.hasMemoryTotalBytes)

        gpu.utilizationPercent = 0
        gpu.memoryUsedBytes = 0
        #expect(gpu.hasUtilizationPercent)
        #expect(gpu.hasMemoryUsedBytes)
        #expect(gpu.utilizationPercent == 0)
    }
}
