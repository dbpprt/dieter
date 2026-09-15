package trust

import "testing"

func TestGatewayOriginRejectsCleartextOutsideLiteralLoopback(t *testing.T) {
	for _, raw := range []string{
		"http://gateway.example", "http://192.168.1.2:8080", "http://localhost:8080",
		"http://127.0.0.1.attacker.example", "http://[::]", "http://[::ffff:192.168.1.2]",
		"https://user:password@gateway.example", "https://gateway.example/path",
		"https://gateway.example?secret=x", "https://gateway.example?", "https://gateway.example#x",
		"https://", "https://:443", "ftp://127.0.0.1", "",
	} {
		t.Run(raw, func(t *testing.T) {
			if _, err := GatewayOrigin(raw); err == nil {
				t.Fatal("unsafe gateway origin was accepted")
			}
		})
	}
	for _, raw := range []string{"https://gateway.example", "https://192.168.1.2:8443", "http://127.0.0.1:8080", "http://[::1]:8080", "http://[::ffff:127.0.0.1]:8080"} {
		if got, err := GatewayOrigin("  " + raw + "/  "); err != nil || got != raw {
			t.Errorf("GatewayOrigin(%q) = (%q, %v)", raw, got, err)
		}
	}
}
