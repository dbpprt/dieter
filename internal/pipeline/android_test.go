package pipeline

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAndroidBuildDigestTracksAPKInputs(t *testing.T) {
	root := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := command(ctx, root, nil, "git", "init", "-q"); err != nil {
		t.Fatal(err)
	}
	paths := []string{"apps/android/app/src/main/App.kt", "apps/android/app/src/androidTest/Test.kt", "apps/core/shared/src/commonMain/Core.kt", "api/proto/dieter.proto", "apps/core/shared/src/commonTest/Test.kt", "apps/core/apple/src/appleMain/Facade.kt", "apps/android/README.md"}
	for _, path := range paths {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(root, path)), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, path), []byte("initial"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	before, err := sourceDigest(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if err := os.WriteFile(filepath.Join(root, path), []byte("edited"), 0600); err != nil {
			t.Fatal(err)
		}
		after, err := sourceDigest(ctx, root)
		if err != nil {
			t.Fatal(err)
		}
		if (after != before) != androidBuildInput(path) {
			t.Fatal("incorrect cache invalidation", path)
		}
		before = after
	}
}
