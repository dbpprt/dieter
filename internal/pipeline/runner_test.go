package pipeline

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

// Navigation flows are Mac-only; Android and iOS run native journeys.
const validCase = `version: 1
id: mac.flow
platform: mac
suites: [smoke]
components: [board]
fixture: gateway
timeout: 30s
steps:
  - launch: connected
  - tap: {id: board}
  - expect: {id: lane, visible: true}
`

const androidJourney = `version: 1
id: android.journey
platform: android
suites: [smoke]
components: [android]
fixture: gateway
timeout: 10m
native:
  class: com.dbpprt.dieter.JourneyTest
  methods: [sharedTaskJourney]
`

const iosJourney = `version: 1
id: ios.journey
platform: ios
suites: [smoke]
components: [ios]
fixture: gateway
timeout: 15m
native:
  target: DieterUITests
  class: JourneyUITests
  methods: [testSharedTaskJourney]
`

func TestCaseValidation(t *testing.T) {
	c, err := decodeCase([]byte(validCase), "case.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if c.Steps[1].Line != 10 {
		t.Fatalf("source line lost: %+v", c.Steps)
	}
	if _, err := decodeCase([]byte(validCase+"  - screenshot: board-ready\n"), "case.yaml"); err != nil {
		t.Fatal(err)
	}
	for name, input := range map[string]string{
		"unknown field":         validCase + "shell: rm\n",
		"version":               strings.Replace(validCase, "version: 1", "version: 2", 1),
		"duplicate":             validCase + "id: another\n",
		"documents":             validCase + "---\n" + validCase,
		"ambiguous selector":    strings.Replace(validCase, "{id: board}", "{id: board, text: board}", 1),
		"alias":                 strings.Replace(validCase, "{id: board}", "&target {id: board}", 1),
		"contradictory absence": strings.Replace(validCase, "visible: true", "visible: false, enabled: true", 1),
		"empty assertion":       strings.Replace(validCase, ", visible: true", "", 1),
		"unbounded":             strings.Replace(validCase, "30s", "1h", 1),
		"action count":          strings.Replace(validCase, "launch: connected", "launch: connected\n    screenshot: board", 1),
		"unknown launch":        strings.Replace(validCase, "launch: connected", "launch: offline", 1),
		"screenshot name":       validCase + "  - screenshot: Board!\n",
		"flow without gateway":  strings.Replace(validCase, "fixture: gateway", "fixture: none", 1),
		"no actions or native":  strings.SplitAfter(validCase, "timeout: 30s\n")[0],
		"android flow":          strings.Replace(validCase, "platform: mac", "platform: android", 1),
		"ios flow":              strings.Replace(validCase, "platform: mac", "platform: ios", 1),
		// Removed Android flow actions, build variants, arguments and fixtures.
		"type action":      strings.Replace(validCase, "tap: {id: board}", "type: {id: board, value: text}", 1),
		"press action":     strings.Replace(validCase, "launch: connected", "press: back", 1),
		"scroll action":    strings.Replace(validCase, "tap: {id: board}", "scroll: {within: {id: lane}, until: {id: card}}", 1),
		"probe action":     strings.Replace(validCase, "tap: {id: board}", "probe: machine-telemetry", 1),
		"performance":      validCase + "build: performance\n",
		"arguments":        validCase + "arguments: {forceTURN: '1'}\n",
		"activity fixture": strings.Replace(validCase, "fixture: gateway", "fixture: activity", 1),
		"screen fixture":   strings.Replace(validCase, "fixture: gateway", "fixture: screen", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeCase([]byte(input), "bad.yaml"); err == nil {
				t.Fatal("accepted invalid case")
			}
		})
	}
}

