//go:build !darwin && !linux

package machine

import "context"

type unsupportedGPUCollector struct{}

func newPlatformGPUCollector() gpuCollector { return unsupportedGPUCollector{} }

func (unsupportedGPUCollector) Collect(context.Context, []ProcessDescriptor) GPUTelemetry {
	return GPUTelemetry{State: GPUTelemetryUnavailable, UnavailableReason: "GPU telemetry is not supported on this operating system"}
}
