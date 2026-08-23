package gateway

import (
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Root            string
	Address         string
	PublicURL       *url.URL
	GitHubClientID  string
	GitHubSecret    string
	AllowedUserID   int64
	AllowedLogin    string
	AuthSecret      []byte
	SessionTTL      time.Duration
	NativeRedirects map[string]struct{}
	GitHubBaseURL   string
	GitHubAPIURL    string
	TLSCertFile     string
	TLSKeyFile      string
	DevInsecure     bool
	ProxyMode       bool
}

func ConfigFromEnv(root string) (Config, error) {
	config := Config{
		Root: root, Address: envOr("DIETER_GATEWAY_ADDR", "127.0.0.1:4243"), SessionTTL: 30 * 24 * time.Hour,
		GitHubBaseURL: envOr("DIETER_GITHUB_BASE_URL", "https://github.com"), GitHubAPIURL: envOr("DIETER_GITHUB_API_URL", "https://api.github.com"),
		TLSCertFile: strings.TrimSpace(os.Getenv("DIETER_GATEWAY_TLS_CERT")), TLSKeyFile: strings.TrimSpace(os.Getenv("DIETER_GATEWAY_TLS_KEY")),
		DevInsecure: os.Getenv("DIETER_GATEWAY_DEV_INSECURE") == "1", ProxyMode: os.Getenv("DIETER_GATEWAY_PROXY_MODE") == "1", NativeRedirects: map[string]struct{}{},
	}
	publicURL, err := url.Parse(strings.TrimSpace(os.Getenv("DIETER_PUBLIC_URL")))
	if err != nil || publicURL.Host == "" || publicURL.Path != "" || publicURL.RawQuery != "" || publicURL.Fragment != "" || (!config.DevInsecure && publicURL.Scheme != "https") || (config.DevInsecure && publicURL.Scheme != "http" && publicURL.Scheme != "https") {
		return config, errors.New("DIETER_PUBLIC_URL must be an HTTPS origin without a path, query, or fragment")
	}
	config.PublicURL = publicURL
	config.GitHubClientID = strings.TrimSpace(os.Getenv("DIETER_GITHUB_CLIENT_ID"))
	config.GitHubSecret = strings.TrimSpace(os.Getenv("DIETER_GITHUB_CLIENT_SECRET"))
	if config.GitHubClientID == "" || config.GitHubSecret == "" {
		return config, errors.New("DIETER_GITHUB_CLIENT_ID and DIETER_GITHUB_CLIENT_SECRET are required")
	}
	config.AllowedUserID, err = strconv.ParseInt(strings.TrimSpace(os.Getenv("DIETER_GITHUB_ALLOWED_USER_ID")), 10, 64)
	if err != nil || config.AllowedUserID <= 0 {
		return config, errors.New("DIETER_GITHUB_ALLOWED_USER_ID must be a positive numeric GitHub ID")
	}
	config.AllowedLogin = strings.TrimSpace(os.Getenv("DIETER_GITHUB_ALLOWED_LOGIN"))
	config.AuthSecret, err = hex.DecodeString(strings.TrimSpace(os.Getenv("DIETER_AUTH_SECRET")))
	if err != nil || len(config.AuthSecret) < 32 {
		return config, errors.New("DIETER_AUTH_SECRET must contain at least 32 random bytes encoded as hexadecimal")
	}
	if raw := strings.TrimSpace(os.Getenv("DIETER_NATIVE_SESSION_TTL")); raw != "" {
		config.SessionTTL, err = time.ParseDuration(raw)
		if err != nil || config.SessionTTL < time.Hour || config.SessionTTL > 90*24*time.Hour {
			return config, errors.New("DIETER_NATIVE_SESSION_TTL must be between 1h and 2160h")
		}
	}
	for _, value := range strings.Split(os.Getenv("DIETER_NATIVE_REDIRECT_URIS"), ",") {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		parsed, parseErr := url.Parse(value)
		if parseErr != nil || parsed.Scheme == "" || !parsed.IsAbs() || parsed.Fragment != "" {
			return config, fmt.Errorf("invalid DIETER_NATIVE_REDIRECT_URIS entry %q", value)
		}
		config.NativeRedirects[value] = struct{}{}
	}
	if config.TLSCertFile == "" || config.TLSKeyFile == "" {
		if !config.DevInsecure && !config.ProxyMode {
			return config, errors.New("DIETER_GATEWAY_TLS_CERT and DIETER_GATEWAY_TLS_KEY are required")
		}
		host, _, splitErr := net.SplitHostPort(config.Address)
		ip := net.ParseIP(host)
		if splitErr != nil || host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			return config, errors.New("plaintext gateway modes are allowed only on a loopback address")
		}
	}
	if config.ProxyMode && config.DevInsecure {
		return config, errors.New("DIETER_GATEWAY_PROXY_MODE and DIETER_GATEWAY_DEV_INSECURE are mutually exclusive")
	}
	return config, nil
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