func TestNativeJourneyCaseValidation(t *testing.T) {
	for name, input := range map[string]string{
		"android":     androidJourney,
		"ios":         iosJourney,
		"ipad only":   strings.Replace(iosJourney, "timeout:", "devices: [ipad]\ntimeout:", 1),
		"android sub": strings.Replace(androidJourney, "com.dbpprt.dieter.JourneyTest", "com.dbpprt.dieter.e2e.JourneyTest", 1),
	} {
		if _, err := decodeCase([]byte(input), name+".yaml"); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
	for name, input := range map[string]string{
		"android webrtc class":     strings.Replace(androidJourney, "com.dbpprt.dieter.JourneyTest", "org.webrtc.PeerConnectionTest", 1),
		"android unqualified":      strings.Replace(androidJourney, "com.dbpprt.dieter.JourneyTest", "JourneyTest", 1),
		"android target":           strings.Replace(androidJourney, "  class:", "  target: DieterUITests\n  class:", 1),
		"android Mac suite":        strings.Replace(androidJourney, "  class:", "  suite: core\n  class:", 1),
		"android Mac checks":       strings.Replace(androidJourney, "  class:", "  checks: [core.window]\n  class:", 1),
		"android no methods":       strings.Replace(androidJourney, "[sharedTaskJourney]", "[]", 1),
		"android duplicate method": strings.Replace(androidJourney, "[sharedTaskJourney]", "[sharedTaskJourney, sharedTaskJourney]", 1),
		"android invalid method":   strings.Replace(androidJourney, "[sharedTaskJourney]", "['shared-task']", 1),
		"android devices":          strings.Replace(androidJourney, "timeout:", "devices: [iphone]\ntimeout:", 1),
		"android deadline":         strings.Replace(androidJourney, "10m", "11m", 1),
		"android with steps":       androidJourney + "steps:\n  - launch: connected\n",
		"android screen fixture":   strings.Replace(androidJourney, "fixture: gateway", "fixture: screen", 1),
		"android arguments":        androidJourney + "arguments: {screenSurface: '1'}\n",
		"android performance":      androidJourney + "build: performance\n",
		"ios old target":           strings.Replace(iosJourney, "DieterUITests", "DieterIOSUITests", 1),
		"ios native target":        strings.Replace(iosJourney, "DieterUITests", "DieterIOSNativeTests", 1),
		"ios missing target":       strings.Replace(iosJourney, "  target: DieterUITests\n", "", 1),
		"ios qualified class":      strings.Replace(iosJourney, "class: JourneyUITests", "class: com.dbpprt.dieter.JourneyUITests", 1),
		"ios duplicate device":     strings.Replace(iosJourney, "timeout:", "devices: [iphone, iphone]\ntimeout:", 1),
		"ios unknown device":       strings.Replace(iosJourney, "timeout:", "devices: [watch]\ntimeout:", 1),
		"ios activity fixture":     strings.Replace(iosJourney, "fixture: gateway", "fixture: activity", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeCase([]byte(input), "bad.yaml"); err == nil {
				t.Fatal("accepted invalid case")
			}
		})
	}
}

func TestExactNativeResults(t *testing.T) {
	n := Native{Class: "com.dbpprt.dieter.JourneyTest", Methods: []string{"sharedTaskJourney"}}
	for _, v := range []struct{ output, want string }{
		{nativeOutput("0"), "passed"},
		{nativeOutput("-2"), "failed"},
		{nativeOutput("-3"), "unavailable"},
		{nativeOutput("-4"), "unavailable"},
		{"", "failed"},
		{"INSTRUMENTATION_CODE: -1\n", "failed"},
		{"INSTRUMENTATION_FAILED: com.dbpprt.dieter.e2e/androidx.test.runner.AndroidJUnitRunner\n", "failed"},
		{strings.ReplaceAll(nativeOutput("0"), "sharedTaskJourney", "other"), "failed"},
		{strings.ReplaceAll(nativeOutput("0"), "com.dbpprt.dieter.JourneyTest", "com.dbpprt.dieter.e2e.FlowTest"), "failed"},
		{nativeOutput("0") + nativeOutput("0"), "failed"},
		{strings.ReplaceAll(nativeOutput("0"), "INSTRUMENTATION_CODE: -1\n", ""), "failed"},
		{strings.ReplaceAll(nativeOutput("0"), "INSTRUMENTATION_CODE: -1", "INSTRUMENTATION_CODE: 0"), "failed"},
	} {
		got, reason := instrumentationResult(v.output, n)
		if got != v.want {
			t.Errorf("got %s (%s), want %s", got, reason, v.want)
		}
	}
}

// Every platform qualifies against its explicit native case; Android has no
// implicit FlowTest fallback.
func TestQualifyRequiresExplicitNativeCase(t *testing.T) {
	dir := t.TempDir()
	instrumentation := filepath.Join(dir, "instrumentation.txt")
	if err := os.WriteFile(instrumentation, []byte(nativeOutput("0")), 0600); err != nil {
		t.Fatal(err)
	}
	qualify := func(request map[string]any) (map[string]string, error) {
		input, _ := json.Marshal(request)
		var output bytes.Buffer
		if err := Contract(context.Background(), dir, []string{"qualify"}, bytes.NewReader(input), &output); err != nil {
			return nil, err
		}
		var result map[string]string
		err := json.Unmarshal(output.Bytes(), &result)
		return result, err
	}
	journey, err := decodeCase([]byte(androidJourney), "journey.yaml")
	if err != nil {
		t.Fatal(err)
	}
	result, err := qualify(map[string]any{"platform": "android", "path": instrumentation, "case": journey})
	if err != nil || result["status"] != "passed" {
		t.Fatalf("journey qualification = %v, %v", result, err)
	}
	flow := journey
	flow.Native = nil
	for _, platform := range []string{"android", "ios", "mac"} {
		if _, err := qualify(map[string]any{"platform": platform, "path": instrumentation, "case": flow}); err == nil {
			t.Fatalf("%s qualified a case without native methods", platform)
		}
	}
	if _, err := qualify(map[string]any{"platform": "android", "path": instrumentation}); err == nil {
		t.Fatal("qualified without a case")
	}
}

