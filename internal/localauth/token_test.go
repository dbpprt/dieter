package localauth

import (
	"context"
	"os"
	"testing"
)

func TestRotateWritesOwnerOnlyTokenAndReplacesThePrevious(t *testing.T) {
	root := t.TempDir()
	first, err := Rotate(root)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(Path(root))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("token mode = %v, %v", info.Mode().Perm(), err)
	}
	second, err := Rotate(root)
	if err != nil || second == first {
		t.Fatalf("rotation reused token or failed: %v", err)
	}
	if read, err := Read(root); err != nil || read != second {
		t.Fatalf("Read = %q, %v", read, err)
	}
}

func TestEnsureKeepsAnExistingTokenAndReplacesAnExposedOne(t *testing.T) {
	root := t.TempDir()
	token, err := Ensure(root)
	if err != nil {
		t.Fatal(err)
	}
	if again, err := Ensure(root); err != nil || again != token {
		t.Fatalf("Ensure replaced a valid token: %q, %v", again, err)
	}
	if err := os.Chmod(Path(root), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(root); err == nil {
		t.Fatal("Read accepted a token other users can read")
	}
	replaced, err := Ensure(root)
	if err != nil || replaced == token {
		t.Fatalf("Ensure kept an exposed token: %v", err)
	}
}

func TestValidRejectsEmptyAndMismatchedTokens(t *testing.T) {
	if Valid("", "") || Valid("", "x") || Valid("a", "") || Valid("a", "b") || !Valid("a", "a") {
		t.Fatal("unexpected token comparison result")
	}
}

func TestFileCredentialsFollowRotation(t *testing.T) {
	root := t.TempDir()
	credentials := FileCredentials{Root: root}
	if _, err := credentials.GetRequestMetadata(context.Background()); err == nil {
		t.Fatal("missing token produced credentials")
	}
	if _, err := Rotate(root); err != nil {
		t.Fatal(err)
	}
	current, err := Rotate(root)
	if err != nil {
		t.Fatal(err)
	}
	values, err := credentials.GetRequestMetadata(context.Background())
	if err != nil || values[Header] != current {
		t.Fatalf("credentials = %v, %v", values, err)
	}
}
