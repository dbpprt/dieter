//go:build e2e

package gateway_test

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/gateway"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestGatewayRelocationPreservesEnrollmentAndPeerIdentity(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	oldListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer oldListener.Close()
	newListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer newListener.Close()
	oldURL, _ := url.Parse("http://" + oldListener.Addr().String())
	newURL, _ := url.Parse("http://" + newListener.Addr().String())
	config := gateway.Config{Root: t.TempDir(), PublicURL: newURL, IssuerURL: oldURL, AllowedUserIDs: map[int64]struct{}{42: {}}, AuthSecret: []byte("0123456789abcdef0123456789abcdef"), DevInsecure: true}
	data, err := gateway.OpenStore(config.Root)
	if err != nil {
		t.Fatal(err)
	}
	defer data.Close()
	g, err := gateway.NewServer(config, data, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer g.APIGRPC.Stop()
	go func() { _ = g.APIGRPC.Serve(oldListener) }()
	go func() { _ = g.APIGRPC.Serve(newListener) }()
	local := testkit.Store(t)
	identity, err := link.LoadOrCreateEnrollmentIdentity(local.Root, "relocation", oldURL.String())
	if err != nil {
		t.Fatal(err)
	}
	enrollment, err := link.BeginEnrollment(ctx, identity)
	if err != nil {
		t.Fatal(err)
	}
	if err := data.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), 42, "fixture"); err != nil {
		t.Fatal(err)
	}
	credential, err := link.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
	if err != nil {
		t.Fatal(err)
	}
	if credential.GetGatewayIssuer() != oldURL.String() {
		t.Fatal("enrollment lost durable issuer")
	}
	// Model an existing enrollment created before explicit issuer discovery.
	if err := identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); err != nil {
		t.Fatal(err)
	}
	scope := crdt.Revision([]string{identity.Issuer(), "github:42"})
	binding, err := local.Replica.BindPeerAccount(scope, "github:42", identity.ID, identity.Issuer())
	if err != nil {
		t.Fatal(err)
	}
	keyPath := filepath.Join(local.Root, "daemon", "identity-key.pem")
	keyBefore, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	endpoint, err := link.ResolveGatewayEndpoint(ctx, identity)
	if err != nil || endpoint != newURL.String() {
		t.Fatalf("resolve %q: %v", endpoint, err)
	}
	changed := *identity
	changed.ID = "wrong-id"
	if err := link.RelocateGateway(&changed, endpoint); err == nil {
		t.Fatal("changed enrollment accepted")
	}
	if err := link.RelocateGateway(identity, endpoint); err != nil {
		t.Fatal(err)
	}
	moved, err := link.LoadIdentity(local.Root)
	if err != nil {
		t.Fatal(err)
	}
	if moved.GatewayURL != endpoint || moved.Issuer() != oldURL.String() || moved.ID != identity.ID || moved.Generation != identity.Generation || !bytes.Equal(moved.CertificatePEM, identity.CertificatePEM) {
		t.Fatal("gateway move changed enrollment identity")
	}
	keyAfter, _ := os.ReadFile(keyPath)
	if !bytes.Equal(keyBefore, keyAfter) {
		t.Fatal("daemon private key changed")
	}
	next, err := local.Replica.BindPeerAccount(scope, "github:42", moved.ID, moved.Issuer())
	if err != nil || next != binding {
		t.Fatalf("peer binding/actor changed: %v", err)
	}
	if resolved, err := link.ResolveGatewayEndpoint(ctx, moved); err != nil || resolved != endpoint {
		t.Fatalf("relocated enrollment cannot authenticate: %v", err)
	}
	if err := link.Unenroll(ctx, moved); err != nil {
		t.Fatalf("relocated possession proof failed: %v", err)
	}
}
