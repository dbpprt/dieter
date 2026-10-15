//go:build e2e

package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
)

// localDeviceCLI is the CLI of the machine daemon runs on: it reaches the
// daemon over the loopback API with the daemon's local token.
func localDeviceCLI(t *testing.T, daemon *topology.Daemon) (*CLI, *bytes.Buffer) {
	t.Helper()
	if _, err := link.NewStatusWriter(daemon.Store.Root, link.RuntimeStatus{PID: os.Getpid(), Version: "test", State: "running", ListenAddress: daemon.Address, GatewayState: link.GatewayConnected}); err != nil {
		t.Fatal(err)
	}
	client := New(daemon.Store.Root)
	output := &bytes.Buffer{}
	client.Out, client.Err = output, output
	client.Timeout = 10 * time.Second
	t.Cleanup(client.Close)
	return client, output
}

// remoteDeviceCLI runs on the machine of local and targets target.
func remoteDeviceCLI(t *testing.T, g *topology.Gateway, local, target *topology.Daemon) (*CLI, *bytes.Buffer) {
	t.Helper()
	client := New(local.Identity.Root)
	client.Machine, client.GatewayURL, client.Timeout = target.Identity.ID, g.URL, 15*time.Second
	output := &bytes.Buffer{}
	client.Out, client.Err = output, output
	t.Cleanup(client.Close)
	return client, output
}

