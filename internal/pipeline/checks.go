package pipeline

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// CheckRequest describes work; the Fastlane executor owns every mutation.
type CheckRequest struct {
	Component string            `json:"component"`
	Operation string            `json:"operation"`
	Options   map[string]string `json:"options,omitempty"`
	Packages  []string          `json:"packages,omitempty"`
}
type CheckPlan struct {
	Version int             `json:"version"`
	Paths   []string        `json:"paths"`
	Checks  []CheckRequest  `json:"checks"`
	CI      map[string]bool `json:"ci"`
}
type goPackage struct {
	ImportPath, Dir                             string
	Imports, TestImports, XTestImports          []string
	EmbedFiles, TestEmbedFiles, XTestEmbedFiles []string
}

var macSmokeSuites = []string{"core", "board", "conversation", "machine", "sidebar", "terminal", "island", "workspace", "inbox"}
var ciComponents = []string{"core", "macos", "ios", "android", "kmp"}
var iosRoots = []string{"apps/ios/", "apps/mac/Sources/DieterIOS/", "apps/mac/Tests/DieterIOSTests/"}
var swiftSharedRoots = []string{"apps/mac/Sources/DieterTransport/", "apps/mac/Sources/DieterAPI/", "apps/mac/Vendor/"}

func prefixAny(path string, prefixes ...string) bool {
	return slices.ContainsFunc(prefixes, func(prefix string) bool { return strings.HasPrefix(path, prefix) })
}
func codePaths(paths []string) []string {
	return slices.DeleteFunc(slices.Clone(paths), func(path string) bool {
		return path == "" || (!strings.Contains(path, "/testdata/") && (strings.HasSuffix(path, ".md") || strings.HasSuffix(path, ".txt")))
	})
}
func kotlinAndroidSource(path string) bool {
	return strings.HasPrefix(path, "apps/core/") && !prefixAny(path, "apps/core/testing/", "apps/core/apple/") && !strings.HasSuffix(coreSourceSet(path), "Test") && !strings.HasPrefix(coreSourceSet(path), "apple")
}
func macChecks(paths []string) []string {
	selected := map[string]bool{}
	for _, path := range paths {
		if !strings.HasPrefix(path, "apps/mac/") || prefixAny(path, append(iosRoots, "apps/mac/Tests/")...) {
			continue
		}
		relative := strings.TrimPrefix(path, "apps/mac/Sources/DieterMac/")
		suites, ok := macSmokeFiles[relative]
		if !ok {
			for prefix, candidates := range macSmokeComponents {
				if strings.HasPrefix(relative, prefix) {
					suites, ok = candidates, true
					break
				}
			}
		}
		if !ok {
			return slices.Clone(macSmokeSuites)
		}
		for _, suite := range suites {
			selected[suite] = true
		}
	}
	return slices.DeleteFunc(slices.Clone(macSmokeSuites), func(suite string) bool { return !selected[suite] })
}

