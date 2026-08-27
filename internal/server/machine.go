package server

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/machine"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

type machineWorkerRecord struct {
	PID int32 `json:"pid"`
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
		processes = append(processes, &dieterv1.MachineProcess{
			Pid: item.PID, Kind: item.Kind, Name: item.Name, Detail: item.Detail,
			CpuUsagePercent: item.CPUPercent, MemoryBytes: item.MemoryBytes, StartedAt: item.StartedAt,
		})
	}
	supported := machine.SupportsOperations()
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
		SupportsRestart: supported, SupportsShutdown: supported,
		CpuCoreUsagePercent: append([]float64(nil), snapshot.CPUCorePercent...),
	}, nil
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

func (api *grpcAPI) PerformMachineOperation(_ context.Context, request *dieterv1.MachineOperationRequest) (*dieterv1.MachineOperationResponse, error) {
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
	if !machine.SupportsOperations() {
		return nil, status.Error(codes.FailedPrecondition, machine.ErrOperationUnsupported.Error())
	}

	go func() {
		timer := time.NewTimer(api.server.machineDelay)
		defer timer.Stop()
		<-timer.C
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := api.server.machineAction(ctx, operation); err != nil && !errors.Is(err, context.Canceled) {
			api.server.log.Error("machine operation failed", "operation", operation, "error", err)
		}
	}()
	api.server.log.Warn("machine operation accepted", "operation", operation)
	return &dieterv1.MachineOperationResponse{Accepted: true, Message: message}, nil
}
