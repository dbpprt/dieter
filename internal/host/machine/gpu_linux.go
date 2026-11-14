//go:build linux

package machine

import (
	"context"
	"errors"
	"os/exec"
)

type linuxGPUCollector struct {
	run boundedCommandRunner
}

func newPlatformGPUCollector() gpuCollector {
	return newCachedGPUCollector(&linuxGPUCollector{run: boundedCommandRunner{limit: 512 << 10}})
}

func (c *linuxGPUCollector) Collect(ctx context.Context, descriptors []ProcessDescriptor) GPUTelemetry {
	devices, amdPartial := collectAMDGPU("/sys/class/drm")
	usage := map[int32][]GPUProcessUsage{}
	partial := amdPartial
	path, pathErr := exec.LookPath("nvidia-smi")
	if pathErr == nil {
		raw, err := c.run.Run(ctx, path,
			"--query-gpu=uuid,pci.bus_id,name,driver_version,utilization.gpu,memory.total,memory.used,temperature.gpu,power.draw",
			"--format=csv,noheader,nounits")
		if err != nil {
			partial = true
		} else if nvidia, parseErr := parseNVIDIAGPUs(raw); parseErr != nil {
			partial = true
		} else {
			devices = append(devices, nvidia...)
			processRaw, processErr := c.run.Run(ctx, path,
				"--query-compute-apps=pid,gpu_uuid,used_gpu_memory", "--format=csv,noheader,nounits")
			if processErr != nil {
				partial = true
			} else if processUsage, counts, parseErr := parseNVIDIAProcesses(processRaw, descriptors); parseErr != nil {
				partial = true
			} else {
				usage = processUsage
				for index := range devices {
					if devices[index].Vendor == GPUVendorNVIDIA {
						count := counts[devices[index].ID]
						devices[index].ProcessCount = &count
					}
				}
			}
		}
	} else if !errors.Is(pathErr, exec.ErrNotFound) {
		partial = true
	}
	if len(devices) == 0 {
		if partial {
			return GPUTelemetry{State: GPUTelemetryUnavailable, UnavailableReason: "GPU drivers did not provide telemetry"}
		}
		return GPUTelemetry{State: GPUTelemetryNoDevices}
	}
	state := GPUTelemetryAvailable
	if partial {
		state = GPUTelemetryPartial
	}
	return GPUTelemetry{State: state, Devices: devices, ProcessUsage: usage}
}
