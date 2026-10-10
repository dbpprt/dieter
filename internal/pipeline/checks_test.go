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

// checkKeys renders every planned check with its options, sorted.
func checkKeys(plan CheckPlan) []string {
	keys := []string{}
	for _, check := range plan.Checks {
		key := check.Component + ":" + check.Operation
		options := []string{}
		for name, value := range check.Options {
			options = append(options, name+"="+value)
		}
		slices.Sort(options)
		for _, option := range options {
			key += " " + option
		}
		keys = append(keys, key)
	}
	slices.Sort(keys)
	return keys
}

var (
	androidGate = []string{"android:build", "android:e2e profile=android-emulator", "android:test_unit"}
	iosGate     = []string{"ios:build", "ios:e2e profiles=ios-iphone,ios-ipad"}
)

func sortedKeys(groups ...[]string) []string {
	keys := []string{}
	for _, group := range groups {
		keys = append(keys, group...)
	}
	slices.Sort(keys)
	return keys
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
		{"apps/android/app/src/main/kotlin/com/dbpprt/dieter/MainActivity.kt", []string{"android"}, true},
		{"apps/android/app/src/main/kotlin/com/dbpprt/dieter/screens/ScreenCanvasHost.kt", []string{"android"}, true},
		{"apps/android/app/src/main/java/org/webrtc/DieterLowLatencyDecoderFactory.java", []string{"android"}, true},
		{"apps/android/app/src/androidTest/kotlin/com/dbpprt/dieter/JourneyTest.kt", []string{"android"}, true},
		{"native/android-webrtc/build_sdk.py", []string{"android"}, true},
		{"apps/mac/Tests/DieterMacTests/Test.swift", []string{"macos"}, false},
		{"apps/mac/Sources/DieterMac/UI/BoardView.swift", []string{"macos"}, true},
		{"apps/ios/App/DieterApp.swift", []string{"ios"}, true},
		{"apps/ios/Tests/JourneyUITests.swift", []string{"ios"}, true},
		{"apps/ios/Dieter.xcodeproj/project.pbxproj", []string{"ios"}, true},
		{"apps/mac/Sources/DieterIOS/ComposeHost.swift", []string{"ios"}, true},
		{"apps/mac/Sources/DieterTransport/ControlRTCBridge.swift", []string{"macos", "ios"}, true},
		{"apps/mac/MarkdownPreview/src/chart.js", []string{"core", "macos"}, true},
		{"apps/core/mobile/README.md", nil, false},
		{"apps/core/mobile/src/commonMain/kotlin/com/dbpprt/dieter/mobile/ManagementScreens.kt", []string{"kmp", "android", "ios"}, true},
		{"apps/core/mobile/src/jvmTest/kotlin/com/dbpprt/dieter/ui/BoardCardDragTest.kt", []string{"kmp", "android", "ios"}, true},
		{"apps/core/shared/src/commonMain/kotlin/CoreRuntime.kt", []string{"kmp", "macos", "ios", "android"}, true},
		{"fastlane/lib/dieter/platforms/ios.rb", []string{"core", "ios"}, true},
		{"fastlane/lib/dieter/platforms/android.rb", []string{"core", "android"}, true},
		{"fastlane/lib/dieter/platforms/emulator.rb", []string{"core", "android"}, true},
		{"fastlane/lib/dieter/fixtures/gateway.rb", []string{"core", "android", "ios"}, true},
		{"internal/harness/runtime/bridge.js", []string{"core", "android", "ios"}, true},
		{"config/harnesses.yaml", []string{"core", "android", "ios"}, true},
		{"tools/fixtures/gateway/mobile_fixture.go", ciComponents, true},
		{"fastlane/lib/dieter/distribution/apple.rb", []string{"core"}, false},
		{"tests/e2e/cases/android/journey.yaml", []string{"core", "android"}, true},
		{"tests/e2e/cases/ios/journey.yaml", []string{"core", "ios"}, true},
		{"internal/pipeline/result_test.go", []string{"core"}, false},
	} {
		t.Run(test.path, func(t *testing.T) {
			plan := planChecks([]string{test.path}, nil)
			for _, component := range ciComponents {
				if plan.CI[component] != slices.Contains(test.enabled, component) {
					t.Fatalf("CI = %v", plan.CI)
				}
			}
			if len(plan.CI) != len(ciComponents) {
				t.Fatalf("unknown CI components: %v", plan.CI)
			}
			device := slices.ContainsFunc(plan.Checks, func(check CheckRequest) bool { return check.Operation == "e2e" })
			if device != test.device {
				t.Fatalf("device checks = %v", plan.Checks)
			}
			if test.enabled == nil && len(plan.Checks) > 0 {
				t.Fatal("documentation selected compilers")
			}
		})
	}
}

