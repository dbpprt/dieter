//go:build darwin

package machine

import (
	"context"
	"testing"
	"time"
)

func TestParseSystemProfilerAppleAndAMDGPUs(t *testing.T) {
	raw := []byte(`{"SPDisplaysDataType":[{"_name":"Apple M4","spdisplays_vendor":"sppci_vendor_Apple","sppci_model":"Apple M4"},{"_name":"AMD Radeon Pro 5500M","spdisplays_vendor":"sppci_vendor_AMD","spdisplays_vram":"8 GB"}]}`)
	devices, err := parseSystemProfilerGPUs(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 2 || devices[0].Vendor != GPUVendorApple || devices[0].MemoryKind != GPUMemoryUnified {
		t.Fatalf("devices=%#v", devices)
	}
	if devices[0].MemoryTotalBytes != nil {
		t.Fatalf("Apple unified memory must not be presented as dedicated VRAM: %#v", devices[0])
	}
	if devices[1].Vendor != GPUVendorAMD || devices[1].MemoryTotalBytes == nil || *devices[1].MemoryTotalBytes != 8*(1<<30) {
		t.Fatalf("AMD device=%#v", devices[1])
	}
}

func TestDarwinGPUCollectorReadsTheHostWithoutPrivileges(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	telemetry := newPlatformGPUCollector().Collect(ctx, nil)
	if telemetry.State == GPUTelemetryUnavailable || len(telemetry.Devices) == 0 {
		t.Fatalf("telemetry=%#v", telemetry)
	}
	if telemetry.Devices[0].ID == "" || telemetry.Devices[0].Name == "" {
		t.Fatalf("device=%#v", telemetry.Devices[0])
	}
}
