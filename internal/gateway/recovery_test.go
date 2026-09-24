package gateway

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"io"
	"log/slog"
	"math/big"
	"net/url"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const recoveryOwner int64 = 701

type recoveryFixture struct {
	store       *Store
	service     *Service
	old         DaemonRecord
	replacement DaemonRecord
	private     ed25519.PrivateKey
	ctx         context.Context
}

func newRecoveryFixture(t *testing.T) *recoveryFixture {
	t.Helper()
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	keys, err := LoadOrCreateKeys(store.Root)
	if err != nil {
		t.Fatal(err)
	}
	issuer, _ := url.Parse("https://gateway.example")
	config := Config{IssuerURL: issuer, PublicURL: issuer, AllowedUserIDs: map[int64]struct{}{recoveryOwner: {}, 702: {}}}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	service := NewService(store, NewAuth(config, store, logger), keys, NewHub(store, config), config)
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	fixture := &recoveryFixture{store: store, service: service, private: private,
		ctx: context.WithValue(context.Background(), principalKey{}, Principal{GitHubID: recoveryOwner})}
	fixture.old = fixture.insert(t, "d_original", recoveryOwner, der, 2, true)
	fixture.replacement = fixture.insert(t, "d_replacement", recoveryOwner, der, 1, false)
	return fixture
}

