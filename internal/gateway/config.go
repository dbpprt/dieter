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
	AllowedUserIDs  map[int64]struct{}
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
	RTCSTUNURLs     []string
	RTCTURNURLs     []string
	RTCTURNSecret   []byte
	RTCTTL          time.Duration
}

func ConfigFromEnv(root string) (Config, error) {
	config := Config{
		Root: root, Address: envOr("DIETER_GATEWAY_ADDR", "127.0.0.1:4243"), SessionTTL: 30 * 24 * time.Hour,
		GitHubBaseURL: envOr("DIETER_GITHUB_BASE_URL", "https://github.com"), GitHubAPIURL: envOr("DIETER_GITHUB_API_URL", "https://api.github.com"),
		TLSCertFile: strings.TrimSpace(os.Getenv("DIETER_GATEWAY_TLS_CERT")), TLSKeyFile: strings.TrimSpace(os.Getenv("DIETER_GATEWAY_TLS_KEY")),
		DevInsecure: os.Getenv("DIETER_GATEWAY_DEV_INSECURE") == "1", ProxyMode: os.Getenv("DIETER_GATEWAY_PROXY_MODE") == "1", NativeRedirects: map[string]struct{}{}, RTCTTL: 5 * time.Minute,
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
	config.AllowedUserIDs = map[int64]struct{}{}
	legacyAllowedUserID := strings.TrimSpace(os.Getenv("DIETER_GITHUB_ALLOWED_USER_ID"))
	if legacyAllowedUserID != "" {
		config.AllowedUserID, err = addAllowedUserID(config.AllowedUserIDs, legacyAllowedUserID)
		if err != nil {
			return config, errors.New("DIETER_GITHUB_ALLOWED_USER_ID must be a positive numeric GitHub ID")
		}
	}
	if allowedUserIDs := strings.TrimSpace(os.Getenv("DIETER_GITHUB_ALLOWED_USER_IDS")); allowedUserIDs != "" {
		for _, value := range strings.Split(allowedUserIDs, ",") {
			if _, err := addAllowedUserID(config.AllowedUserIDs, strings.TrimSpace(value)); err != nil {
				return config, errors.New("DIETER_GITHUB_ALLOWED_USER_IDS must be a comma-separated list of positive numeric GitHub IDs")
			}
		}
	}
	if len(config.AllowedUserIDs) == 0 {
		return config, errors.New("DIETER_GITHUB_ALLOWED_USER_ID or DIETER_GITHUB_ALLOWED_USER_IDS must contain at least one positive numeric GitHub ID")
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
	config.RTCSTUNURLs, err = rtcURLs(os.Getenv("DIETER_RTC_STUN_URLS"), "stun:", "stuns:")
	if err != nil {
		return config, err
	}
	config.RTCTURNURLs, err = rtcURLs(os.Getenv("DIETER_RTC_TURN_URLS"), "turn:", "turns:")
	if err != nil {
		return config, err
	}
	if raw := strings.TrimSpace(os.Getenv("DIETER_RTC_TTL")); raw != "" {
		config.RTCTTL, err = time.ParseDuration(raw)
		if err != nil || config.RTCTTL < time.Minute || config.RTCTTL > 10*time.Minute {
			return config, errors.New("DIETER_RTC_TTL must be between 1m and 10m")
		}
	}
	if raw := strings.TrimSpace(os.Getenv("DIETER_RTC_TURN_SECRET")); raw != "" {
		config.RTCTURNSecret, err = hex.DecodeString(raw)
		if err != nil || len(config.RTCTURNSecret) < 32 {
			return config, errors.New("DIETER_RTC_TURN_SECRET must contain at least 32 random bytes encoded as hexadecimal")
		}
	}
	if len(config.RTCTURNURLs) > 0 && len(config.RTCTURNSecret) == 0 {
		return config, errors.New("DIETER_RTC_TURN_SECRET is required when DIETER_RTC_TURN_URLS is configured")
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

func addAllowedUserID(allowed map[int64]struct{}, value string) (int64, error) {
	id, err := strconv.ParseInt(value, 10, 64)
	if err != nil || id <= 0 {
		return 0, errors.New("GitHub user ID must be positive")
	}
	allowed[id] = struct{}{}
	return id, nil
}

func (c Config) AllowsGitHubUser(id int64) bool {
	if len(c.AllowedUserIDs) > 0 {
		_, ok := c.AllowedUserIDs[id]
		return ok
	}
	return id > 0 && id == c.AllowedUserID
}

func rtcURLs(raw string, prefixes ...string) ([]string, error) {
	var result []string
	for _, value := range strings.Split(raw, ",") {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		valid := false
		for _, prefix := range prefixes {
			if strings.HasPrefix(strings.ToLower(value), prefix) {
				valid = true
				break
			}
		}
		if !valid {
			return nil, fmt.Errorf("invalid RTC URL %q", value)
		}
		result = append(result, value)
	}
	return result, nil
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
