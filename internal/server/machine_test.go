package server

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/machine"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestMachineInformationIncludesHostAndDaemonProcess(t *testing.T) {
	application := New(store.New(t.TempDir()), slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	information, err := (&grpcAPI{server: application}).GetMachineInformation(ctx, &emptypb.Empty{})
	if err != nil {
		t.Fatal(err)
	}
	if information.GetHostname() == "" || information.GetOsName() == "" || information.GetLogicalCpuCount() == 0 {
		t.Fatalf("incomplete host identity: %#v", information)
	}
	if information.GetMemoryTotalBytes() == 0 || information.GetDiskTotalBytes() == 0 || information.GetCollectedAt() == "" {
		t.Fatalf("incomplete host telemetry: %#v", information)
	}
	if len(information.GetProcesses()) != 1 || information.GetProcesses()[0].GetKind() != "daemon" {
		t.Fatalf("Dieter process projection=%#v", information.GetProcesses())
	}
	foundUpdate := false
	for _, capability := range information.GetOperationCapabilities() {
		if capability.GetAction() == dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_UPDATE_DAEMON {
			foundUpdate = true
			if capability.GetSupported() || capability.GetUnavailableReason() == "" {
				t.Fatalf("unexpected update capability for isolated non-Homebrew daemon: %#v", capability)
			}
		}
	}
	if !foundUpdate {
		t.Fatal("machine information omitted daemon update capability")
	}
}

func TestMachineOperationRequiresExactConfirmationBeforeScheduling(t *testing.T) {
	application := New(store.New(t.TempDir()), slog.New(slog.NewTextHandler(io.Discard, nil)))
	api := &grpcAPI{server: application}
	_, err := api.PerformMachineOperation(context.Background(), &dieterv1.MachineOperationRequest{
		Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_RESTART, Confirmation: "restart",
	})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("confirmation error=%v", err)
	}
}

func TestDaemonUpdateRequiresExactConfirmation(t *testing.T) {
	application := New(store.New(t.TempDir()), slog.New(slog.NewTextHandler(io.Discard, nil)))
	application.machineCapabilities = testMachineOperationCapabilities
	_, err := (&grpcAPI{server: application}).PerformMachineOperation(context.Background(), &dieterv1.MachineOperationRequest{
		Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_UPDATE_DAEMON, Confirmation: "yes",
	})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("confirmation error=%v", err)
	}
}

func TestDaemonUpdateRejectsAnUnsupportedInstallation(t *testing.T) {
	application := New(store.New(t.TempDir()), slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, err := (&grpcAPI{server: application}).PerformMachineOperation(context.Background(), &dieterv1.MachineOperationRequest{
		Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_UPDATE_DAEMON, Confirmation: "UPDATE",
	})
	if status.Code(err) != codes.FailedPrecondition || !strings.Contains(err.Error(), "Homebrew") {
		t.Fatalf("unsupported update error=%v", err)
	}
}

func TestDaemonUpdateSchedulesValidatedUpdater(t *testing.T) {
	application := New(store.New(t.TempDir()), slog.New(slog.NewTextHandler(io.Discard, nil)))
	application.machineDelay = 0
	application.machineCapabilities = testMachineOperationCapabilities
	called := make(chan machine.Operation, 1)
	application.machineAction = func(_ context.Context, operation machine.Operation) error {
		called <- operation
		return nil
	}
	response, err := (&grpcAPI{server: application}).PerformMachineOperation(context.Background(), &dieterv1.MachineOperationRequest{
		Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_UPDATE_DAEMON, Confirmation: "UPDATE", IdempotencyKey: "update-once",
	})
	if err != nil || !response.GetAccepted() || !strings.Contains(response.GetMessage(), "reconnect") {
		t.Fatalf("response=%#v err=%v", response, err)
	}
	select {
	case operation := <-called:
		if operation != machine.OperationUpdate {
			t.Fatalf("operation=%q", operation)
		}
	case <-time.After(time.Second):
		t.Fatal("validated daemon update was not scheduled")
	}
}

func TestMachineOperationSchedulesTheValidatedHostAction(t *testing.T) {
	application := New(store.New(t.TempDir()), slog.New(slog.NewTextHandler(io.Discard, nil)))
	application.machineDelay = 0
	application.machineCapabilities = testMachineOperationCapabilities
	called := make(chan machine.Operation, 1)
	application.machineAction = func(_ context.Context, operation machine.Operation) error {
		called <- operation
		return nil
	}
	response, err := (&grpcAPI{server: application}).PerformMachineOperation(context.Background(), &dieterv1.MachineOperationRequest{
		Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_RESTART, Confirmation: "RESTART",
	})
	if err != nil || !response.GetAccepted() {
		t.Fatalf("response=%#v err=%v", response, err)
	}
	select {
	case operation := <-called:
		if operation != machine.OperationRestart {
			t.Fatalf("operation=%q", operation)
		}
	case <-time.After(time.Second):
		t.Fatal("validated machine operation was not scheduled")
	}
}

func TestMachineOperationIsIdempotentAndRejectsKeyReuse(t *testing.T) {
	application := New(store.New(t.TempDir()), slog.New(slog.NewTextHandler(io.Discard, nil)))
	application.machineDelay = time.Hour
	application.machineCapabilities = testMachineOperationCapabilities
	api := &grpcAPI{server: application}
	request := &dieterv1.MachineOperationRequest{Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_RESTART, Confirmation: "RESTART", IdempotencyKey: "same-request"}
	first, err := api.PerformMachineOperation(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := api.PerformMachineOperation(context.Background(), request)
	if err != nil || second.GetOperationId() != first.GetOperationId() || second.GetScheduledAt() != first.GetScheduledAt() {
		t.Fatalf("first=%#v second=%#v err=%v", first, second, err)
	}
	_, err = api.PerformMachineOperation(context.Background(), &dieterv1.MachineOperationRequest{Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_SHUTDOWN, Confirmation: "SHUT DOWN", IdempotencyKey: "same-request"})
	if status.Code(err) != codes.AlreadyExists {
		t.Fatalf("key reuse error=%v", err)
	}
}

func testMachineOperationCapabilities(context.Context) []machine.OperationCapability {
	return []machine.OperationCapability{
		{Operation: machine.OperationRestart, Supported: true, Authorized: true},
		{Operation: machine.OperationShutdown, Supported: true, Authorized: true},
		{Operation: machine.OperationUpdate, Supported: true, Authorized: true},
	}
}
