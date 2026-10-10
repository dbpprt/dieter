package pipeline

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
func changedPaths(ctx context.Context, root, base string) ([]string, error) {
	ref := "HEAD"
	if base != "" {
		out, err := command(ctx, root, nil, "git", "merge-base", base, "HEAD")
		if err != nil {
			return nil, err
		}
		ref = strings.TrimSpace(out)
	}
	tracked, err := command(ctx, root, nil, "git", "diff", "--name-only", "--no-renames", "-z", ref, "--")
	if err != nil {
		return nil, err
	}
	untracked, err := command(ctx, root, nil, "git", "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return nil, err
	}
	return strings.Split(tracked+untracked, "\x00"), nil
}

// App-specific paths narrow device work; shared pipeline and fixture paths select every platform.
func affected(cases []Case, paths []string) []Case {
	broad := false
	macChanged := false
	androidChanged := false
	iosChanged := false
	for _, p := range paths {
		if p == "" || strings.HasSuffix(p, ".md") || strings.HasSuffix(p, ".txt") {
			continue
		}
		if strings.HasPrefix(p, "apps/ios/") || strings.HasPrefix(p, "apps/mac/Sources/DieterIOS/") || strings.HasPrefix(p, "tests/e2e/cases/ios/") || strings.HasPrefix(p, "fastlane/lib/dieter/native/ios_") || p == "fastlane/lib/dieter/platforms/ios.rb" {
			iosChanged = true
			continue
		}
		// Both Apple apps link the shared core through SharedCore and DieterTransport.
		if strings.HasPrefix(p, "apps/mac/Sources/SharedCore/") || strings.HasPrefix(p, "apps/mac/Sources/DieterTransport/") || strings.HasPrefix(p, "apps/mac/Sources/DieterAPI/") || p == "apps/mac/Package.swift" || p == "fastlane/lib/dieter/platforms/framework.rb" {
			iosChanged = true
			macChanged = true
		}
		if strings.HasPrefix(p, "tests/e2e/cases/mac/") {
			macChanged = true
			continue
		}
		// The Android and iOS journeys run real turns through the mock harness.
		if strings.HasPrefix(p, "internal/harness/runtime/") || p == "config/harnesses.yaml" {
			androidChanged = true
			iosChanged = true
			continue
		}
		if strings.HasPrefix(p, "tests/e2e/cases/android/") || strings.HasPrefix(p, "apps/android/") || strings.HasPrefix(p, "native/android-webrtc/") || p == "fastlane/lib/dieter/platforms/android.rb" || p == "fastlane/lib/dieter/platforms/emulator.rb" {
			androidChanged = true
			continue
		}
		if strings.HasPrefix(p, "tests/e2e/") || strings.HasPrefix(p, "fastlane/lib/dieter/pipeline/") || strings.HasPrefix(p, "fastlane/lib/dieter/fixtures/") || p == "fastlane/lib/dieter/runtime.rb" || p == "fastlane/lib/dieter/screens.rb" || p == "fastlane/lib/dieter/operations.rb" || p == "fastlane/config.json" || p == "fastlane/config.schema.json" || strings.HasPrefix(p, "api/") || strings.HasPrefix(p, "tools/fixtures/gateway/") || p == "fastlane/Fastfile" {
			broad = true
			continue
		}
		if (strings.HasPrefix(p, "apps/mac/") && !strings.HasPrefix(p, "apps/mac/Tests/") && !strings.HasPrefix(p, "apps/mac/Sources/DieterIOS/")) || p == "fastlane/lib/dieter/platforms/mac.rb" {
			macChanged = true
			continue
		}
		// Android compiles the core and its Compose UI from source; the iOS app
		// links both, and the Mac links the core without the Compose UI.
		// Code that only the core's own tests compile reaches none of them.
		if strings.HasPrefix(p, "apps/core/") {
			sourceSet := coreSourceSet(p)
			if strings.HasPrefix(p, "apps/core/testing/") || strings.HasSuffix(sourceSet, "Test") {
				continue
			}
			if !strings.HasPrefix(sourceSet, "android") {
				iosChanged = true
			}
			if !strings.HasPrefix(p, "apps/core/mobile/") && !strings.HasPrefix(sourceSet, "android") && !strings.HasPrefix(sourceSet, "ios") {
				macChanged = true
			}
			if !strings.HasPrefix(p, "apps/core/apple/") && !strings.HasPrefix(sourceSet, "apple") && !strings.HasPrefix(sourceSet, "ios") && !strings.HasPrefix(sourceSet, "macos") {
				androidChanged = true
			}
		}
	}
	result := []Case{}
	for _, c := range cases {
		if broad || (c.Platform == "ios" && iosChanged) || (c.Platform == "mac" && macChanged) || (c.Platform == "android" && androidChanged) {
			result = append(result, c)
		}
	}
	return result
}

// coreSourceSet returns the Kotlin source set of a core module path, such as
// "commonMain" for apps/core/shared/src/commonMain/..., or "" outside src/.
func coreSourceSet(p string) string {
	_, rest, ok := strings.Cut(p, "/src/")
	if !ok {
		return ""
	}
	sourceSet, _, _ := strings.Cut(rest, "/")
	return sourceSet
}
func androidBuildInput(path string) bool {
	if path == "" || strings.HasSuffix(path, ".md") || strings.HasPrefix(path, "apps/core/apple/") || strings.HasPrefix(path, "apps/core/testing/") {
		return false
	}
	if strings.Contains(path, "/src/") {
		sourceSet := strings.Split(strings.SplitN(path, "/src/", 2)[1], "/")[0]
		if sourceSet == "test" || strings.HasSuffix(sourceSet, "Test") && sourceSet != "androidTest" || strings.HasPrefix(sourceSet, "apple") || strings.HasPrefix(sourceSet, "ios") || strings.HasPrefix(sourceSet, "macos") {
			return false
		}
	}
	return true
}

func sourceDigest(ctx context.Context, root string) (string, error) {
	out, err := command(ctx, root, nil, "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "apps/android", "apps/core", "api/proto", "native/android-webrtc")
	if err != nil {
		return "", err
	}
	h := sha256.New()
	for _, p := range strings.Split(out, "\x00") {
		if !androidBuildInput(p) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, p))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return "", err
		}
		fmt.Fprintf(h, "%s\x00", p)
		h.Write(data)
	}
	return fmt.Sprintf("%x", h.Sum(nil)), nil
}