func waitTrustState(t *testing.T, daemon *topology.Daemon, state dieterv1.TrustState) {
	t.Helper()
	deadline := time.Now().Add(testkit.Budget(10 * time.Second))
	for daemon.Trust.State() != state {
		if time.Now().After(deadline) {
			t.Fatalf("%s trust state %v, want %v", daemon.Identity.Name, daemon.Trust.State(), state)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestDeviceCLIOverLocalDirectAndRelayRoutes(t *testing.T) {
	t.Parallel()
	g := topology.StartGateway(t, topology.GatewayOptions{})
	first := topology.StartDaemon(t, g, topology.DaemonOptions{Name: "First", Direct: true})
	second := topology.StartDaemon(t, g, topology.DaemonOptions{Name: "Second"})

	local, output := localDeviceCLI(t, first)
	if status := runDaemonCLI(t, local, output, "device", "status"); !strings.Contains(status, "TRUSTED") || !strings.Contains(status, "(this machine)") || !strings.Contains(status, "Second") {
		t.Fatalf("local status=%q", status)
	}
	var roster struct {
		Entries []struct {
			Operation string `json:"operation"`
		} `json:"entries"`
	}
	if raw := runDaemonCLI(t, local, output, "device", "roster", "--format", "json"); json.Unmarshal([]byte(raw), &roster) != nil || len(roster.Entries) != 3 {
		t.Fatalf("local roster=%q", raw)
	}
	if requests := runDaemonCLI(t, local, output, "device", "requests"); !strings.Contains(requests, "No device is waiting") {
		t.Fatalf("local requests=%q", requests)
	}

	// A new machine waits with its code; the second machine's CLI approves it
	// on the first machine over direct TLS.
	pending := topology.StartDaemon(t, g, topology.DaemonOptions{Name: "Pending", Untrusted: true})
	waitTrustState(t, pending, dieterv1.TrustState_TRUST_STATE_PENDING)
	code := pending.Trust.Status().GetPairingCode()
	direct, directOutput := remoteDeviceCLI(t, g, second, first)
	deadline := time.Now().Add(testkit.Budget(10 * time.Second))
	for requests := ""; !strings.Contains(requests, "Pending"); requests = runDaemonCLI(t, direct, directOutput, "device", "requests") {
		if time.Now().After(deadline) {
			t.Fatalf("pending request not listed: %q", requests)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if direct.transport.route != "direct" {
		t.Fatalf("route=%s, want direct", direct.transport.route)
	}
	if strings.Contains(directOutput.String(), code) {
		t.Fatal("a pairing code was listed")
	}
	if approved := runDaemonCLI(t, direct, directOutput, "device", "approve", code); !strings.Contains(approved, "Approved") {
		t.Fatalf("approve=%q", approved)
	}
	waitTrustState(t, pending, dieterv1.TrustState_TRUST_STATE_TRUSTED)
	directOutput.Reset()
	if err := direct.Run([]string{"device", "approve", "0000-0000-0000-0000"}); err == nil || !strings.Contains(err.Error(), "No device is waiting with this code") {
		t.Fatalf("wrong code: %v", err)
	}
	for _, args := range [][]string{{"device", "init"}, {"device", "recover", "--recovery-key", "DRK1-X"}} {
		if err := direct.Run(args); err == nil || !strings.Contains(err.Error(), "only on the machine itself") {
			t.Fatalf("%v over --machine: %v", args, err)
		}
	}

	// Without the direct route the CLI tunnels through the gateway relay.
	first.Direct.Server.Stop()
	_ = first.Direct.Listener.Close()
	relayed, relayedOutput := remoteDeviceCLI(t, g, second, first)
	if status := runDaemonCLI(t, relayed, relayedOutput, "device", "status"); !strings.Contains(status, "Pending") {
		t.Fatalf("relay status=%q", status)
	}
	if relayed.transport.route != "relay" {
		t.Fatalf("route=%s, want relay", relayed.transport.route)
	}
	if synced := runDaemonCLI(t, relayed, relayedOutput, "device", "sync"); !strings.Contains(synced, "TRUSTED") {
		t.Fatalf("relay sync=%q", synced)
	}
	runDaemonCLI(t, relayed, relayedOutput, "device", "roster")
	runDaemonCLI(t, relayed, relayedOutput, "device", "requests")
	if revoked := runDaemonCLI(t, relayed, relayedOutput, "device", "revoke", pending.Trust.DeviceID()); !strings.Contains(revoked, "removed") {
		t.Fatalf("relay revoke=%q", revoked)
	}
	waitTrustState(t, pending, dieterv1.TrustState_TRUST_STATE_REVOKED)
	// The revoked machine is no longer a target.
	toRevoked, _ := remoteDeviceCLI(t, g, second, pending)
	if err := toRevoked.Run([]string{"device", "status"}); err == nil || !strings.Contains(err.Error(), "not a trusted device") {
		t.Fatalf("revoked target: %v", err)
	}
	// Agents never change device trust, even on another machine.
	relayed.env.TurnToken = "agent-turn"
	if err := relayed.Run([]string{"device", "approve", code}); err == nil || !strings.Contains(err.Error(), "agents cannot change device trust") {
		t.Fatalf("agent approve: %v", err)
	}
}

func TestDeviceCLIStartsAndRecoversTheRosterLocally(t *testing.T) {
	t.Parallel()
	g := topology.StartGateway(t, topology.GatewayOptions{})
	first := topology.StartDaemon(t, g, topology.DaemonOptions{Name: "First", Untrusted: true})
	waitTrustState(t, first, dieterv1.TrustState_TRUST_STATE_NO_ROSTER)
	local, output := localDeviceCLI(t, first)
	if status := runDaemonCLI(t, local, output, "device", "status"); !strings.Contains(status, "NO_ROSTER") || !strings.Contains(status, "dieter device init") {
		t.Fatalf("status=%q", status)
	}
	initialized := runDaemonCLI(t, local, output, "device", "init")
	key := regexp.MustCompile(`DRK1-[0-9A-Z-]+`).FindString(initialized)
	if key == "" || !strings.Contains(initialized, "store it offline") {
		t.Fatalf("init=%q", initialized)
	}
	output.Reset()
	if err := local.Run([]string{"device", "init"}); err == nil || !strings.Contains(err.Error(), "--replace") {
		t.Fatalf("second init: %v", err)
	}
	second := topology.StartDaemon(t, g, topology.DaemonOptions{Name: "Second", Untrusted: true})
	waitTrustState(t, second, dieterv1.TrustState_TRUST_STATE_PENDING)
	pending, pendingOutput := localDeviceCLI(t, second)
	if status := runDaemonCLI(t, pending, pendingOutput, "device", "status"); !strings.Contains(status, "Pairing code:") || !strings.Contains(status, "dieter device approve CODE") {
		t.Fatalf("pending status=%q", status)
	}
	pending.In = strings.NewReader(strings.ToLower(key) + "\n")
	if recovered := runDaemonCLI(t, pending, pendingOutput, "device", "recover", "--recovery-key", "-"); !strings.Contains(recovered, "TRUSTED") {
		t.Fatalf("recover=%q", recovered)
	}
	waitTrustState(t, second, dieterv1.TrustState_TRUST_STATE_TRUSTED)
	if second.Trust.Status().GetRootHash() != first.Trust.Status().GetRootHash() {
		t.Fatal("the recovered machine joined another roster")
	}
}