func TestContractRejectsRemovedOperations(t *testing.T) {
	var help bytes.Buffer
	if err := Contract(context.Background(), t.TempDir(), []string{"--help"}, strings.NewReader(""), &help); err != nil {
		t.Fatal(err)
	}
	for _, operation := range []string{"extract", "ios-console", "screen-normalize"} {
		if strings.Contains(help.String(), operation) {
			t.Fatalf("help still lists %s", operation)
		}
		var output bytes.Buffer
		if err := Contract(context.Background(), t.TempDir(), []string{operation}, strings.NewReader("{}"), &output); err == nil || !strings.Contains(err.Error(), "unknown contract operation") {
			t.Fatalf("%s: %v", operation, err)
		}
	}
}

func TestDeviceLeaseOwnership(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lease")
	unlock, err := acquireLease(path)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := acquireLease(path); err == nil {
		second()
		t.Fatal("admitted concurrent device owner")
	}
	unlock()
	next, err := acquireLease(path)
	if err != nil {
		t.Fatal(err)
	}
	next()
	if _, err = os.Stat(path); err != nil {
		t.Fatal("lease inode must remain")
	}
}
func TestOwnedProcessStopsWithoutTouchingOtherProcess(t *testing.T) {
	p, err := startOwned(t.TempDir(), "/bin/sleep", "30")
	if err != nil {
		t.Fatal(err)
	}
	if err = p.stop(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-p.done:
	default:
		t.Fatal("child not reaped")
	}
}
func TestCommandCancellation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := command(ctx, t.TempDir(), nil, "/bin/sleep", "30")
	if err == nil || time.Since(start) > time.Second {
		t.Fatal("cancellation did not stop child promptly")
	}
}
func TestBoundedOutputAndShellQuoting(t *testing.T) {
	b := &tailBuffer{limit: 4}
	_, _ = b.Write([]byte("abcdef"))
	if b.String() != "cdef" {
		t.Fatal(b.String())
	}
	if shellArgs([]string{"hello world", "x'y"}) != "'hello world' 'x'\"'\"'y'" {
		t.Fatal("unsafe ADB argument quoting")
	}
}

