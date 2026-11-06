package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/security/linkauth"
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
	t.Parallel()
	const issuer = "https://issuer.example.test"
	const oldID = "d_original"
	const replacementID = "d_replacement"
	root := t.TempDir()
	identity, err := link.LoadOrCreateEnrollmentIdentity(root, "Replacement", issuer)
	if err != nil {
		t.Fatal(err)
	}
	publicDER, err := identity.PublicKeyDER()
	if err != nil {
		t.Fatal(err)
	}
	replacementCert := testEnrollmentCertificate(t, replacementID, publicDER)
	oldCert := testEnrollmentCertificate(t, oldID, publicDER)
	block, _ := pem.Decode(oldCert)
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	signingKey, otherSigningKey := testSigningKeyPEM(t), testSigningKeyPEM(t)
	otherIdentity, err := link.LoadOrCreateEnrollmentIdentity(t.TempDir(), "Other", issuer)
	if err != nil {
		t.Fatal(err)
	}
	otherPublicDER, err := otherIdentity.PublicKeyDER()
	if err != nil {
		t.Fatal(err)
	}
	otherKeyCert := testEnrollmentCertificate(t, oldID, otherPublicDER)
	identity.GatewayIssuer = issuer
	if err := identity.SaveCredential(replacementID, "Replacement", replacementCert, signingKey, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}
	client := New(root)
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
		GatewaySigningPublicKey: signingKey,
		ExpiresAt:               certificate.NotAfter.UTC().Format(time.RFC3339Nano), Generation: 2, GatewayIssuer: issuer,
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
		{"missing signing key", func(c *gatewayv1.DaemonCredential) { c.GatewaySigningPublicKey = nil }},
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
	loaded, err := link.LoadIdentity(root)
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

// testEnrollmentCertificate is a gateway enrollment certificate for id and
// public, as the gateway issues one; only the gateway ever checks its issuer.
func testEnrollmentCertificate(t *testing.T, id string, publicDER []byte) []byte {
	t.Helper()
	public, err := x509.ParsePKIXPublicKey(publicDER)
	if err != nil {
		t.Fatal(err)
	}
	_, issuer, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: id},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour).Truncate(time.Second),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, public, issuer)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func testSigningKeyPEM(t *testing.T) []byte {
	t.Helper()
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})
}
