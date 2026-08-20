package gateway

import "testing"

func TestProxyModeRequiresLoopbackAndHTTPSPublicOrigin(t *testing.T) {
	setMinimumGatewayEnvironment(t)
	t.Setenv("NAUCLIO_GATEWAY_PROXY_MODE", "1")
	t.Setenv("NAUCLIO_GATEWAY_ADDR", "127.0.0.1:4243")
	t.Setenv("NAUCLIO_PUBLIC_URL", "https://nauclio.example.com")
	config, err := ConfigFromEnv(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if !config.ProxyMode || !config.PublicURL.IsAbs() {
		t.Fatalf("unexpected proxy config: %#v", config)
	}

	t.Setenv("NAUCLIO_GATEWAY_ADDR", "0.0.0.0:4243")
	if _, err := ConfigFromEnv(t.TempDir()); err == nil {
		t.Fatal("proxy mode accepted a non-loopback listener")
	}
	t.Setenv("NAUCLIO_GATEWAY_ADDR", "127.0.0.1:4243")
	t.Setenv("NAUCLIO_PUBLIC_URL", "http://nauclio.example.com")
	if _, err := ConfigFromEnv(t.TempDir()); err == nil {
		t.Fatal("proxy mode accepted a plaintext public origin")
	}
}

func setMinimumGatewayEnvironment(t *testing.T) {
	t.Helper()
	t.Setenv("NAUCLIO_GITHUB_CLIENT_ID", "client")
	t.Setenv("NAUCLIO_GITHUB_CLIENT_SECRET", "secret")
	t.Setenv("NAUCLIO_GITHUB_ALLOWED_USER_ID", "42")
	t.Setenv("NAUCLIO_AUTH_SECRET", "3031323334353637383961626364656630313233343536373839616263646566") // gitleaks:allow -- deterministic test-only key
	t.Setenv("NAUCLIO_GATEWAY_TLS_CERT", "")
	t.Setenv("NAUCLIO_GATEWAY_TLS_KEY", "")
	t.Setenv("NAUCLIO_GATEWAY_DEV_INSECURE", "")
}
