package machine

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseNVIDIAGPUsAndOwnedProcesses(t *testing.T) {
	devices, err := parseNVIDIAGPUs([]byte("GPU-one, 00000000:01:00.0, NVIDIA RTX 4090, 580.10, 74, 24564, 8192, 63, 311.5\nGPU-two, 00000000:02:00.0, NVIDIA A100, 580.10, N/A, 40960, 1024, N/A, N/A\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 2 || devices[0].ID != "GPU-one" || devices[0].Vendor != GPUVendorNVIDIA {
		t.Fatalf("devices=%#v", devices)
	}
	if devices[0].UtilizationPercent == nil || *devices[0].UtilizationPercent != 74 || devices[0].MemoryUsedBytes == nil || *devices[0].MemoryUsedBytes != 8192*(1<<20) {
		t.Fatalf("first device metrics=%#v", devices[0])
	}
	if devices[1].UtilizationPercent != nil || devices[1].TemperatureCelsius != nil || devices[1].PowerWatts != nil {
		t.Fatalf("N/A values must remain absent: %#v", devices[1])
	}
	usage, counts, err := parseNVIDIAProcesses([]byte("42, GPU-one, 512\n99, GPU-two, N/A\n"), []ProcessDescriptor{{PID: 42}})
	if err != nil {
		t.Fatal(err)
	}
	if counts["GPU-one"] != 1 || counts["GPU-two"] != 1 || len(usage[42]) != 1 || len(usage[99]) != 0 {
		t.Fatalf("usage=%#v counts=%#v", usage, counts)
	}
}

func TestCollectAMDGPUFromDocumentedSysfsFiles(t *testing.T) {
	root := t.TempDir()
	device := filepath.Join(root, "card0", "device")
	hwmon := filepath.Join(device, "hwmon", "hwmon0")
	if err := os.MkdirAll(hwmon, 0o755); err != nil {
		t.Fatal(err)
	}
	values := map[string]string{
		filepath.Join(device, "vendor"):              "0x1002\n",
		filepath.Join(device, "device"):              "0x744c\n",
		filepath.Join(device, "product_name"):        "AMD Radeon PRO W7900\n",
		filepath.Join(device, "uevent"):              "PCI_SLOT_NAME=0000:41:00.0\n",
		filepath.Join(device, "gpu_busy_percent"):    "37\n",
		filepath.Join(device, "mem_info_vram_total"): "51539607552\n",
		filepath.Join(device, "mem_info_vram_used"):  "1073741824\n",
		filepath.Join(hwmon, "temp1_input"):          "62500\n",
		filepath.Join(hwmon, "power1_average"):       "185000000\n",
	}
	for path, value := range values {
		if err := os.WriteFile(path, []byte(value), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	devices, partial := collectAMDGPU(root)
	if partial || len(devices) != 1 {
		t.Fatalf("devices=%#v partial=%v", devices, partial)
	}
	deviceValue := devices[0]
	if deviceValue.ID != "pci-0000:41:00.0" || deviceValue.Name != "AMD Radeon PRO W7900" || deviceValue.UtilizationPercent == nil || *deviceValue.UtilizationPercent != 37 {
		t.Fatalf("device=%#v", deviceValue)
	}
	if deviceValue.TemperatureCelsius == nil || *deviceValue.TemperatureCelsius != 62.5 || deviceValue.PowerWatts == nil || *deviceValue.PowerWatts != 185 {
		t.Fatalf("sensor metrics=%#v", deviceValue)
	}
}

func TestCollectAMDGPUDoesNotReportOtherDRMDevices(t *testing.T) {
	root := t.TempDir()
	device := filepath.Join(root, "card0", "device")
	if err := os.MkdirAll(device, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(device, "vendor"), []byte("0x8086\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	devices, partial := collectAMDGPU(root)
	if partial || len(devices) != 0 {
		t.Fatalf("devices=%#v partial=%v", devices, partial)
	}
}
