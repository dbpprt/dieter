package server

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/buildinfo"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/machine"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

type machineWorkerRecord struct {
	PID int32 `json:"pid"`
}

type acceptedMachineOperation struct {
	action   dieterv1.MachineOperationAction
	response *dieterv1.MachineOperationResponse
}

func (api *grpcAPI) GetMachineInformation(ctx context.Context, _ *emptypb.Empty) (*dieterv1.MachineInformation, error) {
	descriptors := api.machineProcessDescriptors()
	snapshot := api.server.machine.Collect(ctx, descriptors)
	processes := make([]*dieterv1.MachineProcess, 0, len(snapshot.Processes))
	var activeAgents uint32
	for _, item := range snapshot.Processes {
		if item.Kind == "agent" {
			activeAgents++
		}
		process := &dieterv1.MachineProcess{
			Pid: item.PID, Kind: item.Kind, Name: item.Name, Detail: item.Detail,
			CpuUsagePercent: item.CPUPercent, MemoryBytes: item.MemoryBytes, StartedAt: item.StartedAt,
		}
		for _, usage := range item.GPUUsage {
			process.GpuUsage = append(process.GpuUsage, &dieterv1.MachineProcessGPU{GpuId: usage.GPUID, MemoryBytes: usage.MemoryBytes})
		}
		processes = append(processes, process)
	}
	capabilities := api.server.machineCapabilities(ctx)
	operationCapabilities := make([]*dieterv1.MachineOperationCapability, 0, len(capabilities))
	var supportsRestart, supportsShutdown bool
	for _, capability := range capabilities {
		action := protoMachineOperation(capability.Operation)
		operationCapabilities = append(operationCapabilities, &dieterv1.MachineOperationCapability{
			Action: action, Supported: capability.Supported, Authorized: capability.Authorized,
			UnavailableReason: capability.UnavailableReason,
		})
		available := capability.Supported && capability.Authorized
		if capability.Operation == machine.OperationRestart {
			supportsRestart = available
		}
		if capability.Operation == machine.OperationShutdown {
			supportsShutdown = available
		}
	}
	return &dieterv1.MachineInformation{
		Hostname: snapshot.Hostname, OsName: snapshot.OSName, OsVersion: snapshot.OSVersion,
		Architecture: snapshot.Architecture, HardwareModel: snapshot.HardwareModel, Processor: snapshot.Processor,
		UptimeSeconds: snapshot.UptimeSeconds, CollectedAt: snapshot.CollectedAt,
		CpuUsagePercent: snapshot.CPUPercent, LogicalCpuCount: snapshot.LogicalCPUs,
		Load_1: snapshot.Load1, Load_5: snapshot.Load5, Load_15: snapshot.Load15,
		MemoryTotalBytes: snapshot.MemoryTotal, MemoryUsedBytes: snapshot.MemoryUsed,
		MemoryCachedBytes: snapshot.MemoryCached, SwapUsedBytes: snapshot.SwapUsed,
		DiskTotalBytes: snapshot.DiskTotal, DiskFreeBytes: snapshot.DiskFree,
		NetworkReceiveBytesPerSecond: snapshot.NetworkReceive, NetworkSendBytesPerSecond: snapshot.NetworkSend,
		TemperatureCelsius: snapshot.Temperature, Processes: processes, ActiveAgentCount: activeAgents,
		SupportsRestart: supportsRestart, SupportsShutdown: supportsShutdown,
		CpuCoreUsagePercent: append([]float64(nil), snapshot.CPUCorePercent...),
		DaemonBuild: &dieterv1.BuildInformation{
			ReleaseVersion: buildinfo.ReleaseVersion, ApiVersion: APIVersion,
			SourceRevision: buildinfo.SourceRevision, BuiltAt: buildinfo.BuiltAt,
		},
		Gpu: protoGPUTelemetry(snapshot.GPU), OperationCapabilities: operationCapabilities,
	}, nil
}

func protoGPUTelemetry(value machine.GPUTelemetry) *dieterv1.GPUTelemetry {
	result := &dieterv1.GPUTelemetry{State: protoGPUState(value.State), UnavailableReason: value.UnavailableReason}
	for _, item := range value.Devices {
		result.Devices = append(result.Devices, &dieterv1.GPUDevice{
			Id: item.ID, Vendor: protoGPUVendor(item.Vendor), Name: item.Name, DriverVersion: item.DriverVersion,
			MemoryKind: protoGPUMemoryKind(item.MemoryKind), UtilizationPercent: item.UtilizationPercent,
			MemoryTotalBytes: item.MemoryTotalBytes, MemoryUsedBytes: item.MemoryUsedBytes,
			TemperatureCelsius: item.TemperatureCelsius, PowerWatts: item.PowerWatts, ProcessCount: item.ProcessCount,
		})
	}
	return result
}

