package pipeline

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
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

// Feature-specific paths narrow device work; shared and unknown app paths fail broad.
func affected(cases []Case, paths []string) []Case {
	components := map[string]bool{}
	broad := false
	macChanged := false
	androidChanged := false
	iosChanged := false
	for _, p := range paths {
		if p == "" || strings.HasSuffix(p, ".md") || strings.HasSuffix(p, ".txt") {
			continue
		}
		// The iOS adapter tests in DieterIOSTests also run in the simulator.
		if strings.HasPrefix(p, "apps/ios/") || strings.HasPrefix(p, "apps/mac/Sources/DieterIOS/") || strings.HasPrefix(p, "apps/mac/Tests/DieterIOSTests/") || strings.HasPrefix(p, "tests/e2e/cases/ios/") || p == "fastlane/lib/dieter/platforms/ios.rb" {
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
		if strings.HasPrefix(p, "tests/e2e/cases/android/") || p == "fastlane/lib/dieter/platforms/android.rb" || p == "fastlane/lib/dieter/platforms/emulator.rb" {
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
		// Android compiles the shared core from source and the Apple apps link
		// it as DieterShared. Apple-only core code reaches only the Apple apps;
		// code that only the core's own tests compile reaches none.
		if strings.HasPrefix(p, "apps/core/") {
			sourceSet := coreSourceSet(p)
			if strings.HasPrefix(p, "apps/core/testing/") || strings.HasSuffix(sourceSet, "Test") {
				continue
			}
			macChanged = true
			iosChanged = true
			if !strings.HasPrefix(p, "apps/core/apple/") && !strings.HasPrefix(sourceSet, "apple") {
				androidChanged = true
			}
			continue
		}
		if p == "just/android.just" {
			androidChanged = true
			continue
		}
		if !strings.HasPrefix(p, "apps/android/") && !strings.HasPrefix(p, "native/android-webrtc/") {
			continue
		}
		if strings.HasPrefix(p, "apps/android/app/src/test/") {
			continue
		}
		lower := strings.ToLower(p)
		found := false
		for key, terms := range map[string][]string{"machines": {"machines", "machineinformation"}, "activity": {"activityscreen", "activityfeed"}, "screens": {"/screens/", "webrtc", "screensscreen"}, "schedules": {"schedule"}, "conversation": {"conversation", "composer", "message"}, "workspace": {"workspace", "project"}} {
			for _, term := range terms {
				if strings.Contains(lower, term) {
					components[key] = true
					found = true
				}
			}
		}
		if !found {
			androidChanged = true
		}
	}
	result := []Case{}
	for _, c := range cases {
		match := broad || (c.Platform == "ios" && iosChanged) || (c.Platform == "mac" && macChanged) || (c.Platform == "android" && androidChanged)
		for _, component := range c.Components {
			match = match || (c.Platform == "android" && components[component])
		}
		if match {
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
func last(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}
func redact(s string, args map[string]string) string {
	for k, v := range args {
		if (strings.Contains(strings.ToLower(k), "token") || k == "screenFixture") && v != "" {
			s = strings.ReplaceAll(s, v, "<redacted>")
		}
	}
	return regexp.MustCompile(`isolated_[0-9a-fA-F]{48}`).ReplaceAllString(s, "<redacted>")
}