// Each mobile app runs its own build and journey; there is no iOS unit lane,
// Android screens suite or separate Compose check.
func TestMobileAppChecksSelectExactGates(t *testing.T) {
	for _, test := range []struct {
		paths []string
		want  []string
	}{
		{[]string{"apps/android/app/src/main/kotlin/com/dbpprt/dieter/MainActivity.kt"}, androidGate},
		{[]string{"apps/android/app/src/main/kotlin/com/dbpprt/dieter/screens/ScreenCanvasHost.kt"}, androidGate},
		{[]string{"apps/android/app/src/main/java/org/webrtc/DieterLowLatencyDecoderFactory.java"}, androidGate},
		{[]string{"apps/android/app/build.gradle.kts"}, androidGate},
		{[]string{"native/android-webrtc/sdk.gradle"}, androidGate},
		{[]string{"apps/ios/App/DieterApp.swift"}, iosGate},
		{[]string{"apps/ios/Tests/JourneyUITests.swift"}, iosGate},
		{[]string{"apps/mac/Sources/DieterIOS/NativeViews.swift"}, iosGate},
		// The shared Compose UI: core test_unit runs its JVM tests; the Mac does not link it.
		{[]string{"apps/core/mobile/src/commonMain/kotlin/com/dbpprt/dieter/ui/BoardCardDrag.kt"}, sortedKeys([]string{"core:test_unit"}, androidGate, iosGate)},
		{[]string{"apps/core/mobile/src/iosMain/kotlin/com/dbpprt/dieter/mobile/MobileHost.kt"}, sortedKeys([]string{"core:test_unit"}, androidGate, iosGate)},
		// Both journeys run real turns through the mock harness of the gateway fixture.
		{[]string{"fastlane/lib/dieter/fixtures/gateway.rb"}, sortedKeys(androidGate, iosGate)},
		{[]string{"internal/harness/runtime/bridge.js"}, sortedKeys([]string{"portable:harness_test"}, androidGate, iosGate)},
		{[]string{"config/harnesses.yaml"}, sortedKeys([]string{"portable:harness_test"}, androidGate, iosGate)},
		// Both apps together still plan each gate once.
		{[]string{"apps/android/app/src/main/kotlin/com/dbpprt/dieter/MainActivity.kt", "apps/ios/App/DieterApp.swift", "apps/core/mobile/src/commonMain/kotlin/com/dbpprt/dieter/settings/DieterPalette.kt"}, sortedKeys([]string{"core:test_unit"}, androidGate, iosGate)},
	} {
		if got := checkKeys(planChecks(test.paths, nil)); !slices.Equal(got, test.want) {
			t.Errorf("%v planned %v, want %v", test.paths, got, test.want)
		}
	}
}

