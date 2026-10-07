package pipeline

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
)

func checkExists(plan CheckPlan, component, operation string) bool {
	return slices.ContainsFunc(plan.Checks, func(check CheckRequest) bool { return check.Component == component && check.Operation == operation })
}
func TestAffectedCheckOwnership(t *testing.T) {
	for _, test := range []struct {
		path    string
		enabled []string
		device  bool
	}{
		{"README.md", nil, false},
		{"internal/server/server.go", []string{"core"}, false},
		{"scripts/new_tool.py", []string{"core"}, false},
		{"apps/android/app/src/test/java/Test.kt", []string{"android"}, false},
		{"apps/android/app/src/main/java/Conversation.kt", []string{"android"}, true},
		{"native/android-webrtc/build_sdk.py", []string{"android", "compose_android"}, true},
		{"apps/mac/Tests/DieterMacTests/Test.swift", []string{"macos"}, false},
		{"apps/mac/Sources/DieterMac/UI/BoardView.swift", []string{"macos"}, true},
		{"apps/ios/DieterIOSApp/DieterIOSApp.swift", []string{"ios"}, true},
		{"apps/mac/Sources/DieterIOS/UI/Root.swift", []string{"ios"}, true},
		{"apps/mac/Sources/DieterTransport/ControlRTCBridge.swift", []string{"macos", "ios", "compose_ios"}, true},
		{"apps/mac/MarkdownPreview/src/chart.js", []string{"core", "macos"}, true},
		{"fastlane/lib/dieter/platforms/ios.rb", []string{"core", "ios", "compose_ios"}, true},
		{"fastlane/lib/dieter/platforms/android.rb", []string{"core", "android"}, true},
		{"fastlane/lib/dieter/distribution/apple.rb", []string{"core"}, false},
		{"tests/e2e/cases/android/machines.telemetry.yaml", []string{"core", "android"}, true},
		{"tests/e2e/cases/ios/ios.credentials.yaml", []string{"core", "ios"}, true},
		{"internal/pipeline/result_test.go", []string{"core"}, false},
		{"apps/mobile/README.md", nil, false},
		{"apps/mobile/android/app/src/main/kotlin/SpikeActivity.kt", []string{"compose_android"}, true},
		{"apps/mobile/ios/App/DieterComposeSpikeApp.swift", []string{"compose_ios"}, true},
		{"apps/mac/Sources/DieterComposeHost/ComposeHost.swift", []string{"compose_ios"}, true},
		{"apps/core/mobile/src/commonMain/kotlin/MobileApp.kt", []string{"compose_core", "compose_android", "compose_ios"}, true},
	} {
		t.Run(test.path, func(t *testing.T) {
			plan := planChecks([]string{test.path}, nil, "base")
			for _, component := range ciComponents {
				if plan.CI[component] != slices.Contains(test.enabled, component) {
					t.Fatalf("CI = %v", plan.CI)
				}
			}
			device := slices.ContainsFunc(plan.Checks, func(check CheckRequest) bool { return check.Operation == "e2e" })
			if device != test.device {
				t.Fatalf("device checks = %v", plan.Checks)
			}
			if test.path == "README.md" && len(plan.Checks) > 0 {
				t.Fatal("documentation selected compilers")
			}
		})
	}
}

