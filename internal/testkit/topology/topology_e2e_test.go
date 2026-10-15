//go:build e2e

package topology_test

import (
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestTopologyPairsDaemonsAndClientsOverEveryCarrier(t *testing.T) {
	t.Parallel()
	network := topology.Start(t, topology.GatewayOptions{}, topology.DaemonOptions{Name: "First", Direct: true}, topology.DaemonOptions{Name: "Second"})
	first, second := network.Daemons[0], network.Daemons[1]
	for _, daemon := range network.Daemons {
		if state := daemon.Trust.State(); state != dieterv1.TrustState_TRUST_STATE_TRUSTED {
			t.Fatalf("%s trust state %v", daemon.Identity.Name, state)
		}
	}
	if first.Trust.Status().GetRootHash() != second.Trust.Status().GetRootHash() {
		t.Fatal("daemons pinned different rosters")
	}
	client := topology.StartClient(t, network.Gateway, second, "Test phone")
	if _, err := first.Trust.DaemonKey(second.Identity.ID); err != nil {
		t.Fatal(err)
	}
	for name, connection := range map[string]dieterclient.Client{
		"direct": dieterclient.New(topology.DialDaemon(t, client, first, topology.Direct)),
		"tunnel": dieterclient.New(topology.DialDaemon(t, client, first, topology.Tunnel)),
		"second": dieterclient.New(topology.DialDaemon(t, client, second, topology.Tunnel)),
	} {
		health, err := connection.Health(t.Context(), &emptypb.Empty{})
		if err != nil || health.GetStatus() == "" {
			t.Fatalf("%s health: %v %v", name, health, err)
		}
		status, err := connection.GetTrustStatus(t.Context(), &emptypb.Empty{})
		if err != nil || status.GetState() != dieterv1.TrustState_TRUST_STATE_TRUSTED || len(status.GetDevices()) != 4 {
			t.Fatalf("%s trust status: %v %v", name, status, err)
		}
	}
}
