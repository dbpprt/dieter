package api

import (
	"context"
	"io"
	"log/slog"
	"sync"
	"testing"

	"connectrpc.com/connect"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/types/known/emptypb"
)

// recordingTrust is a DeviceTrust that records which operations ran.
type recordingTrust struct {
	mu    sync.Mutex
	calls []string
}

func (r *recordingTrust) record(name string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, name)
}

func (r *recordingTrust) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.calls)
}

func (r *recordingTrust) Status() *dieterv1.TrustStatus {
	return &dieterv1.TrustStatus{State: dieterv1.TrustState_TRUST_STATE_TRUSTED, HeadSequence: 1}
}
func (r *recordingTrust) Entries(from uint64) *gatewayv1.DeviceRoster {
	return &gatewayv1.DeviceRoster{Length: 2, HeadSequence: 1, Entries: []*gatewayv1.DeviceRosterEntry{{Sequence: from}}}
}
func (r *recordingTrust) Sync(context.Context, []*gatewayv1.DeviceRosterEntry) (*dieterv1.TrustStatus, error) {
	r.record("sync")
	return r.Status(), nil
}
func (r *recordingTrust) Initialize(context.Context, bool) (*dieterv1.TrustStatus, string, error) {
	r.record("initialize")
	return r.Status(), "DRK1-TEST", nil
}
func (r *recordingTrust) ListRequests(context.Context) ([]*dieterv1.PairingRequestInfo, error) {
	return []*dieterv1.PairingRequestInfo{{Name: "Pixel"}}, nil
}
func (r *recordingTrust) Approve(context.Context, string) (*dieterv1.TrustStatus, error) {
	r.record("approve")
	return r.Status(), nil
}
func (r *recordingTrust) Revoke(context.Context, string) (*dieterv1.TrustStatus, error) {
	r.record("revoke")
	return r.Status(), nil
}
func (r *recordingTrust) Recover(context.Context, string) (*dieterv1.TrustStatus, error) {
	r.record("recover")
	return r.Status(), nil
}

func trustTestClient(t *testing.T, trust DeviceTrust) dieterclient.ConnectClient {
	t.Helper()
	data := testkit.Store(t)
	application := NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), Options{Runner: newFakeRunner(), Catalog: testkit.MockCatalog(), Trust: trust})
	server := testkit.HTTPServer(application.Handler())
	t.Cleanup(server.Close)
	return dieterclient.NewConnect(localHTTPClient(server.Client(), data.Root), server.URL)
}

func TestTrustServiceReportsAnUnenrolledMachine(t *testing.T) {
	t.Parallel()
	client := trustTestClient(t, nil)
	value, err := client.GetTrustStatus(t.Context(), &emptypb.Empty{})
	if err != nil || value.GetState() != dieterv1.TrustState_TRUST_STATE_NOT_ENROLLED {
		t.Fatalf("status=%v err=%v", value, err)
	}
	if roster, err := client.GetDeviceRoster(t.Context(), &gatewayv1.GetDeviceRosterRequest{}); err != nil || len(roster.GetEntries()) != 0 {
		t.Fatalf("roster=%v err=%v", roster, err)
	}
	_, err = client.ApproveDevice(t.Context(), &dieterv1.ApproveDeviceRequest{Code: "ABCD"})
	wantCode(t, err, connect.CodeFailedPrecondition, "approve without enrollment")
	_, err = client.InitializeDeviceRoster(t.Context(), &dieterv1.InitializeDeviceRosterRequest{})
	wantCode(t, err, connect.CodeFailedPrecondition, "initialize without enrollment")
}

func TestTrustServiceGuardsAgentsAndRemoteCallers(t *testing.T) {
	t.Parallel()
	trust := &recordingTrust{}
	client := trustTestClient(t, trust)
	ctx := t.Context()
	agent := withHeaders(ctx, map[string]string{turnTokenMetadata: "turn"})
	remote := withHeaders(ctx, map[string]string{operatorSubjectMetadata: "github:42", deviceIDMetadata: "dv_remote"})

	// Reads work for every caller.
	for _, caller := range []context.Context{ctx, agent, remote} {
		if value, err := client.GetTrustStatus(caller, &emptypb.Empty{}); err != nil || value.GetState() != dieterv1.TrustState_TRUST_STATE_TRUSTED {
			t.Fatalf("status=%v err=%v", value, err)
		}
		if value, err := client.GetDeviceRoster(caller, &gatewayv1.GetDeviceRosterRequest{FromSequence: 1}); err != nil || value.GetEntries()[0].GetSequence() != 1 {
			t.Fatalf("roster=%v err=%v", value, err)
		}
		if value, err := client.ListPairingRequests(caller, &emptypb.Empty{}); err != nil || len(value.GetRequests()) != 1 {
			t.Fatalf("requests=%v err=%v", value, err)
		}
	}
	// Agents never change device trust.
	mutations := map[string]func(context.Context) error{
		"sync": func(ctx context.Context) error {
			_, err := client.SyncDeviceRoster(ctx, &dieterv1.SyncDeviceRosterRequest{})
			return err
		},
		"initialize": func(ctx context.Context) error {
			_, err := client.InitializeDeviceRoster(ctx, &dieterv1.InitializeDeviceRosterRequest{})
			return err
		},
		"approve": func(ctx context.Context) error {
			_, err := client.ApproveDevice(ctx, &dieterv1.ApproveDeviceRequest{Code: "ABCD-EFGH-JKMN-PQRS"})
			return err
		},
		"revoke": func(ctx context.Context) error {
			_, err := client.RevokeDevice(ctx, &dieterv1.RevokeDeviceRequest{DeviceId: "dv_other"})
			return err
		},
		"recover": func(ctx context.Context) error {
			_, err := client.RecoverDeviceTrust(ctx, &dieterv1.RecoverDeviceTrustRequest{RecoveryKey: "DRK1-TEST"})
			return err
		},
	}
	for name, mutate := range mutations {
		wantCode(t, mutate(agent), connect.CodePermissionDenied, "agent "+name)
	}
	if trust.count() != 0 {
		t.Fatalf("an agent changed device trust: %v", trust.calls)
	}
	// Starting and recovering a roster runs only on the machine itself.
	for _, name := range []string{"initialize", "recover"} {
		wantCode(t, mutations[name](remote), connect.CodePermissionDenied, "remote "+name)
	}
	if trust.count() != 0 {
		t.Fatalf("a remote device started or recovered trust: %v", trust.calls)
	}
	for _, name := range []string{"sync", "approve", "revoke"} {
		if err := mutations[name](remote); err != nil {
			t.Fatalf("remote %s: %v", name, err)
		}
	}
	for name, mutate := range mutations {
		if err := mutate(ctx); err != nil {
			t.Fatalf("local %s: %v", name, err)
		}
	}
	if trust.count() != 3+len(mutations) {
		t.Fatalf("calls=%v", trust.calls)
	}
}