func goChanged(paths []string) bool {
	return slices.ContainsFunc(paths, func(path string) bool {
		return strings.HasSuffix(path, ".go") || slices.Contains([]string{"go.mod", "go.sum"}, path) || prefixAny(path, "config/", "internal/", "api/gen/") || (strings.HasPrefix(path, "native/") && !strings.HasPrefix(path, "native/android-webrtc/"))
	})
}
func goPackages(ctx context.Context, root string) ([]goPackage, error) {
	files, err := command(ctx, root, nil, "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.go")
	if err != nil {
		return nil, err
	}
	patterns := []string{}
	for _, path := range strings.Split(files, "\x00") {
		info, err := os.Stat(filepath.Join(root, path))
		if path == "" || err != nil || !info.Mode().IsRegular() {
			continue
		}
		pattern := "."
		if strings.Contains(path, "/") {
			pattern = "./" + strings.SplitN(path, "/", 2)[0] + "/..."
		}
		if !slices.Contains(patterns, pattern) {
			patterns = append(patterns, pattern)
		}
	}
	if len(patterns) == 0 {
		return nil, nil
	}
	slices.Sort(patterns)
	// Only stdout is JSON: with a cold module cache, go also reports downloads
	// on stderr.
	c, finish := buildCommand(ctx, "go", append([]string{"list", "-json"}, patterns...)...)
	c.Dir = root
	var stdout bytes.Buffer
	stderr := &tailBuffer{limit: 64 << 10}
	c.Stdout, c.Stderr = &stdout, stderr
	if err := finish(c.Run()); err != nil {
		return nil, fmt.Errorf("%w: %s", err, stderr.String())
	}
	decoder := json.NewDecoder(&stdout)
	packages := []goPackage{}
	for {
		var pkg goPackage
		if err := decoder.Decode(&pkg); err == io.EOF {
			return packages, nil
		} else if err != nil {
			return nil, err
		}
		packages = append(packages, pkg)
	}
}
func affectedGo(root string, paths []string, packages []goPackage) []string {
	broad := slices.ContainsFunc(paths, func(path string) bool {
		return slices.Contains([]string{"go.mod", "go.sum"}, path) || strings.HasPrefix(path, "api/proto/") || strings.HasPrefix(path, "native/") && !strings.HasPrefix(path, "native/android-webrtc/")
	})
	selected := map[string]bool{}
	for _, pkg := range packages {
		dir, err := filepath.Rel(root, pkg.Dir)
		if err != nil {
			continue
		}
		dir = filepath.ToSlash(dir)
		embedded := append(append(slices.Clone(pkg.EmbedFiles), pkg.TestEmbedFiles...), pkg.XTestEmbedFiles...)
		for _, path := range paths {
			if broad || filepath.ToSlash(filepath.Dir(path)) == dir || strings.HasPrefix(path, dir+"/testdata/") || slices.ContainsFunc(embedded, func(file string) bool { return path == dir+"/"+file }) {
				selected[pkg.ImportPath] = true
			}
		}
	}
	for {
		count := len(selected)
		for _, pkg := range packages {
			imports := append(append(slices.Clone(pkg.Imports), pkg.TestImports...), pkg.XTestImports...)
			if slices.ContainsFunc(imports, func(name string) bool { return selected[name] }) {
				selected[pkg.ImportPath] = true
			}
		}
		if count == len(selected) {
			break
		}
	}
	result := []string{}
	for name := range selected {
		result = append(result, name)
	}
	slices.Sort(result)
	return result
}

