package server

import (
	"context"
	"io"
	"log/slog"
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

func TestMachineOperationSchedulesTheValidatedHostAction(t *testing.T) {
	if !machine.SupportsOperations() {
		t.Skip("host operations are not available on this platform")
	}
	application := New(store.New(t.TempDir()), slog.New(slog.NewTextHandler(io.Discard, nil)))
	application.machineDelay = 0
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