func TestSharedCoreCheckParity(t *testing.T) {
	for _, path := range []string{"api/proto/dieter/v1/dieter.proto", "tools/fixtures/gateway/main.go", "apps/core/shared/src/commonMain/kotlin/CoreRuntime.kt", "apps/core/shared/src/commonTest/kotlin/CoreRuntimeTest.kt", "apps/core/testing/src/commonMain/kotlin/Folds.kt", "apps/core/apple/src/appleMain/kotlin/Shared.kt", "fastlane/lib/dieter/platforms/core.rb"} {
		plan := planChecks([]string{path}, nil)
		for _, component := range []string{"core", "mac", "android"} {
			if !checkExists(plan, component, "test_unit") {
				t.Fatalf("%s omitted %s tests: %v", path, component, plan.Checks)
			}
		}
		if checkExists(plan, "ios", "test_unit") || !checkExists(plan, "ios", "build") || !checkExists(plan, "android", "build") {
			t.Fatalf("%s: wrong mobile compilation: %v", path, plan.Checks)
		}
		if checkExists(plan, "mac", "core_test") || !checkExists(plan, "core", "apple_test") {
			t.Fatal("duplicate or missing bridge integration")
		}
		for _, component := range []string{"kmp", "macos", "ios", "android"} {
			if !plan.CI[component] {
				t.Fatalf("%s omitted CI %s", path, component)
			}
		}
		journeys := map[string]map[string]string{}
		for _, check := range plan.Checks {
			if check.Operation == "e2e" {
				if _, duplicate := journeys[check.Component]; duplicate {
					t.Fatalf("%s planned %s e2e twice", path, check.Component)
				}
				journeys[check.Component] = check.Options
			}
		}
		if journeys["android"]["profile"] != "android-emulator" || len(journeys["android"]) != 1 {
			t.Fatalf("%s: Android journey = %v", path, journeys["android"])
		}
		if journeys["ios"]["profiles"] != "ios-iphone,ios-ipad" || len(journeys["ios"]) != 1 {
			t.Fatalf("%s: iPhone and iPad both required: %v", path, journeys["ios"])
		}
		if journeys["mac"]["suite"] != "smoke" {
			t.Fatalf("%s: shared core must run the full Mac smoke: %v", path, journeys["mac"])
		}
	}
	// The Compose UI is not linked by the Mac and has no Apple bridge.
	plan := planChecks([]string{"apps/core/mobile/src/commonMain/kotlin/com/dbpprt/dieter/mobile/ManagementScreens.kt"}, nil)
	if !checkExists(plan, "core", "test_unit") || checkExists(plan, "core", "apple_test") || checkExists(plan, "mac", "test_unit") || checkExists(plan, "mac", "e2e") || plan.CI["macos"] {
		t.Fatalf("Compose UI scope = %v %v", plan.Checks, plan.CI)
	}
	// The Swift side of the bridge reaches both Apple apps, not Android.
	plan = planChecks([]string{"apps/mac/Sources/SharedCore/CoreHost.swift"}, nil)
	if !checkExists(plan, "mac", "core_test") || checkExists(plan, "core", "apple_test") || !checkExists(plan, "ios", "e2e") || checkExists(plan, "android", "e2e") || plan.CI["android"] {
		t.Fatalf("bridge scope = %v %v", plan.Checks, plan.CI)
	}
}

func TestPrivacyPackagingSelectsItsIsolatedNativeGate(t *testing.T) {
	for _, path := range []string{"native/macos-privacy/package.sh", "native/macos-privacy/PrivacyHIDService.swift", "native/macos-capture/PrivacyService.swift", "internal/serviceruntime/runtime.go"} {
		plan := planChecks([]string{path}, nil)
		if !checkExists(plan, "mac", "privacy_native_test") {
			t.Fatalf("%s omitted privacy package qualification: %v", path, plan.Checks)
		}
	}
}

func TestOrchestrationContractsDoNotRequireLocalNativeCompilation(t *testing.T) {
	for _, path := range []string{"fastlane/lib/dieter/pipeline/process.rb", "fastlane/lib/dieter/pipeline/evidence.rb", "fastlane/lib/dieter/ci.rb", "fastlane/lib/dieter/config.rb", "fastlane/lib/dieter/pipeline/engine.rb", "internal/pipeline/checks.go", ".github/workflows/ci.yml", ".github/workflows/qualification.yml", ".github/actions/pipeline-setup/action.yml", "justfile"} {
		plan := planChecks([]string{path}, nil)
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
	for _, path := range []string{"README.md", "apps/mac/Sources/View.swift", "apps/android/app/src/main/kotlin/com/dbpprt/dieter/MainActivity.kt", "native/android-webrtc/sdk.gradle", "apps/core/mobile/src/commonMain/kotlin/App.kt"} {
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
