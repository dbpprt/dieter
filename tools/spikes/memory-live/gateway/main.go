// Command gateway is a loopback gateway copy for the agent memory live test
// (card c_5ce5): it enrolls each NAME=DIETER_HOME argument with one test
// account and serves until interrupted, so real `dieter serve` daemons on
// those homes run enrolled (provider logins, replication, relay) without the
// production gateway.
//
//	go run ./tools/spikes/memory-live/gateway -addr 127.0.0.1:47620 -root DIR alpha=/tmp/x/alpha beta=/tmp/x/beta
package main

import (
	"context"
	"crypto/rand"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/dbpprt/dieter/internal/gateway"
	"github.com/dbpprt/dieter/internal/testkit/topology"
)

func main() {
	address := flag.String("addr", "127.0.0.1:47620", "loopback listen address")
	root := flag.String("root", "", "gateway state directory")
	flag.Parse()
	if *root == "" {
		fmt.Fprintln(os.Stderr, "-root is required")
		os.Exit(2)
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		panic(err)
	}
	g, err := topology.NewGateway(topology.GatewayOptions{
		Root: *root, Address: *address, Accounts: []int64{topology.Account}, Login: "memory-live",
		AuthSecret: secret, SessionTTL: 12 * time.Hour, Logger: logger,
		Configure: func(config *gateway.Config) { config.GitHubClientID, config.GitHubSecret = "isolated", "isolated" },
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "gateway:", err)
		os.Exit(1)
	}
	defer g.Close()
	for _, argument := range flag.Args() {
		name, home, ok := strings.Cut(argument, "=")
		if !ok {
			fmt.Fprintln(os.Stderr, "arguments are NAME=DIETER_HOME")
			os.Exit(2)
		}
		identity, err := g.Enroll(ctx, home, name, topology.Account)
		if err != nil {
			fmt.Fprintln(os.Stderr, "enroll", name, err)
			os.Exit(1)
		}
		fmt.Printf("enrolled %s as %s (%s)\n", name, identity.ID, home)
	}
	fmt.Printf("gateway ready at %s\n", g.URL)
	<-ctx.Done()
}
