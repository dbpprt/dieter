//go:build e2e

package main

import (
	"context"
	"io"
	"log/slog"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/types/known/emptypb"
)

// Native fixture clients pair with the one code the fixture prints; each still
// pins only after the approver's confirmation verifies.
func TestFixtureApprovesEveryClientThatProvesItsPairingCode(t *testing.T) {
	t.Parallel()
	network := topology.Start(t, topology.GatewayOptions{}, topology.DaemonOptions{Name: "Primary"})
	primary := network.Daemons[0]
	_, code, err := roster.NewPairingSecret()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	go approvePairingCode(ctx, primary.Trust, code, slog.New(slog.NewTextHandler(io.Discard, nil)))
	for _, name := range []string{"First app", "Second app"} {
		client, err := network.Gateway.NewClientWithCode(t.Context(), topology.Account, name, code)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		defer client.Close()
		connection := topology.DialDaemon(t, client, primary, topology.Tunnel)
		status, err := dieterclient.New(connection).GetTrustStatus(t.Context(), &emptypb.Empty{})
		if err != nil || status.GetState() != dieterv1.TrustState_TRUST_STATE_TRUSTED {
			t.Fatalf("%s trust status: %v %v", name, status, err)
		}
	}
	if devices := primary.Trust.Status().GetDevices(); len(devices) != 4 {
		t.Fatalf("roster devices=%d, want machine, recovery key and two apps", len(devices))
	}
}
