package gateway

import (
	"testing"
	"time"
)

func TestProxyModeRequiresLoopbackAndHTTPSPublicOrigin(t *testing.T) {
	setMinimumGatewayEnvironment(t)
	t.Setenv("DIETER_GATEWAY_PROXY_MODE", "1")
	t.Setenv("DIETER_GATEWAY_ADDR", "127.0.0.1:4243")
	t.Setenv("DIETER_PUBLIC_URL", "https://dieter.example.com")
	config, err := ConfigFromEnv(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if !config.ProxyMode || !config.PublicURL.IsAbs() {
		t.Fatalf("unexpected proxy config: %#v", config)
	}

	t.Setenv("DIETER_GATEWAY_ADDR", "0.0.0.0:4243")
	if _, err := ConfigFromEnv(t.TempDir()); err == nil {
		t.Fatal("proxy mode accepted a non-loopback listener")
	}
	t.Setenv("DIETER_GATEWAY_ADDR", "127.0.0.1:4243")
	t.Setenv("DIETER_PUBLIC_URL", "http://dieter.example.com")
	if _, err := ConfigFromEnv(t.TempDir()); err == nil {
		t.Fatal("proxy mode accepted a plaintext public origin")
	}
}

func setMinimumGatewayEnvironment(t *testing.T) {
	t.Helper()
	t.Setenv("DIETER_GITHUB_CLIENT_ID", "client")
	t.Setenv("DIETER_GITHUB_CLIENT_SECRET", "secret")
	t.Setenv("DIETER_GITHUB_ALLOWED_USER_ID", "42")
	t.Setenv("DIETER_AUTH_SECRET", "3031323334353637383961626364656630313233343536373839616263646566") // gitleaks:allow -- deterministic test-only key
	t.Setenv("DIETER_GATEWAY_TLS_CERT", "")
	t.Setenv("DIETER_GATEWAY_TLS_KEY", "")
	t.Setenv("DIETER_GATEWAY_DEV_INSECURE", "")
}

func TestGitHubAllowlistSupportsLegacyAndMultipleUserIDs(t *testing.T) {
	setMinimumGatewayEnvironment(t)
	t.Setenv("DIETER_GATEWAY_DEV_INSECURE", "1")
	t.Setenv("DIETER_PUBLIC_URL", "http://127.0.0.1:4243")
	t.Setenv("DIETER_GITHUB_ALLOWED_USER_IDS", "60854672, 42,60854672")

	config, err := ConfigFromEnv(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{42, 60854672} {
		if !config.AllowsGitHubUser(id) {
			t.Fatalf("expected GitHub user %d to be allowed", id)
		}
	}
	if config.AllowsGitHubUser(99) {
		t.Fatal("unexpected GitHub user was allowed")
	}
}

func TestGitHubAllowlistAcceptsPluralConfigurationWithoutLegacyID(t *testing.T) {
	setMinimumGatewayEnvironment(t)
	t.Setenv("DIETER_GATEWAY_DEV_INSECURE", "1")
	t.Setenv("DIETER_PUBLIC_URL", "http://127.0.0.1:4243")
	t.Setenv("DIETER_GITHUB_ALLOWED_USER_ID", "")
	t.Setenv("DIETER_GITHUB_ALLOWED_USER_IDS", "7000188,60854672")

	config, err := ConfigFromEnv(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if !config.AllowsGitHubUser(7000188) || !config.AllowsGitHubUser(60854672) {
		t.Fatalf("unexpected GitHub allowlist: %#v", config.AllowedUserIDs)
	}
}

func TestGitHubAllowlistRejectsMissingOrMalformedIDs(t *testing.T) {
	for _, value := range []string{"", "0", "42,", "42,not-an-id", "-1"} {
		t.Run(value, func(t *testing.T) {
			setMinimumGatewayEnvironment(t)
			t.Setenv("DIETER_GATEWAY_DEV_INSECURE", "1")
			t.Setenv("DIETER_PUBLIC_URL", "http://127.0.0.1:4243")
			t.Setenv("DIETER_GITHUB_ALLOWED_USER_ID", "")
			t.Setenv("DIETER_GITHUB_ALLOWED_USER_IDS", value)
			if _, err := ConfigFromEnv(t.TempDir()); err == nil {
				t.Fatalf("accepted malformed allowlist %q", value)
			}
		})
	}
}

func TestRTCConfigurationRequiresBoundedTURNSettings(t *testing.T) {
	setMinimumGatewayEnvironment(t)
	t.Setenv("DIETER_GATEWAY_DEV_INSECURE", "1")
	t.Setenv("DIETER_PUBLIC_URL", "http://127.0.0.1:4243")
	t.Setenv("DIETER_RTC_STUN_URLS", "stun:stun.example.com:3478")
	t.Setenv("DIETER_RTC_TURN_URLS", "turn:turn.example.com:3478?transport=udp,turns:turn.example.com:443?transport=tcp")
	if _, err := ConfigFromEnv(t.TempDir()); err == nil {
		t.Fatal("TURN URLs were accepted without a REST secret")
	}
	t.Setenv("DIETER_RTC_TURN_SECRET", "3031323334353637383961626364656630313233343536373839616263646566") // gitleaks:allow -- deterministic test-only key
	config, err := ConfigFromEnv(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(config.RTCSTUNURLs) != 1 || len(config.RTCTURNURLs) != 2 || config.RTCTTL != 5*time.Minute {
		t.Fatalf("unexpected RTC config: %#v", config)
	}
	t.Setenv("DIETER_RTC_TTL", "30m")
	if _, err := ConfigFromEnv(t.TempDir()); err == nil {
		t.Fatal("oversized RTC TTL was accepted")
	}
}
