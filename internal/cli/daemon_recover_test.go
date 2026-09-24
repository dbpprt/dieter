package cli

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
)

type recoveryGatewayStub struct {
	gatewayv1.GatewayServiceClient
	inspect func(*gatewayv1.DaemonRecoveryRef) (*gatewayv1.DaemonRecoveryState, error)
	recover func(*gatewayv1.RecoverDaemonRequest) (*gatewayv1.DaemonCredential, error)
	calls   int
}

func (stub *recoveryGatewayStub) InspectDaemonRecovery(_ context.Context, request *gatewayv1.DaemonRecoveryRef, _ ...grpc.CallOption) (*gatewayv1.DaemonRecoveryState, error) {
	return stub.inspect(request)
}

func (stub *recoveryGatewayStub) RecoverDaemon(_ context.Context, request *gatewayv1.RecoverDaemonRequest, _ ...grpc.CallOption) (*gatewayv1.DaemonCredential, error) {
	stub.calls++
	return stub.recover(request)
}

func TestDaemonRecoverValidatesGatewayResultBeforeLocalCutover(t *testing.T) {
	const issuer = "https://issuer.example.test"
	const oldID = "d_original"
	const replacementID = "d_replacement"
	root := t.TempDir()
	identity, err := dieterdaemon.LoadOrCreateEnrollmentIdentity(root, "Replacement", issuer)
	if err != nil {
		t.Fatal(err)
	}
	keys, err := gateway.LoadOrCreateKeys(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	publicDER, err := identity.PublicKeyDER()
	if err != nil {
		t.Fatal(err)
	}
	replacementCert, _, err := keys.IssueDaemonCertificate(replacementID, publicDER)
	if err != nil {
		t.Fatal(err)
	}
	oldCert, _, err := keys.IssueDaemonCertificate(oldID, publicDER)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(oldCert)
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	signingKey, err := keys.SigningPublicPEM()
	if err != nil {
		t.Fatal(err)
	}
	otherIdentity, err := dieterdaemon.LoadOrCreateEnrollmentIdentity(t.TempDir(), "Other", issuer)
	if err != nil {
		t.Fatal(err)
	}
	otherPublicDER, err := otherIdentity.PublicKeyDER()
	if err != nil {
		t.Fatal(err)
	}
	otherKeyCert, _, err := keys.IssueDaemonCertificate(oldID, otherPublicDER)
	if err != nil {
		t.Fatal(err)
	}
	otherKeys, err := gateway.LoadOrCreateKeys(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	otherCACert, _, err := otherKeys.IssueDaemonCertificate(oldID, publicDER)
	if err != nil {
		t.Fatal(err)
	}
	otherSigningKey, err := otherKeys.SigningPublicPEM()
	if err != nil {
		t.Fatal(err)
	}
	identity.GatewayIssuer = issuer
	if err := identity.SaveCredential(replacementID, "Replacement", replacementCert, keys.DaemonCAPEM, signingKey, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}
	client := New(store.New(root))
	var output bytes.Buffer
	client.Out = &output
	stub := &recoveryGatewayStub{
		inspect: func(ref *gatewayv1.DaemonRecoveryRef) (*gatewayv1.DaemonRecoveryState, error) {
			if ref.GetRevokedDaemonId() != oldID || ref.GetReplacementDaemonId() != replacementID {
				t.Fatalf("wrong recovery inspection: %+v", ref)
			}
			return &gatewayv1.DaemonRecoveryState{RevokedGeneration: 2, ReplacementGeneration: identity.Generation}, nil
		},
	}
	client.gateway = &gatewayTransport{client: stub}
	credential := &gatewayv1.DaemonCredential{
		DaemonId: oldID, DaemonName: "Original", CertificatePem: oldCert,
		DaemonCaPem: keys.DaemonCAPEM, GatewaySigningPublicKey: signingKey,
		ExpiresAt: certificate.NotAfter.UTC().Format(time.RFC3339Nano), Generation: 2, GatewayIssuer: issuer,
	}
	path := filepath.Join(root, "daemon", "identity.json")
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	assertUnchanged := func() {
		t.Helper()
		current, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(current, original) {
			t.Fatalf("replacement credential changed on failure: %v", err)
		}
	}
	for _, args := range [][]string{
		{"daemon", "recover", "--help"},
		{"daemon", "recover", "--old-id", oldID},
		{"daemon", "recover", "--old-id", replacementID, "--confirm", "RECOVER"},
	} {
		output.Reset()
		err := client.Run(args)
		if args[2] == "--help" {
			if err != nil || !strings.Contains(output.String(), "--confirm RECOVER") {
				t.Fatalf("offline help: %v, %q", err, output.String())
			}
		} else if err == nil {
			t.Fatalf("unexpected success: %v", args)
		}
		assertUnchanged()
	}
	client.Machine = "another-machine"
	if err := client.Run([]string{"daemon", "recover", "--old-id", oldID, "--confirm", "RECOVER"}); err == nil || !strings.Contains(err.Error(), "local-only") {
		t.Fatalf("remote recovery error: %v", err)
	}
	client.Machine = ""
	if stub.calls != 0 {
		t.Fatalf("gateway contacted for invalid arguments: %d", stub.calls)
	}
	stub.recover = func(request *gatewayv1.RecoverDaemonRequest) (*gatewayv1.DaemonCredential, error) {
		if request.GetRevokedDaemonId() != oldID || request.GetReplacementDaemonId() != replacementID || len(request.GetNonce()) != 32 || len(request.GetSignature()) != 64 ||
			request.GetRevokedGeneration() != 2 || request.GetReplacementGeneration() != identity.Generation {
			t.Fatalf("invalid recovery proof envelope: %+v", request)
		}
		if err := linkauth.VerifyRecovery(replacementCert, issuer, oldID, replacementID, request.GetRevokedGeneration(), request.GetReplacementGeneration(), request.GetNonce(), request.GetSignature()); err != nil {
			t.Fatalf("recovery signature invalid: %v", err)
		}
		if err := linkauth.VerifyRecovery(replacementCert, issuer, oldID, replacementID, request.GetRevokedGeneration()+1, request.GetReplacementGeneration(), request.GetNonce(), request.GetSignature()); err == nil {
			t.Fatal("recovery signature can be reused after another revocation")
		}
		if err := linkauth.VerifyRecovery(replacementCert, issuer, oldID, replacementID, request.GetRevokedGeneration(), request.GetReplacementGeneration()+1, request.GetNonce(), request.GetSignature()); err == nil {
			t.Fatal("recovery signature can be reused with another replacement generation")
		}
		return nil, errors.New("gateway response lost")
	}
	args := []string{"daemon", "recover", "--old-id", oldID, "--confirm", "RECOVER"}
	if err := client.Run(args); err == nil || !strings.Contains(err.Error(), "retry is safe") {
		t.Fatalf("gateway response loss: %v", err)
	}
	assertUnchanged()
	for _, tc := range []struct {
		name  string
		state *gatewayv1.DaemonRecoveryState
	}{
		{"unrevoked original", &gatewayv1.DaemonRecoveryState{RevokedGeneration: 1, ReplacementGeneration: identity.Generation}},
		{"stale replacement", &gatewayv1.DaemonRecoveryState{RevokedGeneration: 2, ReplacementGeneration: identity.Generation + 1}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stub.inspect = func(*gatewayv1.DaemonRecoveryRef) (*gatewayv1.DaemonRecoveryState, error) { return tc.state, nil }
			before := stub.calls
			if err := client.Run(args); err == nil || !strings.Contains(err.Error(), "generations") {
				t.Fatalf("invalid recovery state accepted: %v", err)
			}
			if stub.calls != before {
				t.Fatal("signed recovery attempted for invalid generation")
			}
			assertUnchanged()
		})
	}
	stub.inspect = func(*gatewayv1.DaemonRecoveryRef) (*gatewayv1.DaemonRecoveryState, error) {
		return &gatewayv1.DaemonRecoveryState{RevokedGeneration: 2, ReplacementGeneration: identity.Generation}, nil
	}
	for _, tc := range []struct {
		name   string
		mutate func(*gatewayv1.DaemonCredential)
	}{
		{"wrong ID", func(c *gatewayv1.DaemonCredential) { c.DaemonId = "d_other" }},
		{"wrong generation", func(c *gatewayv1.DaemonCredential) { c.Generation = 1 }},
		{"future generation", func(c *gatewayv1.DaemonCredential) { c.Generation = 3 }},
		{"wrong issuer", func(c *gatewayv1.DaemonCredential) { c.GatewayIssuer = "https://other.example.test" }},
		{"wrong certificate", func(c *gatewayv1.DaemonCredential) { c.CertificatePem = replacementCert }},
		{"missing CA", func(c *gatewayv1.DaemonCredential) { c.DaemonCaPem = nil }},
		{"missing signing key", func(c *gatewayv1.DaemonCredential) { c.GatewaySigningPublicKey = nil }},
		{"different CA", func(c *gatewayv1.DaemonCredential) {
			c.CertificatePem, c.DaemonCaPem = otherCACert, otherKeys.DaemonCAPEM
		}},
		{"foreign certificate under pinned CA", func(c *gatewayv1.DaemonCredential) { c.CertificatePem = otherCACert }},
		{"different signing key", func(c *gatewayv1.DaemonCredential) { c.GatewaySigningPublicKey = otherSigningKey }},
		{"wrong key", func(c *gatewayv1.DaemonCredential) { c.CertificatePem = otherKeyCert }},
		{"expired metadata", func(c *gatewayv1.DaemonCredential) { c.ExpiresAt = time.Now().Add(-time.Hour).Format(time.RFC3339Nano) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stub.recover = func(*gatewayv1.RecoverDaemonRequest) (*gatewayv1.DaemonCredential, error) {
				invalid := proto.Clone(credential).(*gatewayv1.DaemonCredential)
				tc.mutate(invalid)
				return invalid, nil
			}
			if err := client.Run(args); err == nil || !strings.Contains(err.Error(), "invalid recovered credential") {
				t.Fatalf("bad gateway response accepted: %v", err)
			}
			assertUnchanged()
		})
	}
	stub.recover = func(*gatewayv1.RecoverDaemonRequest) (*gatewayv1.DaemonCredential, error) { return credential, nil }
	output.Reset()
	if err := client.Run(args); err != nil {
		t.Fatal(err)
	}
	loaded, err := dieterdaemon.LoadIdentity(root)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.ID != oldID || loaded.Generation != 2 || loaded.Name != "Original" || !bytes.Equal(loaded.CertificatePEM, oldCert) || !loaded.PublicKey.Equal(identity.PublicKey) {
		t.Fatalf("recovered identity mismatch: %+v", loaded)
	}
	if text := output.String(); !strings.Contains(text, oldID) || !strings.Contains(text, replacementID) || !strings.Contains(text, "Restart the daemon service") || !strings.Contains(text, "verify") || !strings.Contains(text, "dieter machine revoke "+replacementID) {
		t.Fatalf("recovery guidance missing: %q", text)
	}
}

func TestDaemonRecoverThroughGatewayRestoresOriginalIdentity(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	origin, _ := url.Parse("http://" + listener.Addr().String())
	config := gateway.Config{
		Root: t.TempDir(), Address: listener.Addr().String(), PublicURL: origin,
		GitHubClientID: "test", GitHubSecret: "test", AllowedUserIDs: map[int64]struct{}{42: {}},
		AuthSecret: []byte("0123456789abcdef0123456789abcdef"), SessionTTL: time.Hour,
		NativeRedirects: map[string]struct{}{}, GitHubBaseURL: "https://github.invalid",
		GitHubAPIURL: "https://api.github.invalid", DevInsecure: true,
	}
	gatewayStore, err := gateway.OpenStore(config.Root)
	if err != nil {
		t.Fatal(err)
	}
	defer gatewayStore.Close()
	server, err := gateway.NewServer(config, gatewayStore, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = server.Serve(listener) }()
	defer server.APIGRPC.Stop()
	defer server.RelayGRPC.Stop()

	root := t.TempDir()
	identity, err := dieterdaemon.LoadOrCreateEnrollmentIdentity(root, "Original", origin.String())
	if err != nil {
		t.Fatal(err)
	}
	enroll := func() *gatewayv1.DaemonCredential {
		t.Helper()
		request, err := dieterdaemon.BeginEnrollment(context.Background(), identity)
		if err != nil {
			t.Fatal(err)
		}
		if err := gatewayStore.ApproveEnrollment(request.GetEnrollmentId(), request.GetUserCode(), 42, "owner"); err != nil {
			t.Fatal(err)
		}
		credential, err := dieterdaemon.CompleteEnrollment(context.Background(), identity, request.GetEnrollmentId(), request.GetEnrollmentSecret())
		if err != nil {
			t.Fatal(err)
		}
		identity.GatewayIssuer = credential.GetGatewayIssuer()
		if err := identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetDaemonCaPem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); err != nil {
			t.Fatal(err)
		}
		return credential
	}
	original := enroll()
	if _, err := gatewayStore.RevokeDaemon(original.GetDaemonId(), 42); err != nil {
		t.Fatal(err)
	}
	if err := identity.ClearCredential(); err != nil {
		t.Fatal(err)
	}
	replacement := enroll()
	if original.GetDaemonId() == replacement.GetDaemonId() {
		t.Fatal("reenrollment reused the original ID")
	}
	client := New(store.New(root))
	defer client.Close()
	var output bytes.Buffer
	client.Out, client.Err = &output, &output
	if err := client.Run([]string{"daemon", "recover", "--old-id", original.GetDaemonId(), "--confirm", "RECOVER"}); err != nil {
		t.Fatal(err)
	}
	recovered, err := dieterdaemon.LoadIdentity(root)
	if err != nil || recovered.ID != original.GetDaemonId() || recovered.Generation != original.GetGeneration()+1 ||
		!bytes.Equal(recovered.CertificatePEM, original.GetCertificatePem()) {
		t.Fatalf("local original identity not restored: %+v: %v", recovered, err)
	}
	oldRecord, err := gatewayStore.Daemon(original.GetDaemonId())
	if err != nil || oldRecord.Revoked || oldRecord.Generation != recovered.Generation {
		t.Fatalf("gateway original identity not restored: %+v: %v", oldRecord, err)
	}
	newRecord, err := gatewayStore.Daemon(replacement.GetDaemonId())
	if err != nil || newRecord.Revoked {
		t.Fatalf("replacement revoked before verification: %+v: %v", newRecord, err)
	}
	client.Close()
	reconnected := New(store.New(root))
	defer reconnected.Close()
	reconnected.Out, reconnected.Err = &output, &output
	output.Reset()
	if err := reconnected.Run([]string{"machine", "list", "--format", "jsonl"}); err != nil ||
		!strings.Contains(output.String(), original.GetDaemonId()) ||
		!strings.Contains(output.String(), replacement.GetDaemonId()) {
		t.Fatalf("restored credential cannot access gateway directory: %v, %q", err, output.String())
	}
}
