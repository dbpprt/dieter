package topology

import (
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