func planChecks(paths []string, packages []string, base string) CheckPlan {
	paths = slices.Clone(paths)
	slices.Sort(paths)
	paths = slices.Compact(paths)
	plan := CheckPlan{Version: 1, Paths: paths, Checks: []CheckRequest{}, CI: map[string]bool{}}
	for _, component := range ciComponents {
		plan.CI[component] = false
	}
	add := func(component, operation string, options map[string]string) {
		request := CheckRequest{Component: component, Operation: operation, Options: options}
		if operation == "go_test" || operation == "go_vet" {
			request.Packages = packages
		}
		encoded, _ := json.Marshal(request)
		for _, check := range plan.Checks {
			previous, _ := json.Marshal(check)
			if string(previous) == string(encoded) {
				return
			}
		}
		plan.Checks = append(plan.Checks, request)
		ci := map[string]string{"mac": "macos", "ios": "ios", "android": "android", "core": "kmp"}[component]
		if ci == "" {
			ci = "core"
		}
		plan.CI[ci] = true
	}
	code := codePaths(paths)
	any := func(test func(string) bool) bool { return slices.ContainsFunc(code, test) }
	schema := any(func(p string) bool {
		return prefixAny(p, "api/proto/") || slices.Contains([]string{"scripts/generate-proto.sh", "scripts/sync_apple_proto.py", "scripts/sync_apple_proto_test.py"}, p)
	})
	fixture := any(func(p string) bool { return prefixAny(p, "tools/fixtures/gateway/") })
	brand := any(func(p string) bool { return prefixAny(p, "assets/brand/") })
	shared := any(func(p string) bool {
		return prefixAny(p, swiftSharedRoots...) || slices.Contains([]string{"apps/mac/Package.swift", "apps/mac/Package.resolved"}, p)
	})
	kmp := schema || fixture || any(func(p string) bool { return prefixAny(p, "apps/core/") || p == "fastlane/lib/dieter/platforms/core.rb" })
	bridge := any(func(p string) bool {
		return prefixAny(p, "apps/mac/Sources/SharedCore/", "apps/mac/Tests/SharedCoreTests/") || p == "fastlane/lib/dieter/platforms/framework.rb"
	})
	framework := any(func(p string) bool { return p == "fastlane/lib/dieter/platforms/framework.rb" })
	mac := schema || fixture || brand || kmp || bridge || any(func(p string) bool {
		return strings.HasPrefix(p, "apps/mac/") && !prefixAny(p, iosRoots...) || prefixAny(p, "fastlane/lib/dieter/native/mac_") || p == "fastlane/lib/dieter/platforms/mac.rb"
	})
	ios := schema || fixture || brand || kmp || shared || framework || any(func(p string) bool {
		return prefixAny(p, iosRoots...) || prefixAny(p, "apps/mac/Sources/SharedCore/", "fastlane/lib/dieter/native/ios_development") || p == "fastlane/lib/dieter/platforms/ios.rb" || p == "fastlane/lib/dieter/fixtures/device_route.rb"
	})
	android := kmp || brand || any(func(p string) bool {
		return prefixAny(p, "apps/android/", "native/android-webrtc/") || slices.Contains([]string{"fastlane/lib/dieter/platforms/android.rb", "fastlane/lib/dieter/platforms/emulator.rb"}, p)
	})
	androidIntegration := schema || fixture || brand || any(func(p string) bool {
		return prefixAny(p, "apps/android/") && !prefixAny(p, "apps/android/app/src/test/") || kotlinAndroidSource(p) || prefixAny(p, "native/android-webrtc/") || slices.Contains([]string{"fastlane/lib/dieter/platforms/android.rb", "fastlane/lib/dieter/platforms/emulator.rb"}, p)
	})
	orchestration := any(func(p string) bool {
		return prefixAny(p, "fastlane/lib/dieter/pipeline/") || slices.Contains([]string{"fastlane/Fastfile", "fastlane/lib/dieter/runtime.rb", "fastlane/lib/dieter/ci.rb", "fastlane/lib/dieter/config.rb", "fastlane/lib/dieter/operations.rb", "fastlane/lib/dieter/screens.rb", "fastlane/config.json", "fastlane/config.schema.json", "Gemfile", "Gemfile.lock", ".ruby-version", "justfile"}, p)
	})
	selector := any(func(p string) bool {
		return prefixAny(p, "internal/pipeline/check", ".github/workflows/ci.yml") || p == "justfile"
	})
	catalog := any(func(p string) bool { return prefixAny(p, "tests/e2e/", "internal/pipeline/") })
	// Orchestration contracts can be verified without compiling every native
	// client locally. CI still selects all components for these shared changes.
	if catalog || orchestration || any(func(p string) bool {
		return prefixAny(p, "fastlane/spec/", "fastlane/lib/dieter/distribution/", "fastlane/release-policy.json", "fastlane/local.example.json")
	}) {
		add("portable", "contracts", nil)
	}
	for _, platform := range []string{"android", "mac", "ios"} {
		if any(func(p string) bool { return prefixAny(p, "tests/e2e/cases/"+platform+"/") }) {
			switch platform {
			case "android":
				androidIntegration = true
			case "ios":
				ios = true
			case "mac":
				mac = true
			}
		}
	}
	if any(func(p string) bool {
		return prefixAny(p, "scripts/", "fastlane/lib/dieter/native/") && !strings.HasSuffix(p, ".go")
	}) {
		add("portable", "support_tests", nil)
	}
	if any(func(p string) bool {
		return prefixAny(p, "deploy/gateway/", "tools/fixtures/turn-probe/") || p == "Dockerfile.gateway" || p == "fastlane/lib/dieter/distribution/gateway.rb"
	}) {
		add("gateway", "deployment_test", nil)
		add("gateway", "deployment_integration", nil)
	}
	if any(func(p string) bool { return p == "justfile" || strings.HasPrefix(p, "just/") }) {
		add("portable", "justfile_check", nil)
	}
	if any(func(p string) bool {
		return prefixAny(p, ".github/workflows/", ".github/actions/")
	}) {
		add("portable", "workflow_check", nil)
		add("portable", "contracts", nil)
	}
	if schema {
		add("portable", "proto", nil)
	}
	if len(packages) > 0 {
		add("portable", "go_test", nil)
		add("portable", "go_vet", nil)
	}
	if any(func(p string) bool { return prefixAny(p, "native/linux-capture/") }) {
		add("daemon", "linux_capture_test", nil)
	}
	screens := schema || any(func(p string) bool {
		return prefixAny(p, "internal/remotedesktop/", "native/macos-capture/", "tools/fixtures/screens/") || strings.Contains(p, "RemoteDesktop") || strings.Contains(p, "Features/Screens/") || p == "apps/mac/Sources/DieterTransport/ScreenClipboardContent.swift"
	})
	if screens {
		add("mac", "screens_native_test", nil)
		add("mac", "screens_test", nil)
	}
	if any(func(p string) bool {
		return prefixAny(p, "internal/harness/runtime/") || slices.Contains([]string{"config/harnesses.yaml", "just/harness.just"}, p)
	}) {
		add("portable", "harness_test", nil)
	}
	if any(func(p string) bool {
		return prefixAny(p, "apps/mac/MarkdownPreview/", "apps/mac/Sources/DieterMac/Resources/MarkdownPreview/")
	}) {
		add("mac", "markdown_check", nil)
		plan.CI["core"] = true
	}
	if mac {
		add("mac", "test_unit", nil)
	} else if any(func(p string) bool { return prefixAny(p, iosRoots[1:]...) }) {
		add("ios", "test_unit", nil)
	}
	if android {
		add("android", "test_unit", nil)
	}
	if kmp {
		add("core", "test_unit", nil)
		add("core", "apple_test", nil)
	} else if bridge {
		add("mac", "core_test", nil)
	}
	if ios {
		add("ios", "build", nil)
		for _, layout := range []string{"iphone", "ipad"} {
			add("ios", "e2e", map[string]string{"profile": "ios-" + layout, "suite": "smoke"})
		}
	}
	suites := macChecks(code)
	if kmp || schema || fixture || brand || framework || any(func(p string) bool {
		return prefixAny(p, "fastlane/lib/dieter/native/mac_") || p == "fastlane/lib/dieter/platforms/mac.rb" || prefixAny(p, "tests/e2e/cases/mac/")
	}) {
		suites = macSmokeSuites
	}
	if len(suites) > 0 {
		options := map[string]string{"suite": "smoke"}
		if !slices.Equal(suites, macSmokeSuites) {
			ids := []string{}
			for _, suite := range suites {
				ids = append(ids, "mac."+suite)
			}
			options = map[string]string{"cases": strings.Join(ids, ",")}
		}
		add("mac", "e2e", options)
	}
	if androidIntegration {
		options := map[string]string{"suite": "functional", "changed": "true"}
		if base != "" {
			options["base"] = base
		}
		add("android", "e2e", options)
	}
	if screens || any(func(p string) bool {
		return prefixAny(p, "native/android-webrtc/", "apps/android/app/src/main/java/org/webrtc/") || strings.HasPrefix(p, "apps/android/") && (strings.Contains(p, "/screens/") || strings.HasSuffix(p, "/ScreensScreen.kt"))
	}) {
		add("android", "e2e", map[string]string{"suite": "screens"})
	}
	if brand || any(func(p string) bool { return prefixAny(p, "landingpage/") || p == "just/site.just" }) {
		add("portable", "site_build", nil)
	}
	if goChanged(code) || any(func(p string) bool {
		return !prefixAny(p, "apps/mac/", "apps/ios/", "apps/android/", "apps/core/", "native/android-webrtc/")
	}) {
		plan.CI["core"] = len(code) > 0
	}
	if selector || orchestration {
		for _, component := range ciComponents {
			plan.CI[component] = true
		}
	}
	return plan
}

func affectedChecks(ctx context.Context, root string, request ContractRequest) (CheckPlan, error) {
	paths := request.Paths
	if paths == nil {
		var err error
		paths, err = changedPaths(ctx, root, request.Base)
		if err != nil {
			return CheckPlan{}, err
		}
	}
	paths = slices.DeleteFunc(paths, func(path string) bool { return path == "" })
	packages := []string{}
	if request.Kind != "ci" && goChanged(codePaths(paths)) {
		inventory, err := goPackages(ctx, root)
		if err != nil {
			return CheckPlan{}, fmt.Errorf("Go dependency inventory: %w", err)
		}
		packages = affectedGo(root, codePaths(paths), inventory)
	}
	return planChecks(paths, packages, request.Base), nil
}