// Device work narrows by platform only: each app's own sources select its
// journey and share cases, and shared or fixture paths select every platform.
func TestAffectedNarrowsMobileJourneysByPlatform(t *testing.T) {
	cases := []Case{{ID: "android.journey", Platform: "android"}, {ID: "android.share", Platform: "android"}, {ID: "ios.journey", Platform: "ios"}, {ID: "ios.share", Platform: "ios"}, {ID: "mac.core", Platform: "mac"}}
	android := []string{"android.journey", "android.share"}
	ios := []string{"ios.journey", "ios.share"}
	all := []string{"android.journey", "android.share", "ios.journey", "ios.share", "mac.core"}
	for _, tc := range []struct {
		path string
		want []string
	}{
		{"apps/android/app/src/main/kotlin/com/dbpprt/dieter/MainActivity.kt", android},
		{"apps/android/app/src/main/kotlin/com/dbpprt/dieter/screens/ScreenCanvasHost.kt", android},
		{"apps/android/app/src/main/java/org/webrtc/DieterLowLatencyDecoderFactory.java", android},
		{"apps/android/app/src/androidTest/kotlin/com/dbpprt/dieter/JourneyTest.kt", android},
		{"apps/android/app/build.gradle.kts", android},
		{"native/android-webrtc/build_sdk.py", android},
		{"fastlane/lib/dieter/platforms/emulator.rb", android},
		{"tests/e2e/cases/android/journey.yaml", android},
		{"apps/ios/App/DieterApp.swift", ios},
		{"apps/ios/Tests/JourneyUITests.swift", ios},
		{"apps/ios/Dieter.xcodeproj/project.pbxproj", ios},
		{"apps/mac/Sources/DieterIOS/ComposeHost.swift", ios},
		{"tests/e2e/cases/ios/journey.yaml", ios},
		{"apps/mac/Sources/DieterMac/UI/BoardView.swift", []string{"mac.core"}},
		{"apps/core/mobile/src/commonMain/kotlin/com/dbpprt/dieter/mobile/ManagementScreens.kt", append(slices.Clone(android), ios...)},
		{"apps/core/mobile/src/androidMain/kotlin/com/dbpprt/dieter/mobile/AndroidShare.kt", android},
		{"apps/ios/Share/ShareViewController.swift", ios},
		{"apps/mac/Sources/DieterIOS/ShareInbox.swift", ios},
		{"fastlane/lib/dieter/native/ios_e2e_metadata.py", ios},
		{"fastlane/lib/dieter/fixtures/ios_media.rb", all},
		{"api/proto/dieter/v1/dieter.proto", all},
		{"tests/e2e/deleted.yaml", all},
		{"tools/fixtures/gateway/mobile_fixture.go", all},
		{"fastlane/lib/dieter/fixtures/gateway.rb", all},
		{"docs/plan.md", nil},
		{"apps/android/README.md", nil},
	} {
		got := []string{}
		for _, c := range affected(cases, []string{tc.path}) {
			got = append(got, c.ID)
		}
		if !slices.Equal(got, tc.want) {
			t.Errorf("%s selected %v, want %v", tc.path, got, tc.want)
		}
	}
}
func TestCatalogValid(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	c, err := catalog(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(c) < 2 {
		t.Fatal("missing cases")
	}
}

// Android and iOS each qualify one native journey against the gateway fixture.
func TestMobileCatalogHoldsNativeJourneys(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	cases, err := catalog(root)
	if err != nil {
		t.Fatal(err)
	}
	journeys := map[string]Case{}
	for _, c := range cases {
		if c.Platform == "mac" {
			continue
		}
		if c.Native == nil || len(c.Steps) != 0 || c.Fixture != "gateway" {
			t.Fatalf("%s is not a native gateway journey", c.ID)
		}
		journeys[c.ID] = c
	}
	android, ok := journeys["android.journey"]
	if !ok || android.Native.Class != "com.dbpprt.dieter.JourneyTest" || !slices.Equal(android.Native.Methods, []string{"sharedTaskJourney"}) {
		t.Fatalf("Android journey = %+v", android.Native)
	}
	ios, ok := journeys["ios.journey"]
	if !ok || ios.Native.Target != "DieterUITests" || ios.Native.Class != "JourneyUITests" || !slices.Equal(ios.Native.Methods, []string{"testSharedTaskJourney"}) {
		t.Fatalf("iOS journey = %+v", ios.Native)
	}
	// The iOS journey runs on both layouts of one simulator build.
	for _, target := range []struct{ platform, device string }{{"android", ""}, {"ios", "iphone"}, {"ios", "ipad"}} {
		input, _ := json.Marshal(map[string]any{"platform": target.platform, "device": target.device, "suite": "smoke"})
		var output bytes.Buffer
		if err := Contract(context.Background(), root, []string{"plan"}, bytes.NewReader(input), &output); err != nil {
			t.Fatalf("%v smoke plan: %v", target, err)
		}
		var plan struct{ Cases []Case }
		if err := json.Unmarshal(output.Bytes(), &plan); err != nil || !slices.ContainsFunc(plan.Cases, func(c Case) bool { return c.ID == target.platform+".journey" }) {
			t.Fatalf("%v smoke plan omitted its journey: %s", target, output.String())
		}
	}
}

// References resolve only against the Android and iOS journey sources and the
// Mac smoke runners; sources of the deleted native apps are not consulted.
func TestJourneyReferencesResolveAgainstTestRoots(t *testing.T) {
	root := t.TempDir()
	write := func(path, content string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(filepath.Join(root, path)), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, path), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("apps/android/app/src/androidTest/kotlin/com/dbpprt/dieter/JourneyTest.kt", "package com.dbpprt.dieter\n\nclass JourneyTest {\n    @Test\n    fun sharedTaskJourney() {}\n}\n")
	write("apps/ios/Tests/JourneyUITests.swift", "import XCTest\n\nfinal class JourneyUITests: XCTestCase {\n    func testSharedTaskJourney() throws {}\n}\n")
	write("apps/mac/Sources/DieterMac/Testing/NativeUISmokeRunner.swift", "enum NativeUISmokeRunner {}\n")
	// Sources of the replaced native apps.
	write("apps/android/app/src/main/java/com/dbpprt/dieter/e2e/FlowTest.kt", "package com.dbpprt.dieter.e2e\n\nclass FlowTest {\n    fun runFlow() {}\n}\n")
	write("apps/ios/DieterIOSUITests/RemoteNodeUITests.swift", "final class RemoteNodeUITests: XCTestCase {\n    func testOne() {}\n}\n")
	write("apps/mac/Tests/DieterIOSTests/IOSCoreAdapterTests.swift", "final class IOSCoreAdapterTests: XCTestCase {\n    func testAdapter() {}\n}\n")
	android := Case{ID: "android.journey", Platform: "android", Source: "android.yaml", Native: &Native{Class: "com.dbpprt.dieter.JourneyTest", Methods: []string{"sharedTaskJourney"}}}
	ios := Case{ID: "ios.journey", Platform: "ios", Source: "ios.yaml", Native: &Native{Target: "DieterUITests", Class: "JourneyUITests", Methods: []string{"testSharedTaskJourney"}}}
	mac := Case{ID: "mac.core", Platform: "mac", Source: "mac.yaml", Native: &Native{Suite: "core", Checks: []string{"core.window"}}}
	if err := validateReferences(root, []Case{android, ios, mac}); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]Case{
		"renamed Android method": {Platform: "android", Native: &Native{Class: "com.dbpprt.dieter.JourneyTest", Methods: []string{"renamedJourney"}}},
		"renamed iOS method":     {Platform: "ios", Native: &Native{Target: "DieterUITests", Class: "JourneyUITests", Methods: []string{"testRenamed"}}},
		"wrong Android package":  {Platform: "android", Native: &Native{Class: "com.dbpprt.dieter.e2e.JourneyTest", Methods: []string{"sharedTaskJourney"}}},
		"Android FlowTest":       {Platform: "android", Native: &Native{Class: "com.dbpprt.dieter.e2e.FlowTest", Methods: []string{"runFlow"}}},
		"old iOS UI tests":       {Platform: "ios", Native: &Native{Target: "DieterUITests", Class: "RemoteNodeUITests", Methods: []string{"testOne"}}},
		"old iOS adapter tests":  {Platform: "ios", Native: &Native{Target: "DieterUITests", Class: "IOSCoreAdapterTests", Methods: []string{"testAdapter"}}},
		"missing Mac runner":     {Platform: "mac", Native: &Native{Suite: "terminal", Checks: []string{"create.window"}}},
	} {
		if err := validateReferences(root, []Case{c}); err == nil {
			t.Errorf("%s: accepted an unresolved reference", name)
		}
	}
	// Both journey roots are required.
	if err := os.RemoveAll(filepath.Join(root, "apps/ios/Tests")); err != nil {
		t.Fatal(err)
	}
	if err := validateReferences(root, []Case{android}); err == nil {
		t.Fatal("accepted a missing iOS journey root")
	}
}
func TestRequiredUnavailableCaseFailsJUnit(t *testing.T) {
	dir := t.TempDir()
	err := writeReport(dir, Report{Platform: "android", Results: []Result{{ID: "missing", Status: "unavailable", Reason: "no device"}}})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "junit.xml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `failures="1"`) {
		t.Fatal(string(data))
	}
}

