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
	if err := json.Unmarshal([]byte(`{"TestConfigurations":[{"TestTargets":[{"BlueprintName":"DieterIOSUITests","TestBundlePath":"__TESTROOT__/UI.xctest","EnvironmentVariables":{"EXISTING":"retained"},"DependentProductPaths":["__TESTROOT__/App.app"]},{"BlueprintName":"DieterIOSNativeTests","TestBundlePath":"__TESTROOT__/Unit.xctest"}]}]}`), &spec); err != nil {
		t.Fatal(err)
	}
	if count := configureIOSTestRun(spec, "/products", map[string]string{"TOKEN": "private-token"}, "DieterIOSUITests"); count != 1 {
		t.Fatal(count)
	}
	data, _ := json.Marshal(spec)
	s := string(data)
	if strings.Contains(s, "__TESTROOT__") || strings.Count(s, "private-token") != 1 || !strings.Contains(s, "retained") || !strings.Contains(s, "/products/App.app") {
		t.Fatal(s)
	}
}
func TestIOSExactMethodQualification(t *testing.T) {
	n := Native{Target: "DieterIOSUITests", Class: "RemoteNodeUITests", Methods: []string{"testOne", "testTwo"}}
	node := func(id, result string) iosTestNode { return iosTestNode{Type: "Test Case", ID: id, Result: result} }
	good := []iosTestNode{node("RemoteNodeUITests/testOne()", "Passed"), node("DieterIOSUITests/RemoteNodeUITests/testTwo()", "Passed")}
	for _, tc := range []struct {
		name  string
		nodes []iosTestNode
		pass  bool
	}{
		{"complete", good, true}, {"missing", good[:1], false}, {"empty", nil, false},
		{"skip", []iosTestNode{good[0], node("RemoteNodeUITests/testTwo()", "Skipped")}, false},
		{"failed", []iosTestNode{good[0], node("RemoteNodeUITests/testTwo()", "Failed")}, false},
		{"duplicate", append(append([]iosTestNode{}, good...), good[0]), false},
		{"unexpected", append(append([]iosTestNode{}, good...), node("Other/testTwo()", "Passed")), false},
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
	message := "RemoteNodeUITests.swift:320: The fixture board must be ready."
	nodes := []iosTestNode{{Type: "Test Case", ID: "RemoteNodeUITests/testOne()", Result: "Failed",
		Children: []iosTestNode{{Type: "Failure Message", Name: message + "\nAttributes: " + strings.Repeat("tree", 10000)}}}}
	data, _ := json.Marshal(map[string]any{"testNodes": nodes})
	status, reason := iosTestResult(data, Native{Target: "DieterIOSUITests", Class: "RemoteNodeUITests", Methods: []string{"testOne"}})
	if status != "failed" || !strings.HasSuffix(reason, message) || strings.Contains(reason, "Attributes") {
		t.Fatal(status, reason)
	}
}

func TestIOSConsoleRedactionAndBounds(t *testing.T) {
	token := "isolated_" + strings.Repeat("a", 48)
	payload := map[string]any{"items": []map[string]string{{"content": "private command", "kind": "input"}, {"content": "launch environment", "adaptorType": "debugger"}, {"content": strings.Repeat("discarded\n", 600) + strings.Repeat("🙂", 20000) + token + " secret-token\nlast failure"}}}
	data, _ := json.Marshal(payload)
	got := iosConsole(data, "console", map[string]string{"token": "secret-token"})
	if len(got) > 64<<10 || strings.Count(got, "\n") > 399 || !strings.HasSuffix(got, "<redacted> <redacted>\nlast failure") {
		t.Fatal("bad console bounds/redaction")
	}
	for _, secret := range []string{token, "secret-token", "private command", "launch environment", "discarded"} {
		if strings.Contains(got, secret) {
			t.Fatal("leaked " + secret)
		}
	}
	action := []byte(`{"commandInvocationDetails":"secret","subsections":[{"testDetails":{"emittedOutput":"useful","runnablePath":"secret"}}]}`)
	if got := iosConsole(action, "action", nil); got != "useful" {
		t.Fatal(got)
	}
	for _, data := range [][]byte{[]byte(`[]`), []byte(`invalid`), []byte(strings.Repeat("x", 4<<20))} {
		if iosConsole(data, "console", nil) != "" {
			t.Fatal("invalid/oversized console retained")
		}
	}
}
func TestIOSCaseDeadlineIncludesColdSimulatorSetup(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(root, "tests/e2e/cases/ios/remote-node.yaml"))
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
	if _, err := decodeCase([]byte(strings.Replace(validCase, "30s", "20m", 1)), "case.yaml"); err == nil {
		t.Fatal("extended the Android deadline")
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
			for _, m := range c.Native.Methods {
				methods[m] = true
			}
			if c.ID == "ios.share-extension" && (len(c.Devices) != 1 || c.Devices[0] != "iphone") {
				t.Fatal("share scope")
			}
		}
	}
	for _, path := range []string{"apps/ios/DieterIOSUITests/RemoteNodeUITests.swift", "apps/ios/DieterIOSNativeTests/IOSCredentialNativeTests.swift", "apps/mac/Tests/DieterIOSTests/IOSCoreAdapterTests.swift"} {
		data, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "func test") {
				name := strings.Split(strings.TrimPrefix(line, "func "), "(")[0]
				if !methods[name] {
					t.Fatal("uncataloged iOS test", name)
				}
			}
		}
	}
	for _, path := range []string{"apps/ios/DieterIOSUITests/RemoteNodeUITests.swift", "apps/mac/Sources/DieterIOS/UI/Root.swift", "apps/mac/Tests/DieterIOSTests/IOSCoreAdapterTests.swift", "tests/e2e/cases/ios/credentials.yaml"} {
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

// Exercise the actual driver lifecycle against stub tool executables. No Apple
// tools, simulator, gateway or operator state is needed for failure-path tests.
