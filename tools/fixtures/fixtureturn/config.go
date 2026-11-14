// Package fixtureturn loads explicitly selected TURN settings for disposable
// native-client fixtures. Production gateway and daemon code never import it.
package fixtureturn

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
)

type Config struct {
	URLs         []string `json:"urls"`
	SharedSecret string   `json:"sharedSecret"`
}

// Load is opt-in and accepts only a protected, bounded fixture file. Never use
// production TURN secrets: the fixture should target its own disposable coturn.
func Load() (*Config, error) {
	path := os.Getenv("DIETER_TEST_TURN_CONFIG")
	if path == "" {
		return nil, nil
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, errors.New("cannot open fixture TURN configuration")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || info.Size() > 65536 {
		return nil, errors.New("fixture TURN configuration must be a private regular file under 64 KiB")
	}
	decoder := json.NewDecoder(io.LimitReader(file, 65537))
	decoder.DisallowUnknownFields()
	var value Config
	if decoder.Decode(&value) != nil || decoder.Decode(new(any)) != io.EOF || len(value.URLs) < 1 || len(value.URLs) > 3 || len(value.SharedSecret) < 32 || strings.ContainsAny(value.SharedSecret, "\x00\r\n") {
		return nil, errors.New("invalid fixture TURN configuration")
	}
	for _, url := range value.URLs {
		if (!strings.HasPrefix(url, "turn:") && !strings.HasPrefix(url, "turns:")) || strings.ContainsAny(url, "\x00\r\n ") {
			return nil, errors.New("invalid fixture TURN URL")
		}
	}
	return &value, nil
}

func (c *Config) IceServer(username string) *gatewayv1.RTCIceServer {
	mac := hmac.New(sha1.New, []byte(c.SharedSecret)) // #nosec G401 -- coturn REST authentication requires HMAC-SHA1.
	_, _ = mac.Write([]byte(username))
	return &gatewayv1.RTCIceServer{Urls: c.URLs, Username: username, Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil))}
}
