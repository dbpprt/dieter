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
	// Path -> whether it is compiled into the APK or its instrumentation test.
	inputs := []struct {
		path  string
		input bool
	}{
		{"apps/android/app/src/main/kotlin/com/dbpprt/dieter/MainActivity.kt", true},
		{"apps/android/app/src/main/java/org/webrtc/DieterLowLatencyDecoderFactory.java", true},
		{"apps/android/app/src/androidTest/kotlin/com/dbpprt/dieter/JourneyTest.kt", true},
		{"apps/android/app/build.gradle.kts", true},
		{"apps/core/shared/src/commonMain/Core.kt", true},
		{"apps/core/mobile/src/commonMain/kotlin/App.kt", true},
		{"apps/core/mobile/src/androidMain/kotlin/Host.kt", true},
		{"api/proto/dieter.proto", true},
		{"native/android-webrtc/sdk.gradle", true},
		{"apps/core/mobile/src/iosMain/kotlin/MobileHost.kt", false},
		{"apps/core/mobile/src/jvmTest/kotlin/AppTest.kt", false},
		{"apps/core/shared/src/commonTest/Test.kt", false},
		{"apps/core/apple/src/appleMain/Facade.kt", false},
		{"apps/core/testing/src/jvmMain/IsolatedGateway.kt", false},
		{"apps/android/README.md", false},
	}
	paths := []string{}
	for _, input := range inputs {
		if androidBuildInput(input.path) != input.input {
			t.Fatalf("androidBuildInput(%s) != %t", input.path, input.input)
		}
		paths = append(paths, input.path)
	}
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
	for _, input := range inputs {
		if err := os.WriteFile(filepath.Join(root, input.path), []byte("edited"), 0600); err != nil {
			t.Fatal(err)
		}
		after, err := sourceDigest(ctx, root)
		if err != nil {
			t.Fatal(err)
		}
		if (after != before) != input.input {
			t.Fatal("incorrect cache invalidation", input.path)
		}
		before = after
	}
}
