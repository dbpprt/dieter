package kanban

import (
	"reflect"
	"strings"
	"testing"
)

func TestProjectHostnameMappingsPreservePortsAndCanonicalizeAddresses(t *testing.T) {
	t.Parallel()
	values := []string{
		" EXAMPLE.COM. ", "example.com", "EXAMPLE.COM.:00080", "example.com:80", "example.com:443",
		"localhost:1", "localhost:65535", "127.0.0.1", "127.0.0.1:04018",
		"2001:0DB8:0:0:0:0:0:1", "[2001:db8::1]", "[2001:0DB8::1]:04018", "::1", "::1:4018",
	}
	want := []string{
		"127.0.0.1", "127.0.0.1:4018", "2001:db8::1", "::1", "::1:4018", "[2001:db8::1]:4018",
		"example.com", "example.com:443", "example.com:80", "localhost:1", "localhost:65535",
	}
	got, err := normalizeProjectHostnames(values)
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("normalized=%v want=%v err=%v", got, want, err)
	}
	// A bare IPv6 address's final digits are address bytes, never an inferred port.
	if got, err := normalizeProjectHostnames([]string{"::1:4018", "[::1]:4018"}); err != nil || !reflect.DeepEqual(got, []string{"::1:4018", "[::1]:4018"}) {
		t.Fatalf("IPv6 address and port conflated: %v %v", got, err)
	}
	if _, err := normalizeProjectHostnames([]string{strings.Repeat("a", 64) + ".example:4018"}); err == nil {
		t.Fatal("accepted overlong DNS label with a port")
	}
	if _, err := normalizeProjectHostnames(make([]string, 65)); err == nil {
		t.Fatal("accepted more than 64 mappings")
	}
}