func (f *recoveryFixture) insert(t *testing.T, id string, owner int64, der []byte, generation uint64, revoked bool) DaemonRecord {
	t.Helper()
	certificate, _, err := f.service.keys.IssueDaemonCertificate(id, der)
	if err != nil {
		t.Fatal(err)
	}
	revokedInt := 0
	if revoked {
		revokedInt = 1
	}
	_, err = f.store.DB.Exec(`INSERT INTO daemons (id, name, github_id, login, public_key, certificate, generation, revoked, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, id, owner, "owner", der, certificate, generation, revokedInt, time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		t.Fatal(err)
	}
	record, err := f.store.Daemon(id)
	if err != nil {
		t.Fatal(err)
	}
	return record
}

func (f *recoveryFixture) request() *gatewayv1.RecoverDaemonRequest {
	nonce := bytes.Repeat([]byte{37}, 32)
	return &gatewayv1.RecoverDaemonRequest{RevokedDaemonId: f.old.ID, ReplacementDaemonId: f.replacement.ID,
		RevokedGeneration: f.old.Generation, ReplacementGeneration: f.replacement.Generation,
		Nonce: nonce, Signature: linkauth.SignRecovery(f.private, f.service.config.IdentityOrigin(), f.old.ID, f.replacement.ID, f.old.Generation, f.replacement.Generation, nonce)}
}

func TestInspectDaemonRecoveryReturnsCurrentGenerationsWithoutMutation(t *testing.T) {
	f := newRecoveryFixture(t)
	ref := &gatewayv1.DaemonRecoveryRef{RevokedDaemonId: f.old.ID, ReplacementDaemonId: f.replacement.ID}
	for _, revoked := range []bool{true, false} {
		revision := f.service.hub.revision.Load()
		state, err := f.service.InspectDaemonRecovery(f.ctx, ref)
		if err != nil {
			t.Fatal(err)
		}
		if state.GetRevokedGeneration() != f.old.Generation || state.GetReplacementGeneration() != f.replacement.Generation {
			t.Fatalf("inspection = %+v", state)
		}
		old, err := f.store.Daemon(f.old.ID)
		if err != nil || old.Revoked != revoked || old.Generation != f.old.Generation {
			t.Fatalf("inspection changed original: %+v: %v", old, err)
		}
		replacement, err := f.store.Daemon(f.replacement.ID)
		if err != nil || replacement.Revoked || replacement.Generation != f.replacement.Generation {
			t.Fatalf("inspection changed replacement: %+v: %v", replacement, err)
		}
		if got := f.service.hub.revision.Load(); got != revision {
			t.Fatalf("inspection signaled directory change: %d != %d", got, revision)
		}
		if revoked {
			if _, err := f.service.RecoverDaemon(f.ctx, f.request()); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestInspectDaemonRecoveryRejectsIneligibleWithoutMutation(t *testing.T) {
	cases := []struct {
		name   string
		change func(*testing.T, *recoveryFixture, *gatewayv1.DaemonRecoveryRef) context.Context
		code   codes.Code
	}{
		{"no principal", func(_ *testing.T, _ *recoveryFixture, _ *gatewayv1.DaemonRecoveryRef) context.Context {
			return context.Background()
		}, codes.Unauthenticated},
		{"wrong owner", func(_ *testing.T, _ *recoveryFixture, _ *gatewayv1.DaemonRecoveryRef) context.Context {
			return context.WithValue(context.Background(), principalKey{}, Principal{GitHubID: 702})
		}, codes.NotFound},
		{"identical IDs", func(_ *testing.T, f *recoveryFixture, ref *gatewayv1.DaemonRecoveryRef) context.Context {
			ref.ReplacementDaemonId = f.old.ID
			return f.ctx
		}, codes.InvalidArgument},
		{"first generation", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.DaemonRecoveryRef) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET generation=1 WHERE id=?`, f.old.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"revoked replacement", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.DaemonRecoveryRef) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET revoked=1 WHERE id=?`, f.replacement.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"different key", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.DaemonRecoveryRef) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET public_key=? WHERE id=?`, []byte("other key"), f.replacement.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"invalid certificate", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.DaemonRecoveryRef) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET certificate=? WHERE id=?`, []byte("invalid"), f.old.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newRecoveryFixture(t)
			ref := &gatewayv1.DaemonRecoveryRef{RevokedDaemonId: f.old.ID, ReplacementDaemonId: f.replacement.ID}
			ctx := tc.change(t, f, ref)
			oldBefore, err := f.store.Daemon(f.old.ID)
			if err != nil {
				t.Fatal(err)
			}
			replacementBefore, err := f.store.Daemon(f.replacement.ID)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := f.service.InspectDaemonRecovery(ctx, ref); status.Code(err) != tc.code {
				t.Fatalf("inspection error = %v, want %v", err, tc.code)
			}
			oldAfter, err := f.store.Daemon(f.old.ID)
			if err != nil || oldAfter.Revoked != oldBefore.Revoked || oldAfter.Generation != oldBefore.Generation || !bytes.Equal(oldAfter.Certificate, oldBefore.Certificate) {
				t.Fatalf("inspection changed old: %+v: %v", oldAfter, err)
			}
			replacementAfter, err := f.store.Daemon(f.replacement.ID)
			if err != nil || replacementAfter.Revoked != replacementBefore.Revoked || replacementAfter.Generation != replacementBefore.Generation || !bytes.Equal(replacementAfter.PublicKey, replacementBefore.PublicKey) {
				t.Fatalf("inspection changed replacement: %+v: %v", replacementAfter, err)
			}
			if f.service.hub.revision.Load() != 0 {
				t.Fatal("inspection signaled directory change")
			}
		})
	}
}

func TestRecoverDaemonPreservesOriginalCredentialAndRetries(t *testing.T) {
	f := newRecoveryFixture(t)
	request := f.request()
	credential, err := f.service.RecoverDaemon(f.ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	if credential.GetDaemonId() != f.old.ID || credential.GetGeneration() != 2 || !bytes.Equal(credential.GetCertificatePem(), f.old.Certificate) {
		t.Fatalf("original credential not retained: %v", credential)
	}
	if got := f.service.hub.revision.Load(); got != 1 {
		t.Fatalf("directory revision = %d", got)
	}
	retry, err := f.service.RecoverDaemon(f.ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	if retry.GetGeneration() != 2 || !bytes.Equal(retry.GetCertificatePem(), credential.GetCertificatePem()) {
		t.Fatal("retry changed credential")
	}
	if got := f.service.hub.revision.Load(); got != 1 {
		t.Fatalf("retry signaled directory change: %d", got)
	}
	old, err := f.store.Daemon(f.old.ID)
	if err != nil || old.Revoked || old.Generation != 2 {
		t.Fatalf("old record = %+v: %v", old, err)
	}
	replacement, err := f.store.Daemon(f.replacement.ID)
	if err != nil || replacement.Revoked || replacement.Generation != 1 {
		t.Fatalf("replacement = %+v: %v", replacement, err)
	}
}

func TestRecoverDaemonRejectsStaleSignedProofAfterLaterRevocation(t *testing.T) {
	f := newRecoveryFixture(t)
	stale := f.request()
	if _, err := f.service.RecoverDaemon(f.ctx, stale); err != nil {
		t.Fatal(err)
	}
	if _, err := f.service.RevokeDaemon(f.ctx, &gatewayv1.DaemonRef{DaemonId: f.old.ID}); err != nil {
		t.Fatal(err)
	}
	revision := f.service.hub.revision.Load()
	if _, err := f.service.RecoverDaemon(f.ctx, stale); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("stale recovery error = %v, want FailedPrecondition", err)
	}
	// Even a request that claims the new generation cannot reuse the old
	// signature: the generation is part of the signed message.
	stale.RevokedGeneration++
	if _, err := f.service.RecoverDaemon(f.ctx, stale); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("relabelled proof error = %v, want Unauthenticated", err)
	}
	old, err := f.store.Daemon(f.old.ID)
	if err != nil || !old.Revoked || old.Generation != 3 {
		t.Fatalf("later revocation changed by stale proof: %+v: %v", old, err)
	}
	if got := f.service.hub.revision.Load(); got != revision {
		t.Fatalf("stale recovery signaled directory change: %d != %d", got, revision)
	}
}

func TestRecoverDaemonRejectsUnauthorizedAndMismatchedProofsWithoutMutation(t *testing.T) {
	cases := []struct {
		name   string
		change func(*testing.T, *recoveryFixture, *gatewayv1.RecoverDaemonRequest) context.Context
		code   codes.Code
	}{
		{"no principal", func(_ *testing.T, _ *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			return context.Background()
		}, codes.Unauthenticated},
		{"wrong owner", func(_ *testing.T, _ *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			return context.WithValue(context.Background(), principalKey{}, Principal{GitHubID: 702})
		}, codes.NotFound},
		{"owner removed from allowlist", func(_ *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			delete(f.service.config.AllowedUserIDs, recoveryOwner)
			return f.ctx
		}, codes.Unauthenticated},
		{"old identity owned by another account", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET github_id=702 WHERE id=?`, f.old.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.NotFound},
		{"replacement owned by another account", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET github_id=702 WHERE id=?`, f.replacement.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.NotFound},
		{"different enrolled key", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			public, _, err := ed25519.GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			der, err := x509.MarshalPKIXPublicKey(public)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := f.store.DB.Exec(`UPDATE daemons SET public_key=? WHERE id=?`, der, f.replacement.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"mismatched original generation", func(_ *testing.T, f *recoveryFixture, r *gatewayv1.RecoverDaemonRequest) context.Context {
			r.RevokedGeneration++
			return f.ctx
		}, codes.FailedPrecondition},
		{"mismatched replacement generation", func(_ *testing.T, f *recoveryFixture, r *gatewayv1.RecoverDaemonRequest) context.Context {
			r.ReplacementGeneration++
			return f.ctx
		}, codes.FailedPrecondition},
		{"original generation changed", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET generation=3 WHERE id=?`, f.old.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"replacement generation changed", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET generation=2 WHERE id=?`, f.replacement.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"invalid signature", func(_ *testing.T, f *recoveryFixture, r *gatewayv1.RecoverDaemonRequest) context.Context {
			r.Signature[0] ^= 1
			return f.ctx
		}, codes.Unauthenticated},
		{"revoked replacement", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET revoked=1 WHERE id=?`, f.replacement.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"old certificate key mismatch", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET certificate=? WHERE id=?`, f.replacement.Certificate, f.old.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"expired original certificate", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			uri, _ := url.Parse("spiffe://board/daemon/" + f.old.ID)
			template := &x509.Certificate{
				SerialNumber: big.NewInt(91), NotBefore: time.Now().Add(-48 * time.Hour), NotAfter: time.Now().Add(-24 * time.Hour),
				KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
				URIs: []*url.URL{uri},
			}
			der, err := x509.CreateCertificate(rand.Reader, template, f.service.keys.DaemonCA, f.private.Public(), f.service.keys.DaemonCAPrivate)
			if err != nil {
				t.Fatal(err)
			}
			certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
			if _, err := f.store.DB.Exec(`UPDATE daemons SET certificate=? WHERE id=?`, certificate, f.old.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"first generation", func(t *testing.T, f *recoveryFixture, _ *gatewayv1.RecoverDaemonRequest) context.Context {
			if _, err := f.store.DB.Exec(`UPDATE daemons SET generation=1 WHERE id=?`, f.old.ID); err != nil {
				t.Fatal(err)
			}
			return f.ctx
		}, codes.FailedPrecondition},
		{"identical IDs", func(_ *testing.T, f *recoveryFixture, r *gatewayv1.RecoverDaemonRequest) context.Context {
			r.ReplacementDaemonId = f.old.ID
			return f.ctx
		}, codes.InvalidArgument},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newRecoveryFixture(t)
			request := f.request()
			ctx := tc.change(t, f, request)
			oldBefore, err := f.store.Daemon(f.old.ID)
			if err != nil {
				t.Fatal(err)
			}
			replacementBefore, err := f.store.Daemon(f.replacement.ID)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := f.service.RecoverDaemon(ctx, request); status.Code(err) != tc.code {
				t.Fatalf("recovery error = %v, want %v", err, tc.code)
			}
			old, err := f.store.Daemon(f.old.ID)
			if err != nil || !old.Revoked || old.Generation != oldBefore.Generation {
				t.Fatalf("rejected recovery changed old record: %+v, %v", old, err)
			}
			replacement, err := f.store.Daemon(f.replacement.ID)
			if err != nil || replacement.Revoked != replacementBefore.Revoked || replacement.Generation != replacementBefore.Generation {
				t.Fatalf("rejected recovery changed replacement: %+v, %v", replacement, err)
			}
			if f.service.hub.revision.Load() != 0 {
				t.Fatal("rejected recovery signaled directory change")
			}
		})
	}
}

func TestRecoverDaemonStorageRejectsStaleReplacementAtomically(t *testing.T) {
	f := newRecoveryFixture(t)
	if _, err := f.store.DB.Exec(`UPDATE daemons SET revoked=1 WHERE id=?`, f.replacement.ID); err != nil {
		t.Fatal(err)
	}
	if _, changed, err := f.store.RecoverDaemon(f.old, f.replacement, recoveryOwner); err == nil || changed {
		t.Fatalf("stale recovery succeeded: changed=%v err=%v", changed, err)
	}
	old, err := f.store.Daemon(f.old.ID)
	if err != nil || !old.Revoked || old.Generation != 2 {
		t.Fatalf("partial mutation: %+v, %v", old, err)
	}
}
