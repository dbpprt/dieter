package cli

import (
	"testing"

	"github.com/dbpprt/dieter/internal/localauth"
)

// testLocalToken returns the raw API token a test daemon's store will accept,
// for forwarders that reach that daemon's loopback listener.
func testLocalToken(t *testing.T, root string) string {
	t.Helper()
	token, err := localauth.Ensure(root)
	if err != nil {
		t.Fatal(err)
	}
	return token
}
