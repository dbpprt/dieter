//go:build darwin

package machine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type darwinGPUCollector struct {
	run        boundedCommandRunner
	mu         sync.Mutex
	devices    []GPUDevice
	discovered time.Time
}

func newPlatformGPUCollector() gpuCollector {
	return newCachedGPUCollector(&darwinGPUCollector{run: boundedCommandRunner{limit: 512 << 10}})
}

func (c *darwinGPUCollector) Collect(ctx context.Context, _ []ProcessDescriptor) GPUTelemetry {
	devices, err := c.staticDevices(ctx)
	if err != nil {
		return GPUTelemetry{State: GPUTelemetryUnavailable, UnavailableReason: err.Error()}
	}
	if len(devices) == 0 {
		return GPUTelemetry{State: GPUTelemetryNoDevices}
	}
	state := GPUTelemetryPartial
	if raw, sampleErr := c.run.Run(ctx, "/usr/sbin/ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"); sampleErr == nil {
		utilization := regexp.MustCompile(`"Device Utilization %"=([0-9]+(?:[.][0-9]+)?)`).FindAllStringSubmatch(string(raw), -1)
		memory := regexp.MustCompile(`"In use system memory"=([0-9]+)`).FindAllStringSubmatch(string(raw), -1)
		for index := range devices {
			if index < len(utilization) {
				devices[index].UtilizationPercent = optionalFloat(utilization[index][1], 1)
			}
			if index < len(memory) {
				devices[index].MemoryUsedBytes = optionalFileValueBytes(memory[index][1])
			}
		}
	}
	return GPUTelemetry{State: state, Devices: devices, ProcessUsage: map[int32][]GPUProcessUsage{}}
}

func (c *darwinGPUCollector) staticDevices(ctx context.Context) ([]GPUDevice, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.devices) > 0 && time.Since(c.discovered) < 5*time.Minute {
		return append([]GPUDevice(nil), c.devices...), nil
	}
	if _, err := os.Stat("/usr/sbin/system_profiler"); err != nil {
		return nil, errors.New("system_profiler is unavailable")
	}
	raw, err := c.run.Run(ctx, "/usr/sbin/system_profiler", "SPDisplaysDataType", "-json")
	if err != nil {
		return nil, fmt.Errorf("read macOS GPU information: %w", err)
	}
	devices, err := parseSystemProfilerGPUs(raw)
	if err != nil {
		return nil, err
	}
	c.devices, c.discovered = append([]GPUDevice(nil), devices...), time.Now()
	return devices, nil
}

func parseSystemProfilerGPUs(raw []byte) ([]GPUDevice, error) {
	var payload struct {
		Displays []map[string]any `json:"SPDisplaysDataType"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, fmt.Errorf("parse macOS GPU information: %w", err)
	}
	result := make([]GPUDevice, 0, len(payload.Displays))
	for index, value := range payload.Displays {
		name := firstString(value, "sppci_model", "_name")
		if name == "" {
			continue
		}
		vendorText := strings.ToLower(firstString(value, "spdisplays_vendor", "sppci_vendor"))
		vendor := GPUVendorUnknown
		switch {
		case strings.Contains(vendorText, "apple") || strings.HasPrefix(strings.ToLower(name), "apple"):
			vendor = GPUVendorApple
		case strings.Contains(vendorText, "nvidia") || strings.Contains(strings.ToLower(name), "nvidia"):
			vendor = GPUVendorNVIDIA
		case strings.Contains(vendorText, "amd") || strings.Contains(vendorText, "ati") || strings.Contains(strings.ToLower(name), "radeon"):
			vendor = GPUVendorAMD
		}
		kind := GPUMemoryDedicated
		if vendor == GPUVendorApple {
			kind = GPUMemoryUnified
		}
		id := fmt.Sprintf("mac-%s-%s-%d", vendor, normalizeGPUID(name), index)
		item := GPUDevice{ID: id, Vendor: vendor, Name: name, MemoryKind: kind}
		if text := firstString(value, "spdisplays_vram", "spdisplays_vram_shared"); text != "" {
			item.MemoryTotalBytes = parseHumanBytes(text)
		}
		result = append(result, item)
	}
	return result, nil
}

func firstString(value map[string]any, names ...string) string {
	for _, name := range names {
		if text, ok := value[name].(string); ok && strings.TrimSpace(text) != "" {
			return strings.TrimSpace(text)
		}
	}
	return ""
}

func parseHumanBytes(value string) *uint64 {
	fields := strings.Fields(strings.ReplaceAll(value, ",", "."))
	if len(fields) < 2 {
		return nil
	}
	amount, err := strconv.ParseFloat(fields[0], 64)
	if err != nil || amount < 0 {
		return nil
	}
	multiplier := float64(1)
	switch strings.ToUpper(fields[1]) {
	case "KB":
		multiplier = 1 << 10
	case "MB":
		multiplier = 1 << 20
	case "GB":
		multiplier = 1 << 30
	case "TB":
		multiplier = 1 << 40
	default:
		return nil
	}
	result := uint64(amount * multiplier)
	return &result
}

func normalizeGPUID(value string) string {
	value = strings.ToLower(value)
	return strings.Trim(strings.Map(func(character rune) rune {
		if character >= 'a' && character <= 'z' || character >= '0' && character <= '9' {
			return character
		}
		return '-'
	}, value), "-")
}

func optionalFileValueBytes(value string) *uint64 {
	parsed, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return nil
	}
	return &parsed
}
