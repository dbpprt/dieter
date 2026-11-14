package gateway

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const fcmTokenURL = "https://oauth2.googleapis.com/token"

// Credentials and bearer tokens stay in memory. Neither provider response bodies
// nor device tokens enter errors or logs. Endpoints are fixed, not credential-controlled.
type fcmSender struct {
	key            *rsa.PrivateKey
	project, email string
	client         *http.Client
	mu             sync.Mutex
	bearer         string
	expires        time.Time
}

func newFCMSender(config Config) (*fcmSender, error) {
	if config.FCMServiceAccountFile == "" && config.FCMServiceAccountBase64 == "" {
		return nil, nil
	}
	if (config.FCMServiceAccountFile != "" && config.FCMServiceAccountBase64 != "") || len(config.FCMServiceAccountBase64) > 32768 {
		return nil, errors.New("invalid FCM credential configuration")
	}
	var encoded []byte
	var err error
	if config.FCMServiceAccountBase64 != "" {
		encoded, err = base64.StdEncoding.DecodeString(config.FCMServiceAccountBase64)
	} else {
		var file *os.File
		file, err = os.Open(config.FCMServiceAccountFile)
		if err == nil {
			defer file.Close()
			encoded, err = io.ReadAll(io.LimitReader(file, 24577))
		}
	}
	if err != nil || len(encoded) > 24576 {
		return nil, errors.New("read FCM service account")
	}
	var account struct {
		Type    string `json:"type"`
		Project string `json:"project_id"`
		Email   string `json:"client_email"`
		Key     string `json:"private_key"`
	}
	if json.Unmarshal(encoded, &account) != nil || account.Type != "service_account" ||
		!regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`).MatchString(account.Project) ||
		!regexp.MustCompile(`^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+\.iam\.gserviceaccount\.com$`).MatchString(account.Email) {
		return nil, errors.New("invalid FCM service account")
	}
	block, _ := pem.Decode([]byte(account.Key))
	if block == nil {
		return nil, errors.New("invalid FCM private key PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("invalid FCM PKCS8 private key")
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok || key.N.BitLen() < 2048 || key.N.BitLen() > 4096 {
		return nil, errors.New("FCM requires an RSA key of 2048–4096 bits")
	}
	return &fcmSender{key: key, project: account.Project, email: account.Email,
		client: &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
			Transport: &http.Transport{ForceAttemptHTTP2: true, MaxConnsPerHost: 2, MaxIdleConns: 2, IdleConnTimeout: time.Minute}}}, nil
}

func (s *fcmSender) token(ctx context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if s.bearer != "" && now.Add(time.Minute).Before(s.expires) {
		return s.bearer, nil
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{"iss": s.email, "scope": "https://www.googleapis.com/auth/firebase.messaging", "aud": fcmTokenURL, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()})
	unsigned := header + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(unsigned))
	signature, err := rsa.SignPKCS1v15(rand.Reader, s.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", errors.New("FCM assertion signing failed")
	}
	assertion := unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, fcmTokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	request.Header.Set("content-type", "application/x-www-form-urlencoded")
	response, err := s.client.Do(request)
	if err != nil {
		return "", errors.New("FCM authentication transport failed")
	}
	defer response.Body.Close()
	var token struct {
		Access  string `json:"access_token"`
		Type    string `json:"token_type"`
		Expires int    `json:"expires_in"`
	}
	if response.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(response.Body, 16384)).Decode(&token) != nil ||
		token.Access == "" || len(token.Access) > 8192 || !strings.EqualFold(token.Type, "Bearer") || token.Expires < 120 || token.Expires > 3600 || strings.ContainsAny(token.Access, "\r\n") {
		return "", errors.New("FCM authentication rejected")
	}
	s.bearer, s.expires = token.Access, now.Add(time.Duration(token.Expires)*time.Second)
	return s.bearer, nil
}

func (s *fcmSender) Send(ctx context.Context, session Session, badge int, sealed []byte) (bool, error) {
	bearer, err := s.token(ctx)
	if err != nil {
		return false, err
	}
	data := map[string]string{"dieter_badge": strconv.Itoa(badge)}
	android := map[string]any{"priority": "normal", "ttl": "3600s"}
	message := map[string]any{"token": session.PushToken, "data": data, "android": android}
	if len(sealed) > 0 {
		// Notification+data lets Google Play services display an alert while
		// Android has stopped the process. Only the encrypted link reaches FCM.
		data["dieter_sealed"] = base64.StdEncoding.EncodeToString(sealed)
		message["notification"] = map[string]string{"title": "Task needs you", "body": "Open Dieter to view the task requiring your attention."}
		android["priority"] = "high"
		android["notification"] = map[string]any{"channel_id": "dieter.attention", "icon": "ic_notification", "notification_count": badge, "default_sound": true, "tag": "dieter.attention.remote." + data["dieter_sealed"]}
	}
	body, _ := json.Marshal(map[string]any{"message": message})
	if len(body) > 4096 {
		return false, errors.New("FCM payload exceeds provider limit")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://fcm.googleapis.com/v1/projects/"+s.project+"/messages:send", bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	request.Header.Set("authorization", "Bearer "+bearer)
	request.Header.Set("content-type", "application/json")
	response, err := s.client.Do(request)
	if err != nil {
		return false, errors.New("FCM delivery transport failed")
	}
	defer response.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(response.Body, 8192))
	if response.StatusCode == http.StatusOK {
		return false, nil
	}
	if response.StatusCode == http.StatusUnauthorized {
		s.mu.Lock()
		if s.bearer == bearer {
			s.bearer = ""
		}
		s.mu.Unlock()
	}
	var failure struct {
		Error struct {
			Details []struct {
				Type string `json:"@type"`
				Code string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	_ = json.Unmarshal(raw, &failure)
	invalid := false
	for _, detail := range failure.Error.Details {
		if response.StatusCode == http.StatusNotFound && detail.Type == "type.googleapis.com/google.firebase.fcm.v1.FcmError" && detail.Code == "UNREGISTERED" {
			invalid = true
		}
	}
	return invalid, fmt.Errorf("FCM rejected delivery (%d)", response.StatusCode)
}