func TestComposeChecksTrackReusedDependenciesWithoutReplacingShippingChecks(t *testing.T) {
	for _, path := range []string{"apps/android/app/src/main/java/com/dbpprt/dieter/settings/DieterPalette.kt", "apps/android/app/src/main/java/com/dbpprt/dieter/ui/BoardCardDrag.kt"} {
		plan := planChecks([]string{path}, nil, "base")
		for _, component := range []string{"android", "compose_core", "compose_android", "compose_ios"} {
			if !plan.CI[component] {
				t.Fatalf("%s omitted %s", path, component)
			}
		}
	}
	for _, path := range []string{"native/android-webrtc/sdk.gradle", "apps/android/app/src/main/java/com/dbpprt/dieter/screens/ScreenCanvasHost.kt", "apps/android/app/src/main/java/com/dbpprt/dieter/ui/RemoteTerminalView.kt", "apps/android/app/src/main/java/com/dbpprt/dieter/ui/ComposerAttachments.kt"} {
		plan := planChecks([]string{path}, nil, "base")
		if !plan.CI["android"] || !plan.CI["compose_android"] {
			t.Fatalf("%s missed Android host: %v", path, plan.CI)
		}
	}
	for _, path := range []string{"apps/core/shared/src/commonMain/kotlin/CoreRuntime.kt", "api/proto/dieter/v1/dieter.proto", "tools/fixtures/gateway/compose_fixture.go"} {
		plan := planChecks([]string{path}, nil, "base")
		for _, component := range []string{"kmp", "android", "ios", "macos", "compose_core", "compose_android", "compose_ios"} {
			if !plan.CI[component] {
				t.Fatalf("%s omitted %s", path, component)
			}
		}
	}
	plan := planChecks([]string{"apps/android/app/src/main/java/com/dbpprt/dieter/data/AndroidCredentials.kt"}, nil, "base")
	if !plan.CI["android"] || !plan.CI["compose_android"] || plan.CI["compose_ios"] {
		t.Fatalf("shared Android credentials scope = %v", plan.CI)
	}
	plan = planChecks([]string{".github/workflows/compose-mobile-deliver.yml"}, nil, "base")
	for _, component := range []string{"core", "compose_core", "compose_android", "compose_ios"} {
		if !plan.CI[component] {
			t.Fatalf("workflow omitted %s", component)
		}
	}
	for _, path := range []string{"fastlane/lib/dieter/fixtures/gateway.rb", "internal/harness/runtime/bridge.js", ".github/actions/pipeline-setup/action.yml"} {
		plan := planChecks([]string{path}, nil, "base")
		for _, component := range []string{"compose_core", "compose_android", "compose_ios"} {
			if !plan.CI[component] {
				t.Fatalf("%s omitted %s", path, component)
			}
		}
	}
}
func TestSharedCoreCheckParity(t *testing.T) {
	for _, path := range []string{"api/proto/dieter/v1/dieter.proto", "tools/fixtures/gateway/main.go", "apps/core/shared/src/commonMain/kotlin/CoreRuntime.kt", "apps/core/shared/src/commonTest/kotlin/CoreRuntimeTest.kt", "apps/core/testing/src/commonMain/kotlin/Folds.kt", "apps/core/apple/src/appleMain/kotlin/Shared.kt"} {
		plan := planChecks([]string{path}, nil, "base")
		for _, component := range []string{"core", "mac", "android"} {
			if !checkExists(plan, component, "test_unit") {
				t.Fatalf("%s omitted %s tests: %v", path, component, plan.Checks)
			}
		}
		if !checkExists(plan, "ios", "build") {
			t.Fatal("missing iOS test product compilation")
		}
		if checkExists(plan, "mac", "core_test") || !checkExists(plan, "core", "apple_test") {
			t.Fatal("duplicate or missing bridge integration")
		}
		android := checkExists(plan, "android", "e2e")
		if android != (kotlinAndroidSource(path) || path == "api/proto/dieter/v1/dieter.proto" || path == "tools/fixtures/gateway/main.go") {
			t.Fatalf("wrong Android device scope for %s", path)
		}
		ios := 0
		for _, check := range plan.Checks {
			if check.Component == "ios" && check.Operation == "e2e" {
				ios++
			}
		}
		if ios != 2 {
			t.Fatal("iPhone and iPad both required")
		}
	}
}

func TestPrivacyPackagingSelectsItsIsolatedNativeGate(t *testing.T) {
	for _, path := range []string{"native/macos-privacy/package.sh", "native/macos-privacy/PrivacyHIDService.swift", "native/macos-capture/PrivacyService.swift", "internal/serviceruntime/runtime.go"} {
		plan := planChecks([]string{path}, nil, "base")
		if !checkExists(plan, "mac", "privacy_native_test") {
			t.Fatalf("%s omitted privacy package qualification: %v", path, plan.Checks)
		}
	}
}

