package gateway

import "testing"

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