func protoGPUState(value machine.GPUTelemetryState) dieterv1.GPUTelemetryState {
	switch value {
	case machine.GPUTelemetryUnavailable:
		return dieterv1.GPUTelemetryState_GPU_TELEMETRY_STATE_UNAVAILABLE
	case machine.GPUTelemetryNoDevices:
		return dieterv1.GPUTelemetryState_GPU_TELEMETRY_STATE_NO_DEVICES
	case machine.GPUTelemetryPartial:
		return dieterv1.GPUTelemetryState_GPU_TELEMETRY_STATE_PARTIAL
	case machine.GPUTelemetryAvailable:
		return dieterv1.GPUTelemetryState_GPU_TELEMETRY_STATE_AVAILABLE
	default:
		return dieterv1.GPUTelemetryState_GPU_TELEMETRY_STATE_UNSPECIFIED
	}
}

func protoGPUVendor(value machine.GPUVendor) dieterv1.GPUVendor {
	switch value {
	case machine.GPUVendorApple:
		return dieterv1.GPUVendor_GPU_VENDOR_APPLE
	case machine.GPUVendorNVIDIA:
		return dieterv1.GPUVendor_GPU_VENDOR_NVIDIA
	case machine.GPUVendorAMD:
		return dieterv1.GPUVendor_GPU_VENDOR_AMD
	default:
		return dieterv1.GPUVendor_GPU_VENDOR_UNSPECIFIED
	}
}

func protoGPUMemoryKind(value machine.GPUMemoryKind) dieterv1.GPUMemoryKind {
	switch value {
	case machine.GPUMemoryUnified:
		return dieterv1.GPUMemoryKind_GPU_MEMORY_KIND_UNIFIED
	case machine.GPUMemoryDedicated:
		return dieterv1.GPUMemoryKind_GPU_MEMORY_KIND_DEDICATED
	default:
		return dieterv1.GPUMemoryKind_GPU_MEMORY_KIND_UNSPECIFIED
	}
}

func protoMachineOperation(value machine.Operation) dieterv1.MachineOperationAction {
	if value == machine.OperationShutdown {
		return dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_SHUTDOWN
	}
	return dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_RESTART
}

func (api *grpcAPI) machineProcessDescriptors() []machine.ProcessDescriptor {
	descriptors := []machine.ProcessDescriptor{{
		PID: int32(os.Getpid()), Kind: "daemon", Name: "Dieter daemon", Detail: "machine data plane",
	}}
	sessionRoot := filepath.Join(api.server.store.RuntimeDir(), "sessions")
	projects, err := os.ReadDir(sessionRoot)
	if err != nil {
		return descriptors
	}
	for _, projectEntry := range projects {
		if !projectEntry.IsDir() {
			continue
		}
		entries, readErr := os.ReadDir(filepath.Join(sessionRoot, projectEntry.Name()))
		if readErr != nil {
			continue
		}
		for _, entry := range entries {
			name := entry.Name()
			if entry.IsDir() || !strings.HasPrefix(name, ".dieter-worker-") || !strings.HasSuffix(name, ".pid") {
				continue
			}
			raw, readErr := os.ReadFile(filepath.Join(sessionRoot, projectEntry.Name(), name))
			var worker machineWorkerRecord
			if readErr != nil || json.Unmarshal(raw, &worker) != nil || worker.PID <= 0 {
				continue
			}
			cardID := strings.TrimSuffix(strings.TrimPrefix(name, ".dieter-worker-"), ".pid")
			card, cardErr := api.server.store.ResolveCard(cardID)
			if cardErr != nil {
				continue
			}
			provider := strings.TrimSpace(card.Provider)
			if provider == "" {
				provider = "agent"
			}
			detail := projectEntry.Name()
			if project, projectErr := api.server.store.ResolveProjectIncludingArchived(card.ProjectID); projectErr == nil {
				detail = project.Name
			}
			if model := strings.TrimSpace(card.Model); model != "" {
				detail += " · " + model
			}
			descriptors = append(descriptors, machine.ProcessDescriptor{
				PID: worker.PID, Kind: "agent", Name: provider + " · " + card.Title, Detail: detail,
			})
		}
	}
	return descriptors
}