func TestOrchestrationContractsDoNotRequireLocalNativeCompilation(t *testing.T) {
	for _, path := range []string{"fastlane/lib/dieter/pipeline/process.rb", "fastlane/lib/dieter/pipeline/evidence.rb", "fastlane/lib/dieter/ci.rb", "fastlane/lib/dieter/config.rb"} {
		plan := planChecks([]string{path}, nil, "")
		if !checkExists(plan, "portable", "contracts") {
			t.Fatalf("missing contracts for %s", path)
		}
		for _, check := range plan.Checks {
			if check.Component != "portable" {
				t.Fatalf("orchestration selected native work: %v", plan.Checks)
			}
		}
		for _, component := range ciComponents {
			if !plan.CI[component] {
				t.Fatalf("shared orchestration omitted CI component %s", component)
			}
		}
	}
}
func TestMacCheckSelectionUsesConservativeMap(t *testing.T) {
	for relative, expected := range macSmokeFiles {
		actual := macChecks([]string{"apps/mac/Sources/DieterMac/" + relative})
		ordered := slices.DeleteFunc(slices.Clone(macSmokeSuites), func(value string) bool { return !slices.Contains(expected, value) })
		if !slices.Equal(actual, ordered) {
			t.Fatalf("%s: %v != %v", relative, actual, ordered)
		}
	}
	paths := []string{"apps/mac/Sources/DieterMac/UI/DieterIslandView.swift", "apps/mac/Sources/DieterMac/Features/Conversation/Composer.swift", "apps/mac/Sources/DieterMac/Features/Terminals/Deleted.swift"}
	expected := []string{"core", "board", "conversation", "terminal", "island", "workspace", "inbox"}
	if !slices.Equal(macChecks(paths), expected) {
		t.Fatalf("union = %v", macChecks(paths))
	}
	paths = append(paths, "apps/mac/Sources/DieterMac/Unknown.swift")
	if !slices.Equal(macChecks(paths), macSmokeSuites) {
		t.Fatal("unknown source must broaden")
	}
}
func TestAffectedGoIncludesEmbeddedDeletedAndTestOnlyImporters(t *testing.T) {
	packages := []goPackage{
		{ImportPath: "dieter/a", Dir: "/repo/a", EmbedFiles: []string{"data.json"}},
		{ImportPath: "dieter/b", Dir: "/repo/b", Imports: []string{"dieter/a"}},
		{ImportPath: "dieter/c", Dir: "/repo/c", XTestImports: []string{"dieter/b"}},
		{ImportPath: "dieter/other", Dir: "/repo/other"},
	}
	for _, path := range []string{"a/a.go", "a/deleted_test.go", "a/data.json", "a/testdata/nested/input.txt"} {
		if !slices.Equal(affectedGo("/repo", []string{path}, packages), []string{"dieter/a", "dieter/b", "dieter/c"}) {
			t.Fatalf("incomplete reverse closure for %s", path)
		}
	}
	if len(affectedGo("/repo", []string{"go.sum"}, packages)) != 4 {
		t.Fatal("module changes must broaden")
	}
}
func TestGoInventoryReadsOnlyStdout(t *testing.T) {
	git, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is unavailable")
	}
	root := t.TempDir()
	if output, err := exec.Command(git, "-C", root, "init").CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte("package main\n"), 0600); err != nil {
		t.Fatal(err)
	}
	// A cold module cache makes go report downloads on stderr.
	bin := t.TempDir()
	fake := "#!/bin/sh\necho 'go: downloading example.com/module v1.0.0' >&2\necho '{\"ImportPath\":\"example.com/root\"}'\n"
	if err := os.WriteFile(filepath.Join(bin, "go"), []byte(fake), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+filepath.Dir(git))
	packages, err := goPackages(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	if len(packages) != 1 || packages[0].ImportPath != "example.com/root" {
		t.Fatalf("packages = %+v", packages)
	}
}
func TestPlannerDoesNotLoadGoForNativeOrDocumentation(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	for _, path := range []string{"README.md", "apps/mac/Sources/View.swift", "apps/android/app/src/test/java/Test.kt"} {
		if _, err := affectedChecks(context.Background(), t.TempDir(), ContractRequest{Paths: []string{path}}); err != nil {
			t.Fatalf("unexpected tool invocation: %v", err)
		}
	}
}
func TestChangedPathsPreserveAllGitStatesAndRenameSides(t *testing.T) {
	root := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-c", "commit.gpgsign=false"}, args...)...)
		cmd.Dir = root
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", args, output, err)
		}
	}
	git("init")
	git("config", "user.email", "test@example.invalid")
	git("config", "user.name", "Test")
	write := func(path, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, path), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"staged", "unstaged", "deleted", "old"} {
		write(name, "original")
	}
	git("add", ".")
	git("commit", "-m", "fixture")
	git("tag", "base")
	write("staged", "staged")
	git("add", "staged")
	write("unstaged", "unstaged")
	os.Remove(filepath.Join(root, "deleted"))
	git("mv", "old", "new name")
	write("untracked\nfile", "new")
	paths, err := changedPaths(context.Background(), root, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"staged", "unstaged", "deleted", "old", "new name", "untracked\nfile"} {
		if !slices.Contains(paths, name) {
			t.Fatalf("missing %q: %v", name, paths)
		}
	}
	git("add", ".")
	git("commit", "-m", "changes")
	paths, err = changedPaths(context.Background(), root, "base")
	if err != nil || !slices.Contains(paths, "old") || !slices.Contains(paths, "deleted") {
		t.Fatalf("base comparison: %v, %v", paths, err)
	}
}
func TestSharedOrchestrationBroadensCIAndPreservesBase(t *testing.T) {
	plan := planChecks([]string{"fastlane/lib/dieter/pipeline/engine.rb"}, nil, "base-sha")
	for _, enabled := range plan.CI {
		if !enabled {
			t.Fatal("shared pipeline must validate every client")
		}
	}
	for _, check := range plan.Checks {
		if check.Component == "android" && check.Operation == "e2e" && check.Options["changed"] == "true" && check.Options["base"] != "base-sha" {
			t.Fatal("lost comparison base")
		}
	}
}
