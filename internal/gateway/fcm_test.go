package gateway

import (
	"context"
	"crypto"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestFCMSignsOAuthAssertionAndSendsOpaqueBackgroundAlert(t *testing.T) {
	t.Parallel()
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	account, _ := json.Marshal(map[string]string{"type": "service_account", "project_id": "test-project", "client_email": "push@test-project.iam.gserviceaccount.com", "private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), "token_uri": "https://attacker.invalid"})
	sender, err := newFCMSender(Config{FCMServiceAccountBase64: base64.StdEncoding.EncodeToString(account)})
	if err != nil {
		t.Fatal(err)
	}
	authCalls, deliveries := 0, 0
	sender.client = &http.Client{Transport: pushRoundTrip(func(request *http.Request) (*http.Response, error) {
		if request.URL.String() == fcmTokenURL {
			authCalls++
			if err := request.ParseForm(); err != nil {
				t.Fatal(err)
			}
			jwt := strings.Split(request.Form.Get("assertion"), ".")
			if len(jwt) != 3 {
				t.Fatal("missing assertion")
			}
			signature, _ := base64.RawURLEncoding.DecodeString(jwt[2])
			digest := sha256.Sum256([]byte(jwt[0] + "." + jwt[1]))
			if rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, digest[:], signature) != nil {
				t.Fatal("invalid assertion signature")
			}
			claimsRaw, _ := base64.RawURLEncoding.DecodeString(jwt[1])
			var claims map[string]any
			_ = json.Unmarshal(claimsRaw, &claims)
			if claims["aud"] != fcmTokenURL || claims["scope"] != "https://www.googleapis.com/auth/firebase.messaging" {
				t.Fatal("incorrect assertion audience/scope")
			}
			return pushResponse(200, `{"access_token":"bearer-test","token_type":"Bearer","expires_in":3600}`), nil
		}
		if request.URL.String() != "https://fcm.googleapis.com/v1/projects/test-project/messages:send" || request.Header.Get("authorization") != "Bearer bearer-test" {
			t.Fatal("wrong FCM endpoint or auth")
		}
		deliveries++
		var body struct {
			Message struct {
				Token        string            `json:"token"`
				Data         map[string]string `json:"data"`
				Notification map[string]string `json:"notification"`
				Android      struct {
					Priority     string         `json:"priority"`
					Notification map[string]any `json:"notification"`
				} `json:"android"`
			} `json:"message"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body.Message.Token != "CaseSensitive_FCM:token" || body.Message.Data["dieter_badge"] != "3" {
			t.Fatal("route/count changed")
		}
		if deliveries == 1 {
			if body.Message.Data["dieter_sealed"] != base64.StdEncoding.EncodeToString([]byte("encrypted-link")) || body.Message.Notification["title"] != "Task needs you" || body.Message.Android.Priority != "high" || body.Message.Android.Notification["channel_id"] != "dieter.attention" {
				t.Fatal("missing background notification or sealed destination")
			}
			return pushResponse(200, `{"name":"message"}`), nil
		}
		if len(body.Message.Notification) != 0 || body.Message.Android.Priority != "normal" {
			t.Fatal("badge-only update alerted")
		}
		return pushResponse(404, `{"error":{"details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"UNREGISTERED"}]}}`), nil
	})}
	session := Session{PushToken: "CaseSensitive_FCM:token"}
	if invalid, err := sender.Send(t.Context(), session, 3, []byte("encrypted-link")); err != nil || invalid {
		t.Fatalf("send: %v %v", invalid, err)
	}
	if invalid, err := sender.Send(t.Context(), session, 3, nil); err == nil || !invalid {
		t.Fatal("unregistered token retained")
	}
	if authCalls != 1 || deliveries != 2 {
		t.Fatal("bearer was not cached")
	}
}

func pushResponse(code int, body string) *http.Response {
	return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}
}

type recordingPushSender struct{ calls int }

func (s *recordingPushSender) Send(context.Context, Session, int, []byte) (bool, error) {
	s.calls++
	return false, nil
}

func TestPushRoutesPreserveProviderAndFCMTokenCase(t *testing.T) {
	t.Parallel()
	store := pushTestStore(t)
	config := Config{PublicURL: &url.URL{Scheme: "https", Host: "gateway.example"}}
	hub := NewHub(store, config)
	apns, fcm := &recordingPushSender{}, &recordingPushSender{}
	providers := pushProviders{gatewayv1.PushProvider_APNS: apns}
	hub.push = newPushManager(store, providers, slog.Default())
	service := NewService(store, nil, nil, hub, config)
	key, _ := ecdh.X25519().GenerateKey(rand.Reader)
	token := strings.Repeat("AB", 32) // valid in both providers; case must survive FCM
	request := &gatewayv1.SetPushDeviceRequest{Provider: gatewayv1.PushProvider_FCM, Token: token, PublicKey: key.PublicKey().Bytes()}
	signPushRequest(t, service, request, 1)
	ctx := context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: 1, SessionHash: "one"})
	result, err := service.SetPushDevice(ctx, request)
	if err != nil || result.GetAvailable() {
		t.Fatal("unconfigured provider reported available", err)
	}
	if len(hub.push.destinations(1)) != 0 {
		t.Fatal("unconfigured provider offered to daemon")
	}
	providers[gatewayv1.PushProvider_FCM] = fcm
	result, err = service.SetPushDevice(ctx, request)
	if err != nil || !result.GetAvailable() {
		t.Fatal("FCM unavailable", err)
	}
	request.Provider = gatewayv1.PushProvider_APNS
	ctx2 := context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: 1, SessionHash: "two"})
	if _, err = service.SetPushDevice(ctx2, request); err != nil {
		t.Fatal(err)
	}
	sessions, _ := store.pushSessions(1)
	if len(sessions) != 2 {
		t.Fatal("same token in different providers collided")
	}
	for _, session := range sessions {
		if session.PushProvider == int32(gatewayv1.PushProvider_FCM) && session.PushToken != token {
			t.Fatal("FCM token lowercased")
		}
		if _, err := providers.Send(t.Context(), session, 1, nil); err != nil {
			t.Fatal(err)
		}
	}
	if apns.calls != 1 || fcm.calls != 1 {
		t.Fatal("cross-provider dispatch")
	}
	for _, provider := range []gatewayv1.PushProvider{99, gatewayv1.PushProvider_FCM} {
		request.Provider, request.Sandbox = provider, true
		if _, err = service.SetPushDevice(ctx, request); status.Code(err) != codes.InvalidArgument {
			t.Fatal("invalid provider/environment accepted")
		}
	}
	_ = store.UpdateAuthState(func(state *AuthState) error {
		for i := range state.Sessions {
			state.Sessions[i].ExpiresAt = time.Now().Add(-time.Second)
		}
		return nil
	})
	if len(hub.push.destinations(1)) != 0 {
		t.Fatal("expired route retained")
	}
}

func TestFCMDoesNotDeleteTokensForAuthenticationOrGenericPayloadErrors(t *testing.T) {
	t.Parallel()
	for _, body := range []string{`{"error":{"status":"INVALID_ARGUMENT"}}`, `{"error":{"status":"PERMISSION_DENIED"}}`} {
		sender := &fcmSender{project: "test-project", bearer: "cached", expires: time.Now().Add(time.Hour)}
		sender.client = &http.Client{Transport: pushRoundTrip(func(*http.Request) (*http.Response, error) { return pushResponse(400, body), nil })}
		if invalid, err := sender.Send(t.Context(), Session{}, 0, nil); invalid || err == nil {
			t.Fatal("configuration failure deleted route")
		}
	}
	if _, err := newFCMSender(Config{FCMServiceAccountBase64: "bad"}); err == nil {
		t.Fatal("bad credentials accepted")
	}
}
