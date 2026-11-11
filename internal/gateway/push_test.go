package gateway

import (
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/roster"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func TestNativePushRegistrationThroughAuthenticatedGRPC(t *testing.T) {
	t.Parallel()
	store := pushTestStore(t)
	config := Config{PublicURL: &url.URL{Scheme: "https", Host: "gateway.example"}, AllowedUserIDs: map[int64]struct{}{1: {}}, AuthSecret: []byte(strings.Repeat("a", 32)), SessionTTL: time.Hour, MinimumClientVersion: "0.6.0"}
	auth := NewAuth(config, store, slog.Default())
	token, _, err := auth.createSession(1, "owner")
	if err != nil {
		t.Fatal(err)
	}
	hub := NewHub(store, config)
	service := NewService(store, auth, nil, hub, config)
	server := grpc.NewServer(grpc.UnaryInterceptor(auth.UnaryInterceptor))
	gatewayv1.RegisterGatewayServiceServer(server, service)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	defer server.Stop()
	go func() { _ = server.Serve(listener) }()
	connection, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	client := gatewayv1.NewGatewayServiceClient(connection)
	key, _ := ecdh.X25519().GenerateKey(rand.Reader)
	request := &gatewayv1.SetPushDeviceRequest{DeviceId: "dv_fixture", Signature: make([]byte, 64), Token: strings.Repeat("ab", 32), PublicKey: key.PublicKey().Bytes()}
	signPushRequest(t, service, request, 1)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	unauth := metadata.AppendToOutgoingContext(ctx, "x-dieter-client-version", "0.6.0")
	if _, err := client.SetPushDevice(unauth, request); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("unprotected registration: %v", err)
	}
	native := metadata.AppendToOutgoingContext(unauth, "authorization", "Bearer "+token)
	if _, err := client.SetPushDevice(native, request); err != nil {
		t.Fatal(err)
	}
	sessions, _ := store.pushSessions(1)
	if len(sessions) != 1 {
		t.Fatal("native registration was not durable")
	}
	if _, err := client.SetPushDevice(native, &gatewayv1.SetPushDeviceRequest{}); err != nil {
		t.Fatal(err)
	}
	sessions, _ = store.pushSessions(1)
	if len(sessions) != 0 {
		t.Fatal("native unregister retained route")
	}
}

func TestAPNsSigningConfigurationParsesProtectedPKCS8AndRejectsWrongKeys(t *testing.T) {
	t.Parallel()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	encoded := base64.StdEncoding.EncodeToString(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	sender, err := newAPNSSender(Config{APNSKeyBase64: encoded, APNSKeyID: "ABCDEFGHIJ", APNSTeamID: "KLMNOPQRST"})
	if err != nil || sender == nil {
		t.Fatalf("valid APNs key rejected: %v", err)
	}
	wrong, _ := ecdh.X25519().GenerateKey(rand.Reader)
	der, _ = x509.MarshalPKCS8PrivateKey(wrong)
	encoded = base64.StdEncoding.EncodeToString(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	if _, err := newAPNSSender(Config{APNSKeyBase64: encoded, APNSKeyID: "ABCDEFGHIJ", APNSTeamID: "KLMNOPQRST"}); err == nil {
		t.Fatal("non-P256 key admitted")
	}
	if _, err := newAPNSSender(Config{APNSKeyBase64: "bad", APNSKeyID: "ABCDEFGHIJ", APNSTeamID: "KLMNOPQRST"}); err == nil {
		t.Fatal("bad PEM admitted")
	}
}

func pushTestStore(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	err = store.UpdateAuthState(func(state *AuthState) error {
		for _, item := range []struct {
			id      string
			account int64
		}{{"one", 1}, {"two", 1}, {"foreign", 2}} {
			state.Sessions = append(state.Sessions, Session{TokenHash: item.id, GitHubID: item.account, ExpiresAt: time.Now().Add(time.Hour)})
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func TestPushRegistrationIsBoundedAndNativeSessionBound(t *testing.T) {
	t.Parallel()
	store := pushTestStore(t)
	hub := NewHub(store, Config{})
	service := NewService(store, nil, nil, hub, Config{PublicURL: &url.URL{Scheme: "https", Host: "gateway.example"}})
	key, _ := ecdh.X25519().GenerateKey(rand.Reader)
	request := &gatewayv1.SetPushDeviceRequest{DeviceId: "dv_fixture", Signature: make([]byte, 64), Token: strings.Repeat("ab", 32), PublicKey: key.PublicKey().Bytes()}
	signPushRequest(t, service, request, 1)
	ctx := context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: 1, SessionHash: "one"})
	if _, err := service.SetPushDevice(context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: 1}), request); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("machine registered phone: %v", err)
	}
	reply, err := service.SetPushDevice(ctx, request)
	if err != nil || reply.GetAvailable() {
		t.Fatalf("disabled APNs: %v %v", reply, err)
	}
	sessions, _ := store.pushSessions(1)
	if len(sessions) != 1 || sessions[0].TokenHash != "one" {
		t.Fatal("registration missing")
	}
	foreign := context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: 2, SessionHash: "foreign"})
	signPushRequest(t, service, request, 2)
	if _, err := service.SetPushDevice(foreign, request); err != nil {
		t.Fatal(err)
	}
	sessions, _ = store.pushSessions(1)
	if len(sessions) != 0 {
		t.Fatal("old account kept route after device changed accounts")
	}
	request.PublicKey = make([]byte, 32)
	if _, err := service.SetPushDevice(ctx, request); status.Code(err) != codes.InvalidArgument {
		t.Fatal("low-order key accepted")
	}
	if _, err := service.SetPushDevice(foreign, &gatewayv1.SetPushDeviceRequest{PublicKey: make([]byte, 2048)}); err != nil {
		t.Fatal(err)
	}
	sessions, _ = store.pushSessions(2)
	if len(sessions) != 0 {
		t.Fatal("unregister retained route")
	}
	state, _ := store.AuthState()
	for _, session := range state.Sessions {
		if session.TokenHash == "foreign" && len(session.PushPublicKey) != 0 {
			t.Fatal("unregister retained unchecked key bytes")
		}
	}
}

