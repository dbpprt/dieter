package topology

import (
	"context"
	"testing"

	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/testkit"
	"google.golang.org/grpc"
)

// Topology is a gateway with the daemons started behind it.
type Topology struct {
	Gateway *Gateway
	Daemons []*Daemon
}

// Start runs a gateway and one daemon per options entry for the test's
// lifetime. Daemon roots default to fresh homes, runners to a FakeRunner, and
// catalogs to the mock catalog.
func Start(tb testing.TB, gateway GatewayOptions, daemons ...DaemonOptions) *Topology {
	tb.Helper()
	topology := &Topology{Gateway: StartGateway(tb, gateway)}
	for _, options := range daemons {
		topology.Daemons = append(topology.Daemons, StartDaemon(tb, topology.Gateway, options))
	}
	return topology
}

// StartGateway runs a gateway until the test ends; Root defaults to a
// temporary directory.
func StartGateway(tb testing.TB, options GatewayOptions) *Gateway {
	tb.Helper()
	if options.Root == "" {
		options.Root = tb.TempDir()
	}
	gateway, err := NewGateway(options)
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(gateway.Close)
	return gateway
}

// StartDaemon runs a daemon behind g until the test ends.
func StartDaemon(tb testing.TB, g *Gateway, options DaemonOptions) *Daemon {
	tb.Helper()
	if options.Root == "" && options.Identity == nil {
		options.Root = testkit.Home(tb)
	}
	if options.Name == "" {
		options.Name = "Test machine"
	}
	if options.API.Runner == nil {
		options.API.Runner = &testkit.FakeRunner{}
	}
	if options.API.Catalog == nil {
		options.API.Catalog = testkit.MockCatalog()
	}
	daemon, err := g.StartDaemon(tb.Context(), options)
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(daemon.Close)
	return daemon
}

// Machine enrolls an identity named name for account in a fresh home.
func Machine(tb testing.TB, g *Gateway, name string, account int64) *link.Identity {
	tb.Helper()
	identity, err := g.Enroll(tb.Context(), testkit.Home(tb), name, account)
	if err != nil {
		tb.Fatal(err)
	}
	return identity
}

// SignIn returns a client session token for account.
func SignIn(tb testing.TB, g *Gateway, account int64, login string) string {
	tb.Helper()
	token, err := g.NewSession("test_", account, login)
	if err != nil {
		tb.Fatal(err)
	}
	return token
}

// Dial returns a gateway gRPC connection closed when the test ends.
func Dial(tb testing.TB, g *Gateway) *grpc.ClientConn {
	tb.Helper()
	connection, err := g.Dial()
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(func() { _ = connection.Close() })
	return connection
}

// StartClient pairs a test app device approved by approver until the test
// ends.
func StartClient(tb testing.TB, g *Gateway, approver *Daemon, name string) *Client {
	tb.Helper()
	client, err := g.NewClient(tb.Context(), approver, name)
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(client.Close)
	return client
}

// DialDaemon connects client to daemon over route until the test ends.
func DialDaemon(tb testing.TB, client *Client, daemon *Daemon, route Route) *grpc.ClientConn {
	tb.Helper()
	connection, err := client.Dial(tb.Context(), daemon.Identity.ID, route)
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(func() { _ = connection.Close() })
	return connection
}

// Join pairs the device trust of identity, a machine whose daemon the test
// plays itself (peer sync, the CLI), with the code approver approves. Its
// roster follows the gateway until the test ends.
func Join(tb testing.TB, g *Gateway, approver *Daemon, identity *link.Identity) *link.Trust {
	tb.Helper()
	deviceTrust, err := link.OpenTrust(identity, discard())
	if err != nil {
		tb.Fatal(err)
	}
	deviceTrust.PairingPoll = PairingPoll
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		deviceTrust.Run(ctx)
	}()
	tb.Cleanup(func() {
		cancel()
		<-done
		deviceTrust.Close()
	})
	if err := Pair(tb.Context(), approver.Trust, deviceTrust); err != nil {
		tb.Fatal(err)
	}
	return deviceTrust
}
