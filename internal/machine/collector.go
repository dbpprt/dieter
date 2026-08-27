package machine

import (
	"context"
	"runtime"
	"sort"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/load"
	"github.com/shirou/gopsutil/v4/mem"
	gopsnet "github.com/shirou/gopsutil/v4/net"
	"github.com/shirou/gopsutil/v4/process"
	"github.com/shirou/gopsutil/v4/sensors"
)

// ProcessDescriptor supplies Dieter-owned context for a process without making
// the platform telemetry layer aware of projects, cards, or central storage.
type ProcessDescriptor struct {
	PID    int32
	Kind   string
	Name   string
	Detail string
}

type Process struct {
	PID         int64
	Kind        string
	Name        string
	Detail      string
	CPUPercent  float64
	MemoryBytes uint64
	StartedAt   string
}

type Snapshot struct {
	Hostname       string
	OSName         string
	OSVersion      string
	Architecture   string
	HardwareModel  string
	Processor      string
	UptimeSeconds  uint64
	CollectedAt    string
	CPUPercent     float64
	CPUCorePercent []float64
	LogicalCPUs    uint32
	Load1          float64
	Load5          float64
	Load15         float64
	MemoryTotal    uint64
	MemoryUsed     uint64
	MemoryCached   uint64
	SwapUsed       uint64
	DiskTotal      uint64
	DiskFree       uint64
	NetworkReceive float64
	NetworkSend    float64
	Temperature    float64
	Processes      []Process
}

type networkSample struct {
	received uint64
	sent     uint64
	at       time.Time
}

// Collector keeps only ephemeral counters needed to turn cumulative process
// and network values into rates. No telemetry is persisted.
type Collector struct {
	root string

	mu          sync.Mutex
	static      Snapshot
	staticReady bool
	lastNetwork networkSample
	processes   map[int32]*process.Process
}

func NewCollector(root string) *Collector {
	return &Collector{root: root, processes: map[int32]*process.Process{}}
}

func (c *Collector) Collect(ctx context.Context, descriptors []ProcessDescriptor) Snapshot {
	snapshot := c.staticInformation(ctx)
	snapshot.CollectedAt = time.Now().UTC().Format(time.RFC3339Nano)

	if values, err := cpu.PercentWithContext(ctx, 150*time.Millisecond, true); err == nil && len(values) > 0 {
		var total float64
		for _, value := range values {
			value = clampPercent(value)
			snapshot.CPUCorePercent = append(snapshot.CPUCorePercent, value)
			total += value
		}
		snapshot.CPUPercent = total / float64(len(values))
	}
	if avg, err := load.AvgWithContext(ctx); err == nil {
		snapshot.Load1, snapshot.Load5, snapshot.Load15 = avg.Load1, avg.Load5, avg.Load15
	}
	if memory, err := mem.VirtualMemoryWithContext(ctx); err == nil {
		snapshot.MemoryTotal = memory.Total
		snapshot.MemoryUsed = memory.Used
		snapshot.MemoryCached = memory.Cached + memory.Inactive
	}
	if swap, err := mem.SwapMemoryWithContext(ctx); err == nil {
		snapshot.SwapUsed = swap.Used
	}
	if usage, err := disk.UsageWithContext(ctx, c.root); err == nil {
		snapshot.DiskTotal, snapshot.DiskFree = usage.Total, usage.Free
	}
	if counters, err := gopsnet.IOCountersWithContext(ctx, false); err == nil && len(counters) > 0 {
		snapshot.NetworkReceive, snapshot.NetworkSend = c.networkRates(counters[0].BytesRecv, counters[0].BytesSent, time.Now())
	}
	if temperatures, err := sensors.TemperaturesWithContext(ctx); err == nil {
		var total float64
		var count int
		for _, sensor := range temperatures {
			if sensor.Temperature > 0 && sensor.Temperature < 150 {
				total += sensor.Temperature
				count++
			}
		}
		if count > 0 {
			snapshot.Temperature = total / float64(count)
		}
	}
	snapshot.Processes = c.processInformation(ctx, descriptors)
	return snapshot
}

func (c *Collector) staticInformation(ctx context.Context) Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.staticReady {
		return c.static
	}
	value := Snapshot{OSName: operatingSystemName(runtime.GOOS), Architecture: runtime.GOARCH}
	if info, err := host.InfoWithContext(ctx); err == nil {
		value.Hostname = info.Hostname
		value.OSVersion = info.PlatformVersion
		value.Architecture = info.KernelArch
		value.UptimeSeconds = info.Uptime
	}
	if count, err := cpu.CountsWithContext(ctx, true); err == nil && count > 0 {
		value.LogicalCPUs = uint32(count)
	} else {
		value.LogicalCPUs = uint32(runtime.NumCPU())
	}
	if details, err := cpu.InfoWithContext(ctx); err == nil && len(details) > 0 {
		value.Processor = details[0].ModelName
	}
	value.HardwareModel, value.Processor = hardwareDetails(value.Processor)
	c.static, c.staticReady = value, true
	return c.static
}

func (c *Collector) networkRates(received, sent uint64, now time.Time) (float64, float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	previous := c.lastNetwork
	c.lastNetwork = networkSample{received: received, sent: sent, at: now}
	seconds := now.Sub(previous.at).Seconds()
	if previous.at.IsZero() || seconds <= 0 || received < previous.received || sent < previous.sent {
		return 0, 0
	}
	return float64(received-previous.received) / seconds, float64(sent-previous.sent) / seconds
}

func (c *Collector) processInformation(ctx context.Context, descriptors []ProcessDescriptor) []Process {
	c.mu.Lock()
	defer c.mu.Unlock()
	result := make([]Process, 0, len(descriptors))
	live := make(map[int32]bool, len(descriptors))
	for _, descriptor := range descriptors {
		if descriptor.PID <= 0 || live[descriptor.PID] {
			continue
		}
		live[descriptor.PID] = true
		item := Process{PID: int64(descriptor.PID), Kind: descriptor.Kind, Name: descriptor.Name, Detail: descriptor.Detail}
		tracked := c.processes[descriptor.PID]
		if tracked == nil {
			tracked, _ = process.NewProcess(descriptor.PID)
			if tracked != nil {
				c.processes[descriptor.PID] = tracked
			}
		}
		if tracked != nil {
			if percent, err := tracked.PercentWithContext(ctx, 0); err == nil && percent > 0 {
				item.CPUPercent = percent
			}
			if memory, err := tracked.MemoryInfoWithContext(ctx); err == nil {
				item.MemoryBytes = memory.RSS
			}
			if milliseconds, err := tracked.CreateTimeWithContext(ctx); err == nil && milliseconds > 0 {
				item.StartedAt = time.UnixMilli(milliseconds).UTC().Format(time.RFC3339Nano)
			}
		}
		result = append(result, item)
	}
	for pid := range c.processes {
		if !live[pid] {
			delete(c.processes, pid)
		}
	}
	sort.SliceStable(result, func(i, j int) bool {
		if result[i].Kind != result[j].Kind {
			return result[i].Kind == "agent"
		}
		if result[i].CPUPercent != result[j].CPUPercent {
			return result[i].CPUPercent > result[j].CPUPercent
		}
		return result[i].PID < result[j].PID
	})
	return result
}

func clampPercent(value float64) float64 {
	if value < 0 {
		return 0
	}
	if value > 100 {
		return 100
	}
	return value
}

func operatingSystemName(value string) string {
	switch value {
	case "darwin":
		return "macOS"
	case "windows":
		return "Windows"
	case "linux":
		return "Linux"
	default:
		return value
	}
}
