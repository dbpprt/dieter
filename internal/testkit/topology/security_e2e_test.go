//go:build e2e

package topology_test

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// recorder keeps every byte the gateway reads and writes on any connection:
// clients, relay tunnels, and daemon links. The test gateway runs without
// TLS, so this is what a gateway operator sees.
type recorder struct {
	mu   sync.Mutex
	data bytes.Buffer
}

type recordingListener struct {
	net.Listener
	recorder *recorder
}

type recordingConn struct {
	net.Conn
	recorder *recorder
}

func (r *recorder) wrap(listener net.Listener) net.Listener {
	return recordingListener{Listener: listener, recorder: r}
}

func (r *recorder) contains(value string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return bytes.Contains(r.data.Bytes(), []byte(value))
}

func (l recordingListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return recordingConn{Conn: conn, recorder: l.recorder}, nil
}

func (c recordingConn) Read(buffer []byte) (int, error) {
	n, err := c.Conn.Read(buffer)
	c.recorder.mu.Lock()
	c.recorder.data.Write(buffer[:n])
	c.recorder.mu.Unlock()
	return n, err
}

func (c recordingConn) Write(buffer []byte) (int, error) {
	c.recorder.mu.Lock()
	c.recorder.data.Write(buffer)
	c.recorder.mu.Unlock()
	return c.Conn.Write(buffer)
}

func canary(t *testing.T, label string) string {
	t.Helper()
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		t.Fatal(err)
	}
	return "canary-" + label + "-" + hex.EncodeToString(raw)
}

// exercise drives a project, a chat turn, a file and a remote execution, each
// carrying its own canary, over one daemon connection.
func exercise(t *testing.T, client dieterclient.Client, repository, label string) []string {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(60*time.Second))
	defer cancel()
	projectName, prompt, content, output := canary(t, label+"-project"), canary(t, label+"-prompt"), canary(t, label+"-file"), canary(t, label+"-exec")
	created, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{Mode: "open", Path: repository, Name: projectName})
	if err != nil {
		t.Fatal(err)
	}
	projectID := created.GetProject().GetId()
	chat, err := client.CreateChat(ctx, &dieterv1.CreateConversationRequest{ProjectId: projectID, Title: "Canary chat", Prompt: prompt, Provider: "mock", Model: "mock", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	for {
		conversation, err := client.GetConversation(ctx, &dieterv1.GetConversationRequest{CardId: chat.GetId()})
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := json.Marshal(conversation)
		if strings.Contains(string(raw), "echo "+prompt) {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatalf("%s: the turn reply never arrived", label)
		case <-time.After(20 * time.Millisecond):
		}
	}
	if _, err := client.CreateFile(ctx, &dieterv1.CreateFileRequest{ProjectId: projectID, Path: label + "-notes.txt", Kind: "file", Content: content}); err != nil {
		t.Fatal(err)
	}
	document, err := client.ReadFile(ctx, &dieterv1.ReadFileRequest{ProjectId: projectID, Path: label + "-notes.txt"})
	if err != nil || !strings.Contains(document.GetContent(), content) {
		t.Fatalf("%s: file read %v %v", label, document, err)
	}
	execution, err := client.StartExecution(ctx, &dieterv1.StartExecutionRequest{ProjectId: projectID, Argv: []string{"/bin/sh", "-c", "cat"}, Stdin: []byte(output), StdinEof: true})
	if err != nil {
		t.Fatal(err)
	}
	watch, err := client.WatchExecution(ctx, &dieterv1.WatchExecutionRequest{ExecutionId: execution.GetId()})
	if err != nil {
		t.Fatal(err)
	}
	// Read until the daemon ends the watch after the execution's final event,
	// so nothing still writes to the daemon's home when the test removes it.
	// Every event carries a snapshot of the execution, so an exit code can
	// arrive before the output does.
	var echoed []byte
	for {
		event, err := watch.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("%s: execution output %q: %v", label, echoed, err)
		}
		echoed = append(echoed, event.GetData()...)
	}
	if !bytes.Contains(echoed, []byte(output)) {
		t.Fatalf("%s: execution output %q", label, echoed)
	}
	return []string{projectName, prompt, content, output}
}

