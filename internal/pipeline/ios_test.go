package pipeline

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIOSDestinationRequiresInstalledRuntime(t *testing.T) {
	inventory := `{"devicetypes":[{"name":"iPhone 17 Pro","identifier":"phone"},{"name":"iPad Pro 11-inch (M5)","identifier":"pad"}],"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-9","version":"26.9","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-10","version":"26.10","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27","version":"27.0","isAvailable":false}]}`
	for _, device := range []string{"iphone", "ipad"} {
		kind, rt, err := iosDestination([]byte(inventory), device)
		if err != nil || kind == "" || !strings.HasSuffix(rt, "26-10") {
			t.Fatal(kind, rt, err)
		}
	}
	for _, data := range []string{`{}`, `not json`, strings.ReplaceAll(inventory, `"isAvailable":true`, `"isAvailable":false`)} {
		if _, _, err := iosDestination([]byte(data), "iphone"); err == nil {
			t.Fatal("accepted unavailable runtime")
		}
	}
}
func TestIOSConfigRelocatesProductsAndInjectsOnlySelectedTarget(t *testing.T) {
	var spec any
	if err := json.Unmarshal([]byte(`{"TestConfigurations":[{"TestTargets":[{"BlueprintName":"DieterUITests","TestBundlePath":"__TESTROOT__/UI.xctest","EnvironmentVariables":{"EXISTING":"retained"},"DependentProductPaths":["__TESTROOT__/Dieter.app"]},{"BlueprintName":"OtherTests","TestBundlePath":"__TESTROOT__/Other.xctest"}]}]}`), &spec); err != nil {
		t.Fatal(err)
	}
	if count := configureIOSTestRun(spec, "/products", map[string]string{"TOKEN": "private-token"}, "DieterUITests"); count != 1 {
		t.Fatal(count)
	}
	data, _ := json.Marshal(spec)
	s := string(data)
	if strings.Contains(s, "__TESTROOT__") || strings.Count(s, "private-token") != 1 || !strings.Contains(s, "retained") || !strings.Contains(s, "/products/Dieter.app") {
		t.Fatal(s)
	}
	var missing any
	_ = json.Unmarshal([]byte(`{"TestTargets":[{"BlueprintName":"DieterIOSUITests","TestBundlePath":"__TESTROOT__/UI.xctest"}]}`), &missing)
	if count := configureIOSTestRun(missing, "/products", nil, "DieterUITests"); count != 0 {
		t.Fatal("configured a target other than DieterUITests")
	}
}
func TestIOSExactMethodQualification(t *testing.T) {
	n := Native{Target: "DieterUITests", Class: "JourneyUITests", Methods: []string{"testSharedTaskJourney", "testTwo"}}
	node := func(id, result string) iosTestNode { return iosTestNode{Type: "Test Case", ID: id, Result: result} }
	good := []iosTestNode{node("JourneyUITests/testSharedTaskJourney()", "Passed"), node("DieterUITests/JourneyUITests/testTwo()", "Passed")}
	for _, tc := range []struct {
		name  string
		nodes []iosTestNode
		pass  bool
	}{
		{"complete", good, true}, {"missing", good[:1], false}, {"empty", nil, false},
		{"skip", []iosTestNode{good[0], node("JourneyUITests/testTwo()", "Skipped")}, false},
		{"failed", []iosTestNode{good[0], node("JourneyUITests/testTwo()", "Failed")}, false},
		{"duplicate", append(append([]iosTestNode{}, good...), good[0]), false},
		{"unexpected", append(append([]iosTestNode{}, good...), node("Other/testTwo()", "Passed")), false},
		{"old target", []iosTestNode{good[0], node("DieterIOSUITests/JourneyUITests/testTwo()", "Passed")}, false},
		{"retry", []iosTestNode{{Type: "Repetition", Children: good}}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data, _ := json.Marshal(map[string]any{"testNodes": []iosTestNode{{Type: "Test Suite", Children: tc.nodes}}})
			status, reason := iosTestResult(data, n)
			if (status == "passed") != tc.pass {
				t.Fatal(status, reason)
			}
		})
	}
	if status, _ := iosTestResult([]byte("invalid"), n); status == "passed" {
		t.Fatal("invalid report passed")
	}
}
func TestIOSFailureSummaryPreservesAssertionWithoutAccessibilityDump(t *testing.T) {
	message := "JourneyUITests.swift:42: The fixture inbox must be ready."
	nodes := []iosTestNode{{Type: "Test Case", ID: "JourneyUITests/testSharedTaskJourney()", Result: "Failed",
		Children: []iosTestNode{{Type: "Failure Message", Name: message + "\nAttributes: " + strings.Repeat("tree", 10000)}}}}
	data, _ := json.Marshal(map[string]any{"testNodes": nodes})
	status, reason := iosTestResult(data, Native{Target: "DieterUITests", Class: "JourneyUITests", Methods: []string{"testSharedTaskJourney"}})
	if status != "failed" || !strings.HasSuffix(reason, message) || strings.Contains(reason, "Attributes") {
		t.Fatal(status, reason)
	}
}

func TestIOSCaseDeadlineIncludesColdSimulatorSetup(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(root, "tests/e2e/cases/ios/journey.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	c, err := decodeCase(data, "case.yaml")
	if err != nil {
		t.Fatal(err)
	}
	for _, timeout := range []string{"1s", "10m", "20m"} {
		c.Timeout = timeout
		if err := c.validate(); err != nil {
			t.Fatalf("rejected bounded iOS deadline %s: %v", timeout, err)
		}
	}
	for _, timeout := range []string{"0s", "20m1s", "1h", "invalid"} {
		c.Timeout = timeout
		if err := c.validate(); err == nil {
			t.Fatalf("accepted invalid iOS deadline %s", timeout)
		}
	}
	for _, input := range []string{strings.Replace(androidJourney, "10m", "20m", 1), strings.Replace(validCase, "30s", "20m", 1)} {
		if _, err := decodeCase([]byte(input), "case.yaml"); err == nil {
			t.Fatal("extended the Android or Mac deadline")
		}
	}
}

func TestIOSCatalogCoverageAndLayout(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	cases, err := catalog(root)
	if err != nil {
		t.Fatal(err)
	}
	methods := map[string]bool{}
	iosCases := map[string]bool{}
	for _, c := range cases {
		if c.Platform == "ios" {
			iosCases[c.ID] = true
			if c.Native.Target != "DieterUITests" {
				t.Fatal("iOS case outside DieterUITests", c.ID)
			}
			for _, m := range c.Native.Methods {
				methods[m] = true
			}
		}
	}
	found := 0
	err = filepath.WalkDir(filepath.Join(root, "apps/ios/Tests"), func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".swift") {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "func test") {
				found++
				name := strings.Split(strings.TrimPrefix(line, "func "), "(")[0]
				if !methods[name] {
					t.Error("uncataloged iOS test", name)
				}
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if found == 0 {
		t.Fatal("no iOS UI tests found")
	}
	for _, path := range []string{"apps/ios/Tests/JourneyUITests.swift", "apps/ios/App/DieterApp.swift", "apps/mac/Sources/DieterIOS/ComposeHost.swift", "tests/e2e/cases/ios/journey.yaml", "fastlane/lib/dieter/platforms/ios.rb"} {
		got := affected(cases, []string{path})
		if len(got) != len(iosCases) {
			t.Fatal(path, len(got))
		}
		for _, c := range got {
			if !iosCases[c.ID] {
				t.Fatal(path, "affected case outside iOS catalog", c.ID)
			}
		}
	}
}