func TestPushPresenceAggregatesOwnersWithoutCrossAccountDelivery(t *testing.T) {
	t.Parallel()
	store := pushTestStore(t)
	key, _ := ecdh.X25519().GenerateKey(rand.Reader)
	service := NewService(store, nil, nil, NewHub(store, Config{}), Config{PublicURL: &url.URL{Scheme: "https", Host: "gateway.example"}})
	for _, account := range []int64{1, 2} {
		request := &gatewayv1.SetPushDeviceRequest{PublicKey: key.PublicKey().Bytes()}
		signPushRequest(t, service, request, account)
		if err := store.UpdateAuthState(func(state *AuthState) error {
			for i := range state.Sessions {
				item := &state.Sessions[i]
				if item.GitHubID != account {
					continue
				}
				item.PushToken = strings.Repeat("a", 64)
				item.PushPublicKey = request.PublicKey
				item.PushDeviceID = request.DeviceId
				item.PushSignature = request.Signature
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []string{"a", "b"} {
		_, err := store.DB.Exec(`INSERT INTO daemons(id,name,github_id,login,public_key,certificate,created_at) VALUES(?,?,?,?,?,?,?)`, id, id, 1, "owner", []byte("key"), []byte("cert"), time.Now().Format(time.RFC3339Nano))
		if err != nil {
			t.Fatal(err)
		}
	}
	manager := newPushManager(store, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := manager.handle(DaemonRecord{ID: "a", GitHubID: 1}, &gatewayv1.AttentionPresence{Count: 2}); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if job := queuedPush(t, manager.queue); job.badge != 2 {
			t.Fatal("first owner count")
		}
	}
	if err := manager.handle(DaemonRecord{ID: "b", GitHubID: 1}, &gatewayv1.AttentionPresence{Count: 3, Alerts: []*gatewayv1.SealedAttention{{DestinationId: "one", Sealed: make([]byte, 80)}, {DestinationId: "foreign", Sealed: make([]byte, 80)}}}); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		job := queuedPush(t, manager.queue)
		if job.badge != 5 || job.account != 1 || job.session == "foreign" {
			t.Fatalf("wrong recipient or total: %+v", job)
		}
	}
	if len(manager.queue) != 0 {
		t.Fatal("foreign account received alert")
	}
	if err := manager.handle(DaemonRecord{ID: "a", GitHubID: 1}, &gatewayv1.AttentionPresence{Count: 100001}); err == nil {
		t.Fatal("unbounded count admitted")
	}
	if err := manager.handle(DaemonRecord{ID: "a", GitHubID: 1}, &gatewayv1.AttentionPresence{Alerts: []*gatewayv1.SealedAttention{{DestinationId: "one", Sealed: []byte("card")}}}); err == nil {
		t.Fatal("malformed envelope admitted")
	}
}

type pushRoundTrip func(*http.Request) (*http.Response, error)

func (f pushRoundTrip) RoundTrip(request *http.Request) (*http.Response, error) { return f(request) }

func TestAPNsUsesSignedHTTP2RequestAndOpaqueDestination(t *testing.T) {
	t.Parallel()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	sender := &apnsSender{key: key, keyID: "KEY", teamID: "TEAM", topic: "com.getdieter.ios"}
	calls := 0
	sender.client = &http.Client{Transport: pushRoundTrip(func(request *http.Request) (*http.Response, error) {
		calls++
		if request.URL.Host != "api.sandbox.push.apple.com" || request.Header.Get("apns-topic") != "com.getdieter.ios" || request.Header.Get("apns-push-type") != "alert" {
			t.Fatal("incorrect APNs routing")
		}
		jwt := strings.Split(strings.TrimPrefix(request.Header.Get("authorization"), "bearer "), ".")
		if len(jwt) != 3 {
			t.Fatal("missing provider JWT")
		}
		signature, _ := base64.RawURLEncoding.DecodeString(jwt[2])
		digest := sha256.Sum256([]byte(jwt[0] + "." + jwt[1]))
		if len(signature) != 64 || !ecdsa.Verify(&key.PublicKey, digest[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])) {
			t.Fatal("invalid ES256 provider signature")
		}
		raw, _ := io.ReadAll(request.Body)
		var payload map[string]any
		_ = json.Unmarshal(raw, &payload)
		if payload["dieter_sealed"] != base64.StdEncoding.EncodeToString([]byte("sealed")) {
			t.Fatal("destination envelope changed")
		}
		if calls == 1 {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{}}, nil
		}
		return &http.Response{StatusCode: 410, Body: io.NopCloser(strings.NewReader(`{"reason":"Unregistered"}`)), Header: http.Header{}}, nil
	})}
	session := Session{PushToken: strings.Repeat("ab", 32), PushSandbox: true}
	if invalid, err := sender.Send(t.Context(), session, 3, []byte("sealed")); invalid || err != nil {
		t.Fatalf("delivery: %t %v", invalid, err)
	}
	if invalid, err := sender.Send(t.Context(), session, 0, []byte("sealed")); !invalid || err == nil {
		t.Fatal("expired device route retained")
	}
}

func signPushRequest(t *testing.T, service *Service, request *gatewayv1.SetPushDeviceRequest, account int64) roster.Signer {
	t.Helper()
	signer := testClientDevice(t, "phone")
	genesis, err := roster.Genesis(roster.Account(service.config.IdentityOrigin(), account), signer)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.AppendDeviceRoster(principalContext(t, account), &gatewayv1.AppendDeviceRosterRequest{Entry: genesis}); err != nil {
		t.Fatal(err)
	}
	request.DeviceId = signer.Descriptor().DeviceId
	request.Signature, err = signer.Sign(roster.PushKeyBytes(genesis.Account, request.DeviceId, request.PublicKey))
	if err != nil {
		t.Fatal(err)
	}
	return signer
}

func queuedPush(t *testing.T, queue <-chan pushJob) pushJob {
	t.Helper()
	select {
	case job := <-queue:
		return job
	default:
		t.Fatal("expected a queued notification")
		return pushJob{}
	}
}

func TestRevokedPhoneStopsReceivingPushes(t *testing.T) {
	t.Parallel()
	store := pushTestStore(t)
	config := Config{PublicURL: &url.URL{Scheme: "https", Host: "gateway.example"}}
	service := NewService(store, nil, nil, NewHub(store, config), config)
	key, _ := ecdh.X25519().GenerateKey(rand.Reader)
	request := &gatewayv1.SetPushDeviceRequest{Token: strings.Repeat("ab", 32), PublicKey: key.PublicKey().Bytes()}
	phone := signPushRequest(t, service, request, 1)
	ctx := context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: 1, SessionHash: "one"})
	if _, err := service.SetPushDevice(ctx, request); err != nil {
		t.Fatal(err)
	}
	paired, _ := store.pushSessions(1)
	if len(paired) != 1 {
		t.Fatal("paired phone missing")
	}
	state, _, _, err := service.rosterSnapshot(1)
	if err != nil {
		t.Fatal(err)
	}
	backup := testClientDevice(t, "backup")
	added, err := state.Add(backup.Descriptor(), phone)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = service.AppendDeviceRoster(principalContext(t, 1), &gatewayv1.AppendDeviceRosterRequest{Entry: added}); err != nil {
		t.Fatal(err)
	}
	state, _, _, err = service.rosterSnapshot(1)
	if err != nil {
		t.Fatal(err)
	}
	revoked, err := state.Revoke(phone.Descriptor().DeviceId, backup)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = service.AppendDeviceRoster(principalContext(t, 1), &gatewayv1.AppendDeviceRosterRequest{Entry: revoked}); err != nil {
		t.Fatal(err)
	}
	paired, err = store.pushSessions(1)
	if err != nil || len(paired) != 0 {
		t.Fatalf("revoked phone kept delivery: %v %v", paired, err)
	}
	if _, err = service.SetPushDevice(ctx, request); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("revoked phone registered: %v", err)
	}
}