// settle waits until every turn of data finished, so no writer is left when
// the test removes the daemon's home.
func settle(t *testing.T, data *store.Store) {
	t.Helper()
	cards, err := data.Kanban.ListCards(kanban.CardFilter{})
	if err != nil {
		t.Fatal(err)
	}
	for _, card := range cards {
		testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool {
			stored, cardErr := data.Kanban.ResolveCard(card.ID)
			leased, leaseErr := data.Leases.CardActive(card.ID)
			return cardErr == nil && leaseErr == nil && !leased && stored.Runtime == "idle"
		}, "turn of %s to finish", card.ID)
	}
	if err := data.WaitForWriter(t.Context()); err != nil {
		t.Fatal(err)
	}
}

// The gateway relays every carrier but sees no content: not on the wire of a
// relay tunnel, not in peer replication, and not in its own state.
func TestGatewayRelaysButNeverSeesContent(t *testing.T) {
	t.Parallel()
	traffic := &recorder{}
	runner := &testkit.FakeRunner{Reply: func(request harness.Request) string { return "echo " + request.Prompt }}
	network := topology.Start(t, topology.GatewayOptions{Listen: traffic.wrap},
		topology.DaemonOptions{Name: "Canary A", Direct: true, API: api.Options{Runner: runner}},
		topology.DaemonOptions{Name: "Canary B"})
	a, b := network.Daemons[0], network.Daemons[1]
	scope := crdt.Revision([]string{a.Identity.Issuer(), "github:42"})
	if _, err := a.Store.Replica.BindPeerAccount(scope, "github:42", a.Identity.ID, a.Identity.Issuer()); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Store.Replica.BindPeerAccount(scope, "github:42", b.Identity.ID, b.Identity.Issuer()); err != nil {
		t.Fatal(err)
	}
	client := topology.StartClient(t, network.Gateway, a, "Canary phone")
	var canaries []string
	for route, label := range map[topology.Route]string{topology.Tunnel: "tunnel", topology.Direct: "direct"} {
		connection := dieterclient.New(topology.DialDaemon(t, client, a, route))
		canaries = append(canaries, exercise(t, connection, testkit.CheckoutDir(t), label)...)
	}
	settle(t, a.Store)
	// Peer replication from A reaches B through a relay tunnel: B advertises no
	// direct route and no WebRTC.
	syncer := &peersync.PeerSync{Identity: a.Identity, Trust: a.Trust, Store: a.Store}
	if err := syncer.Round(t.Context()); err != nil {
		t.Fatal(err)
	}
	replicated, err := b.Store.Replica.PeerData(scope)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(replicated.Records)
	if !strings.Contains(string(raw), canaries[0]) {
		t.Fatalf("project %s did not replicate", canaries[0])
	}
	if data, err := a.Store.Replica.PeerData(scope); err != nil || data.LastRoute != "relay" {
		t.Fatalf("peer route %q, want relay: %v", data.LastRoute, err)
	}
	// Positive control: the recorder sees what the gateway legitimately reads,
	// such as the device names of the roster.
	if !traffic.contains("Canary phone") {
		t.Fatal("the recorder captured no gateway traffic")
	}
	for _, value := range canaries {
		if traffic.contains(value) {
			t.Errorf("the gateway saw %s on the wire", value)
		}
	}
	err = filepath.WalkDir(network.Gateway.Config.Root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		defer file.Close()
		raw, err := io.ReadAll(file)
		if err != nil {
			return err
		}
		for _, value := range canaries {
			if bytes.Contains(raw, []byte(value)) {
				t.Errorf("the gateway stored %s in %s", value, path)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// A daemon accepts only roster devices with a token bound to the presented
// key, and a client accepts only the roster key of the daemon it dials,
// whatever the gateway relays.
func TestDaemonsAndClientsRefuseUntrustedPeersThroughTheGateway(t *testing.T) {
	t.Parallel()
	network := topology.Start(t, topology.GatewayOptions{}, topology.DaemonOptions{Name: "A"}, topology.DaemonOptions{Name: "B"})
	a, b := network.Daemons[0], network.Daemons[1]
	first := topology.StartClient(t, network.Gateway, a, "First phone")
	second := topology.StartClient(t, network.Gateway, a, "Second phone")
	health := func(certificate *ecdsa.PrivateKey, daemonKey []byte, token string, target *topology.Daemon) error {
		t.Helper()
		tlsCertificate, err := link.DeviceCertificate(certificate)
		if err != nil {
			t.Fatal(err)
		}
		dial, err := first.Dialer(t.Context(), target.Identity.ID, topology.Tunnel)
		if err != nil {
			t.Fatal(err)
		}
		connection, err := link.DialDaemon(tlsCertificate, daemonKey, link.TokenCredentials(token), dial)
		if err != nil {
			t.Fatal(err)
		}
		defer connection.Close()
		ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
		defer cancel()
		_, err = dieterclient.New(connection).Health(ctx, &emptypb.Empty{})
		return err
	}
	keyA, err := first.DaemonKey(t.Context(), a.Identity.ID)
	if err != nil {
		t.Fatal(err)
	}
	keyB, err := first.DaemonKey(t.Context(), b.Identity.ID)
	if err != nil {
		t.Fatal(err)
	}
	tokenFirst, err := first.Token(t.Context(), a.Identity.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := health(first.Key, keyA, tokenFirst, a); err != nil {
		t.Fatalf("a paired client was refused: %v", err)
	}
	// A key outside the roster, even with a session and a matching token.
	outsider, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	outsiderDescriptor, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "jvm", "Outsider", "", outsider.Public())
	if err != nil {
		t.Fatal(err)
	}
	outsiderToken, err := gatewayv1.NewGatewayServiceClient(first.Gateway).ExchangeDaemonToken(t.Context(), &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: a.Identity.ID, ClientKeyThumbprint: outsiderDescriptor.GetDeviceId()})
	if err != nil {
		t.Fatal(err)
	}
	if err := health(outsider, keyA, outsiderToken.GetAccessToken(), a); status.Code(err) != codes.Unavailable {
		t.Fatalf("a key outside the roster: %v", err)
	}
	// A token bound to another device.
	if err := health(second.Key, keyA, tokenFirst, a); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("a token of another device: %v", err)
	}
	// The gateway issues no token without a device.
	if _, err := gatewayv1.NewGatewayServiceClient(first.Gateway).ExchangeDaemonToken(t.Context(), &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: a.Identity.ID}); err == nil {
		t.Fatal("the gateway issued a token without a device")
	}
	// The tunnel reaches A while the client expects B's key: a gateway that
	// routes a tunnel to another machine is refused by the client.
	tokenB, err := first.Token(t.Context(), b.Identity.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := health(first.Key, keyB, tokenB, a); status.Code(err) != codes.Unavailable {
		t.Fatalf("a tunnel to another daemon: %v", err)
	}
	// A revoked device is refused at once by the machine that revoked it, and
	// by the others as soon as they see the revocation.
	if _, err := a.Trust.Revoke(t.Context(), second.DeviceID()); err != nil {
		t.Fatal(err)
	}
	tokenSecond, err := second.Token(t.Context(), a.Identity.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := health(second.Key, keyA, tokenSecond, a); status.Code(err) != codes.Unavailable {
		t.Fatalf("a revoked device: %v", err)
	}
	deadline := time.Now().Add(testkit.Budget(10 * time.Second))
	for {
		tokenSecondB, err := second.Token(t.Context(), b.Identity.ID)
		if err != nil {
			t.Fatal(err)
		}
		if err := health(second.Key, keyB, tokenSecondB, b); status.Code(err) == codes.Unavailable {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the other daemon kept accepting a revoked device")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if b.Trust.Status().GetHeadSequence() != a.Trust.Status().GetHeadSequence() {
		t.Fatal("daemons disagree on the roster head")
	}
}
