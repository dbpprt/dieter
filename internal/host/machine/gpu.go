package machine

import (
	"bytes"
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type GPUVendor string

const (
	GPUVendorUnknown GPUVendor = "unknown"
	GPUVendorApple   GPUVendor = "apple"
	GPUVendorNVIDIA  GPUVendor = "nvidia"
	GPUVendorAMD     GPUVendor = "amd"
)

type GPUMemoryKind string

const (
	GPUMemoryUnknown   GPUMemoryKind = "unknown"
	GPUMemoryUnified   GPUMemoryKind = "unified"
	GPUMemoryDedicated GPUMemoryKind = "dedicated"
)

type GPUTelemetryState string

const (
	GPUTelemetryUnavailable GPUTelemetryState = "unavailable"
	GPUTelemetryNoDevices   GPUTelemetryState = "no_devices"
	GPUTelemetryPartial     GPUTelemetryState = "partial"
	GPUTelemetryAvailable   GPUTelemetryState = "available"
)

type GPUProcessUsage struct {
	GPUID       string
	MemoryBytes *uint64
}

type GPUDevice struct {
	ID                 string
	Vendor             GPUVendor
	Name               string
	DriverVersion      string
	MemoryKind         GPUMemoryKind
	UtilizationPercent *float64
	MemoryTotalBytes   *uint64
	MemoryUsedBytes    *uint64
	TemperatureCelsius *float64
	PowerWatts         *float64
	ProcessCount       *uint32
}

type GPUTelemetry struct {
	State             GPUTelemetryState
	Devices           []GPUDevice
	UnavailableReason string
	ProcessUsage      map[int32][]GPUProcessUsage
}

type gpuCollector interface {
	Collect(context.Context, []ProcessDescriptor) GPUTelemetry
}

type cachedGPUCollector struct {
	mu       sync.Mutex
	delegate gpuCollector
	last     GPUTelemetry
	at       time.Time
}

func newCachedGPUCollector(delegate gpuCollector) gpuCollector {
	return &cachedGPUCollector{delegate: delegate}
}

func (c *cachedGPUCollector) Collect(ctx context.Context, descriptors []ProcessDescriptor) GPUTelemetry {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.at.IsZero() && time.Since(c.at) < time.Second {
		return cloneGPUTelemetry(c.last)
	}
	value := c.delegate.Collect(ctx, descriptors)
	sort.SliceStable(value.Devices, func(i, j int) bool { return value.Devices[i].ID < value.Devices[j].ID })
	c.last, c.at = cloneGPUTelemetry(value), time.Now()
	return value
}

func cloneGPUTelemetry(value GPUTelemetry) GPUTelemetry {
	result := value
	result.Devices = append([]GPUDevice(nil), value.Devices...)
	result.ProcessUsage = make(map[int32][]GPUProcessUsage, len(value.ProcessUsage))
	for pid, items := range value.ProcessUsage {
		result.ProcessUsage[pid] = append([]GPUProcessUsage(nil), items...)
	}
	return result
}

type boundedCommandRunner struct {
	limit int
}

func (r boundedCommandRunner) Run(ctx context.Context, path string, arguments ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, path, arguments...)
	stdout := &limitedBuffer{limit: r.limit}
	stderr := &limitedBuffer{limit: 16 << 10}
	command.Stdout, command.Stderr = stdout, stderr
	err := command.Run()
	if stdout.exceeded || stderr.exceeded {
		return nil, errors.New("GPU telemetry command output exceeded its limit")
	}
	if err != nil {
		message := strings.TrimSpace(stderr.String())
		if message != "" {
			return nil, fmt.Errorf("%w: %s", err, message)
		}
		return nil, err
	}
	return stdout.Bytes(), nil
}

type limitedBuffer struct {
	bytes.Buffer
	limit    int
	exceeded bool
}

func (b *limitedBuffer) Write(value []byte) (int, error) {
	length := len(value)
	remaining := b.limit - b.Len()
	if remaining <= 0 {
		b.exceeded = true
		return length, nil
	}
	if len(value) > remaining {
		_, _ = b.Buffer.Write(value[:remaining])
		b.exceeded = true
		return length, nil
	}
	_, _ = b.Buffer.Write(value)
	return length, nil
}

func parseNVIDIAGPUs(raw []byte) ([]GPUDevice, error) {
	reader := csv.NewReader(bytes.NewReader(raw))
	reader.TrimLeadingSpace = true
	reader.FieldsPerRecord = -1
	var result []GPUDevice
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("parse nvidia-smi CSV: %w", err)
		}
		if len(record) != 9 {
			return nil, fmt.Errorf("parse nvidia-smi CSV: got %d fields, want 9", len(record))
		}
		for index := range record {
			record[index] = strings.TrimSpace(record[index])
		}
		id := record[0]
		if unavailable(id) {
			id = record[1]
		}
		if unavailable(id) || id == "" {
			return nil, errors.New("parse nvidia-smi CSV: device has no stable identity")
		}
		result = append(result, GPUDevice{
			ID: id, Vendor: GPUVendorNVIDIA, Name: record[2], DriverVersion: record[3], MemoryKind: GPUMemoryDedicated,
			UtilizationPercent: optionalFloat(record[4], 1),
			MemoryTotalBytes:   optionalFloatBytes(record[5], 1<<20),
			MemoryUsedBytes:    optionalFloatBytes(record[6], 1<<20),
			TemperatureCelsius: optionalFloat(record[7], 1),
			PowerWatts:         optionalFloat(record[8], 1),
		})
	}
	return result, nil
}