func (api *grpcAPI) PerformMachineOperation(ctx context.Context, request *dieterv1.MachineOperationRequest) (*dieterv1.MachineOperationResponse, error) {
	var operation machine.Operation
	var confirmation, message string
	switch request.GetAction() {
	case dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_RESTART:
		operation, confirmation, message = machine.OperationRestart, "RESTART", "Restarting the machine."
	case dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_SHUTDOWN:
		operation, confirmation, message = machine.OperationShutdown, "SHUT DOWN", "Shutting down the machine."
	default:
		return nil, status.Error(codes.InvalidArgument, "select restart or shutdown")
	}
	if request.GetConfirmation() != confirmation {
		return nil, status.Errorf(codes.InvalidArgument, "confirmation must be exactly %q", confirmation)
	}
	capability := machine.OperationCapability{Operation: operation, UnavailableReason: machine.ErrOperationUnsupported.Error()}
	for _, candidate := range api.server.machineCapabilities(ctx) {
		if candidate.Operation == operation {
			capability = candidate
			break
		}
	}
	if !capability.Supported {
		reason := capability.UnavailableReason
		if reason == "" {
			reason = machine.ErrOperationUnsupported.Error()
		}
		return nil, status.Error(codes.FailedPrecondition, reason)
	}
	if !capability.Authorized {
		reason := capability.UnavailableReason
		if reason == "" {
			reason = "machine operation is not authorized"
		}
		return nil, status.Error(codes.PermissionDenied, reason)
	}

	key := strings.TrimSpace(request.GetIdempotencyKey())
	if len(key) > 128 || strings.ContainsAny(key, "\r\n\x00") {
		return nil, status.Error(codes.InvalidArgument, "idempotency_key must be at most 128 printable characters")
	}
	if key == "" {
		key = randomMachineOperationID()
	}
	api.server.machineOperationMu.Lock()
	if existing, ok := api.server.machineOperations[key]; ok {
		api.server.machineOperationMu.Unlock()
		if existing.action != request.GetAction() {
			return nil, status.Error(codes.AlreadyExists, "idempotency_key was already used for a different machine operation")
		}
		return proto.Clone(existing.response).(*dieterv1.MachineOperationResponse), nil
	}
	if api.server.pendingMachineOperation != "" {
		api.server.machineOperationMu.Unlock()
		return nil, status.Error(codes.FailedPrecondition, "another machine operation is already pending")
	}
	scheduledAt := time.Now().UTC().Add(api.server.machineDelay)
	response := &dieterv1.MachineOperationResponse{Accepted: true, Message: message, OperationId: key, ScheduledAt: scheduledAt.Format(time.RFC3339Nano)}
	api.server.machineOperations[key] = acceptedMachineOperation{action: request.GetAction(), response: response}
	api.server.machineOperationOrder = append(api.server.machineOperationOrder, key)
	api.server.pendingMachineOperation = key
	for len(api.server.machineOperationOrder) > 32 {
		oldest := api.server.machineOperationOrder[0]
		api.server.machineOperationOrder = api.server.machineOperationOrder[1:]
		if oldest != api.server.pendingMachineOperation {
			delete(api.server.machineOperations, oldest)
		}
	}
	api.server.machineOperationMu.Unlock()

	go func() {
		timer := time.NewTimer(api.server.machineDelay)
		defer timer.Stop()
		<-timer.C
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := api.server.machineAction(ctx, operation); err != nil && !errors.Is(err, context.Canceled) {
			api.server.log.Error("machine operation failed", "operation", operation, "error", err)
		}
		api.server.machineOperationMu.Lock()
		if api.server.pendingMachineOperation == key {
			api.server.pendingMachineOperation = ""
		}
		api.server.machineOperationMu.Unlock()
	}()
	api.server.log.Warn("machine operation accepted", "operation", operation, "operation_id", key, "scheduled_at", scheduledAt)
	return proto.Clone(response).(*dieterv1.MachineOperationResponse), nil
}

func randomMachineOperationID() string {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return fmt.Sprintf("power-%d", time.Now().UnixNano())
	}
	return fmt.Sprintf("power-%x", value)
}
