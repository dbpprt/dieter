package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
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

func TestAndroidPreflightVerifiesSelectedAVDAndSupportsExactPhysicalDevice(t *testing.T) {
	root := t.TempDir()
	adb := filepath.Join(root, "adb")
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$ADB_STUB_LOG"
case "$3" in
 get-state) echo device ;;
 emu) echo Wrong_AVD ;;
 shell)
  case "$*" in
   *sys.boot_completed*) echo 1 ;;
   *init.svc.bootanim*) echo stopped ;;
  esac ;;
esac
`
	if err := os.WriteFile(adb, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(root, "adb.log")
	t.Setenv("ADB_STUB_LOG", log)
	t.Setenv("DIETER_ANDROID_AVD", "Pixel_9_API_37_1")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	a := android{root: root, adb: adb, serial: "emulator-5554"}
	if err := a.preflight(ctx); err == nil || !strings.Contains(err.Error(), "Wrong_AVD") {
		t.Fatal("wrong AVD accepted", err)
	}
	_ = os.WriteFile(log, nil, 0600)
	a.serial = "physical-phone-123"
	if err := a.preflight(ctx); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(log)
	if strings.Contains(string(data), "emu avd") || !strings.Contains(string(data), "-s physical-phone-123") {
		t.Fatal(string(data))
	}
}
