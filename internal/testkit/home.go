package testkit

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/store"
)

// Home returns a fresh private DIETER_HOME root that the test owns. It never
// resolves the operator's home or environment.
func Home(tb testing.TB) string {
	tb.Helper()
	root := filepath.Join(tb.TempDir(), "dieter-home")
	if err := os.Mkdir(root, 0o700); err != nil {
		tb.Fatal(err)
	}
	return root
}

// Store returns an initialized central store in a fresh Home.
func Store(tb testing.TB) *store.Store {
	tb.Helper()
	data := store.New(Home(tb))
	if err := data.Ensure(); err != nil {
		tb.Fatal(err)
	}
	return data
}

// LocalToken returns the loopback API token of the Dieter home root, creating
// it when missing.
func LocalToken(tb testing.TB, root string) string {
	tb.Helper()
	token, err := localauth.Ensure(root)
	if err != nil {
		tb.Fatal(err)
	}
	return token
}
