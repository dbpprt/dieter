package gateway

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

type apnsSender struct {
	key                  *ecdsa.PrivateKey
	keyID, teamID, topic string
	client               *http.Client
	mu                   sync.Mutex
	bearer               string
	issued               time.Time
}

func newAPNSSender(config Config) (*apnsSender, error) {
	if config.APNSKeyFile == "" && config.APNSKeyBase64 == "" {
		return nil, nil
	}
	var encoded []byte
	var err error
	if config.APNSKeyBase64 != "" {
		encoded, err = base64.StdEncoding.DecodeString(config.APNSKeyBase64)
	} else {
		encoded, err = os.ReadFile(config.APNSKeyFile)
	}
	if err != nil {
		return nil, errors.New("read APNs signing key")
	}
	block, _ := pem.Decode(encoded)
	if block == nil {
		return nil, errors.New("invalid APNs signing key PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("invalid APNs PKCS8 signing key")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() || config.APNSKeyID == "" || config.APNSTeamID == "" {
		return nil, errors.New("APNs requires a P-256 key, key ID and team ID")
	}
	topic := config.APNSTopic
	if topic == "" {
		topic = buildinfo.BundlePrefix + ".ios"
	}
	return &apnsSender{key: key, keyID: config.APNSKeyID, teamID: config.APNSTeamID, topic: topic,
		client: &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }, Transport: &http.Transport{ForceAttemptHTTP2: true, MaxConnsPerHost: 2, MaxIdleConns: 2, IdleConnTimeout: time.Minute}},
	}, nil
}

func (s *apnsSender) token() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if s.bearer != "" && now.Sub(s.issued) < 50*time.Minute {
		return s.bearer, nil
	}
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": s.keyID})
	claims, _ := json.Marshal(map[string]any{"iss": s.teamID, "iat": now.Unix()})
	unsigned := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(unsigned))
	r, v, err := ecdsa.Sign(rand.Reader, s.key, digest[:])
	if err != nil {
		return "", err
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	v.FillBytes(signature[32:])
	s.bearer = unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
	s.issued = now
	return s.bearer, nil
}

// Invalid routes are removed only for APNs's explicit token errors. Neither
// response bodies nor tokens enter logs, and requests never follow redirects.
func (s *apnsSender) Send(ctx context.Context, session Session, badge int, sealed []byte) (bool, error) {
	bearer, err := s.token()
	if err != nil {
		return false, err
	}
	aps := map[string]any{"badge": badge}
	payload := map[string]any{"aps": aps}
	if len(sealed) > 0 {
		aps["alert"] = map[string]string{"title": "Task needs you", "body": "Open Dieter to view the task requiring your attention."}
		aps["sound"] = "default"
		aps["thread-id"] = "dieter.attention"
		payload["dieter_sealed"] = base64.StdEncoding.EncodeToString(sealed)
	}
	body, _ := json.Marshal(payload)
	endpoint := "https://api.push.apple.com"
	if session.PushSandbox {
		endpoint = "https://api.sandbox.push.apple.com"
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/3/device/"+session.PushToken, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	request.Header.Set("authorization", "bearer "+bearer)
	request.Header.Set("apns-topic", s.topic)
	request.Header.Set("apns-push-type", "alert")
	request.Header.Set("apns-priority", "5")
	if len(sealed) > 0 {
		request.Header.Set("apns-priority", "10")
	}
	request.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(time.Hour).Unix()))
	request.Header.Set("content-type", "application/json")
	response, err := s.client.Do(request)
	if err != nil {
		return false, errors.New("APNs transport failed")
	}
	defer response.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
	if response.StatusCode == http.StatusOK {
		return false, nil
	}
	var failure struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(raw, &failure)
	invalid := response.StatusCode == http.StatusGone || failure.Reason == "BadDeviceToken" || failure.Reason == "DeviceTokenNotForTopic"
	return invalid, fmt.Errorf("APNs rejected delivery (%d)", response.StatusCode)
}