func TestAndroidNativeCoverageInventory(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	cases, err := catalog(root)
	if err != nil {
		t.Fatal(err)
	}
	registered := map[string]bool{}
	for _, c := range cases {
		if c.Platform == "android" && c.Native != nil {
			for _, m := range c.Native.Methods {
				registered[m] = true
			}
		}
	}
	method := regexp.MustCompile(`@Test\s+(?:public\s+)?(?:fun|void)\s+(\w+)`)
	found := 0
	err = filepath.WalkDir(filepath.Join(root, "apps/android/app/src/androidTest"), func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !(strings.HasSuffix(path, ".kt") || strings.HasSuffix(path, ".java")) {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, m := range method.FindAllStringSubmatch(string(data), -1) {
			found++
			if !registered[m[1]] {
				t.Errorf("uncataloged native test %s in %s", m[1], path)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if found == 0 {
		t.Fatal("no Android instrumentation tests found")
	}
}

func nativeOutput(code string) string {
	return "INSTRUMENTATION_STATUS: class=com.dbpprt.dieter.JourneyTest\nINSTRUMENTATION_STATUS: test=sharedTaskJourney\nINSTRUMENTATION_STATUS_CODE: 1\nINSTRUMENTATION_STATUS: class=com.dbpprt.dieter.JourneyTest\nINSTRUMENTATION_STATUS: test=sharedTaskJourney\nINSTRUMENTATION_STATUS_CODE: " + code + "\nINSTRUMENTATION_CODE: -1\n"
}