func parseNVIDIAProcesses(raw []byte, descriptors []ProcessDescriptor) (map[int32][]GPUProcessUsage, map[string]uint32, error) {
	wanted := make(map[int32]bool, len(descriptors))
	for _, item := range descriptors {
		wanted[item.PID] = true
	}
	usage := map[int32][]GPUProcessUsage{}
	counts := map[string]uint32{}
	reader := csv.NewReader(bytes.NewReader(raw))
	reader.TrimLeadingSpace = true
	reader.FieldsPerRecord = -1
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			return usage, counts, nil
		}
		if err != nil || len(record) != 3 {
			return nil, nil, errors.New("parse nvidia-smi process CSV")
		}
		pid64, parseErr := strconv.ParseInt(strings.TrimSpace(record[0]), 10, 32)
		if parseErr != nil {
			continue
		}
		gpuID := strings.TrimSpace(record[1])
		counts[gpuID]++
		pid := int32(pid64)
		if wanted[pid] {
			usage[pid] = append(usage[pid], GPUProcessUsage{GPUID: gpuID, MemoryBytes: optionalFloatBytes(record[2], 1<<20)})
		}
	}
}

func collectAMDGPU(root string) ([]GPUDevice, bool) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, false
	}
	var result []GPUDevice
	partial := false
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), "card") || strings.Contains(entry.Name(), "-") {
			continue
		}
		deviceRoot := filepath.Join(root, entry.Name(), "device")
		if strings.ToLower(readTrimmed(filepath.Join(deviceRoot, "vendor"))) != "0x1002" {
			continue
		}
		id := amdStableID(deviceRoot, entry.Name())
		name := readTrimmed(filepath.Join(deviceRoot, "product_name"))
		if name == "" {
			name = "AMD GPU"
			if product := readTrimmed(filepath.Join(deviceRoot, "device")); product != "" {
				name += " " + product
			}
		}
		item := GPUDevice{ID: id, Vendor: GPUVendorAMD, Name: name, MemoryKind: GPUMemoryDedicated}
		item.UtilizationPercent = optionalFileFloat(filepath.Join(deviceRoot, "gpu_busy_percent"), 1)
		item.MemoryTotalBytes = optionalFileBytes(filepath.Join(deviceRoot, "mem_info_vram_total"), 1)
		item.MemoryUsedBytes = optionalFileBytes(filepath.Join(deviceRoot, "mem_info_vram_used"), 1)
		item.TemperatureCelsius, item.PowerWatts = amdHardwareMonitors(deviceRoot)
		if item.UtilizationPercent == nil || item.MemoryTotalBytes == nil || item.MemoryUsedBytes == nil {
			partial = true
		}
		result = append(result, item)
	}
	return result, partial
}

func amdStableID(deviceRoot, fallback string) string {
	if unique := readTrimmed(filepath.Join(deviceRoot, "unique_id")); unique != "" && unique != "0" {
		return "amd-" + unique
	}
	if target, err := filepath.EvalSymlinks(deviceRoot); err == nil {
		base := filepath.Base(target)
		if strings.Count(base, ":") >= 2 && strings.Contains(base, ".") {
			return "pci-" + base
		}
	}
	if uevent := readTrimmed(filepath.Join(deviceRoot, "uevent")); uevent != "" {
		for _, line := range strings.Split(uevent, "\n") {
			if value, ok := strings.CutPrefix(line, "PCI_SLOT_NAME="); ok && value != "" {
				return "pci-" + value
			}
		}
	}
	return "amd-" + fallback
}

func amdHardwareMonitors(deviceRoot string) (*float64, *float64) {
	directories, _ := filepath.Glob(filepath.Join(deviceRoot, "hwmon", "hwmon*"))
	for _, directory := range directories {
		temperature := optionalFileFloat(filepath.Join(directory, "temp1_input"), 1.0/1000)
		power := optionalFileFloat(filepath.Join(directory, "power1_average"), 1.0/1_000_000)
		if power == nil {
			power = optionalFileFloat(filepath.Join(directory, "power1_input"), 1.0/1_000_000)
		}
		if temperature != nil || power != nil {
			return temperature, power
		}
	}
	return nil, nil
}

func optionalFileFloat(path string, scale float64) *float64 {
	return optionalFloat(readTrimmed(path), scale)
}

func optionalFileBytes(path string, scale uint64) *uint64 {
	value := readTrimmed(path)
	if unavailable(value) {
		return nil
	}
	parsed, err := strconv.ParseUint(value, 10, 64)
	if err != nil || parsed > ^uint64(0)/scale {
		return nil
	}
	parsed *= scale
	return &parsed
}

func optionalFloatBytes(value string, scale uint64) *uint64 {
	if unavailable(value) {
		return nil
	}
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil || parsed < 0 || parsed > float64(^uint64(0)/scale) {
		return nil
	}
	result := uint64(parsed * float64(scale))
	return &result
}

func optionalFloat(value string, scale float64) *float64 {
	if unavailable(value) {
		return nil
	}
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil {
		return nil
	}
	parsed *= scale
	return &parsed
}

func unavailable(value string) bool {
	value = strings.TrimSpace(strings.ToLower(value))
	return value == "" || value == "n/a" || value == "[n/a]" || value == "not supported"
}

func readTrimmed(path string) string {
	value, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(value))
}
