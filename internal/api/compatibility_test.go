package api

import (
	"context"
	"io"
	"log/slog"
	"testing"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/store/daemonstate"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestDaemonRejectsClientBelowPersistedGatewayFloor(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	state := daemonstate.New(data)
	if err := state.SaveGatewayCompatibilityPolicy(daemonstate.GatewayCompatibilityPolicy{
		GatewayReleaseVersion: "0.4.310", MinimumClientVersion: "0.4.309",
		MinimumDaemonVersion: "0.4.308", Revision: "policy-revision",
	}); err != nil {
		t.Fatal(err)
	}
	interceptor := clientCompatibilityInterceptor{state: state}
	if err := interceptor.check(dieterv1connect.MachineServiceHealthProcedure, ""); err != nil {
		t.Fatalf("health bootstrap rejected: %v", err)
	}
	if err := interceptor.check(dieterv1connect.StateServiceGetStateProcedure, "0.4.309"); err != nil {
		t.Fatalf("current client rejected: %v", err)
	}
	for name, release := range map[string]string{"outdated": "0.4.308", "missing": "", "invalid": "development"} {
		t.Run(name, func(t *testing.T) {
			if err := interceptor.check(dieterv1connect.StateServiceGetStateProcedure, release); connect.CodeOf(err) != connect.CodeFailedPrecondition {
				t.Fatalf("error=%v code=%v", err, connect.CodeOf(err))
			}
		})
	}
}

func TestClientFloorGuardsStreamsAndAllowsUnenrolledDaemons(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	state := daemonstate.New(data)
	application := NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), Options{Runner: newFakeRunner(), Catalog: testkit.MockCatalog(), DaemonState: state})
	host := testkit.HTTPServer(application.Handler())
	t.Cleanup(host.Close)
	client := dieterclient.NewConnect(localHTTPClient(host.Client(), data.Root), host.URL)
	release := func(value string) context.Context {
		return withHeaders(t.Context(), map[string]string{clientReleaseHeader: value})
	}
	// Without an authenticated gateway policy every client may bootstrap.
	if _, err := client.GetState(release(""), &dieterv1.GetStateRequest{}); err != nil {
		t.Fatalf("unenrolled daemon rejected a client: %v", err)
	}
	if err := state.SaveGatewayCompatibilityPolicy(daemonstate.GatewayCompatibilityPolicy{
		GatewayReleaseVersion: "0.4.310", MinimumClientVersion: "0.4.309", MinimumDaemonVersion: "0.4.308", Revision: "policy-revision",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetState(release("0.4.308"), &dieterv1.GetStateRequest{}); connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("outdated unary client: %v", err)
	}
	if _, err := client.Health(release("0.4.308"), &emptypb.Empty{}); err != nil {
		t.Fatalf("health must stay available to outdated clients: %v", err)
	}
	outdated, err := client.WatchChanges(release("0.4.308"), &dieterv1.ChangesRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if outdated.Receive() || connect.CodeOf(outdated.Err()) != connect.CodeFailedPrecondition {
		t.Fatalf("outdated stream client: %v", outdated.Err())
	}
	_ = outdated.Close()
	current, err := client.WatchChanges(release("0.4.309"), &dieterv1.ChangesRequest{})
	if err != nil {
		t.Fatal(err)
	}
	defer current.Close()
	if !current.Receive() {
		t.Fatalf("current stream client: %v", current.Err())
	}
}
