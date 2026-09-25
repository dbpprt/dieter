package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
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
	for _, c := range cases {
		if c.Platform == "ios" {
			for _, m := range c.Native.Methods {
				methods[m] = true
			}
			if c.ID == "ios.share-extension" && (len(c.Devices) != 1 || c.Devices[0] != "iphone") {
				t.Fatal("share scope")
			}
		}
	}
	for _, path := range []string{"apps/ios/DieterIOSUITests/RemoteNodeUITests.swift", "apps/ios/DieterIOSNativeTests/IOSCredentialNativeTests.swift"} {
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
	for _, path := range []string{"apps/ios/DieterIOSUITests/RemoteNodeUITests.swift", "apps/mac/Sources/DieterIOS/UI/Root.swift", "tests/e2e/cases/ios/credentials.yaml"} {
		got := affected(cases, []string{path})
		if len(got) != 7 {
			t.Fatal(path, len(got))
		}
	}
}

// Exercise the actual driver lifecycle against stub tool executables. No Apple
// tools, simulator, gateway or operator state is needed for failure-path tests.
func TestIOSDriverCleansOnlyOwnedSimulatorOnEveryExit(t *testing.T) {
	for _, mode := range []string{"success", "boot-failure", "test-failure", "delete-failure", "missing-result", "canceled"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			bin := filepath.Join(root, "bin")
			products := filepath.Join(root, "products")
			output := filepath.Join(root, "out")
			for _, dir := range []string{bin, products, output} {
				if err := os.MkdirAll(dir, 0700); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			t.Setenv("IOS_STUB_LOG", filepath.Join(root, "commands"))
			t.Setenv("IOS_STUB_MODE", mode)
			scripts := map[string]string{
				"xcrun": `#!/bin/sh
printf '%s\n' "$*" >> "$IOS_STUB_LOG"
case "$1 $2 $3" in
 'simctl create '*) echo AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE ;;
 'simctl bootstatus '*)
  if [ "$IOS_STUB_MODE" = canceled ]; then exec sleep 5; fi
  [ "$IOS_STUB_MODE" != boot-failure ] ;;
 'simctl delete '*) [ "$IOS_STUB_MODE" != delete-failure ] ;;
 'xcresulttool get test-results')
  [ "$IOS_STUB_MODE" != missing-result ] || exit 1
  echo '{"testNodes":[{"nodeType":"Test Case","nodeIdentifier":"RemoteNodeUITests/testOne()","result":"Passed"}]}' ;;
 'xcresulttool get log') echo '{"items":[{"content":"useful failure"}]}' ;;
esac
`,
				"plutil": `#!/bin/sh
if [ "$2" = json ]; then echo '{"DieterIOSUITests":{"BlueprintName":"DieterIOSUITests","TestBundlePath":"__TESTROOT__/test.xctest"}}'; fi
`,
				"xcodebuild": `#!/bin/sh
printf '%s\n' "$*" >> "$IOS_STUB_LOG"
[ "$IOS_STUB_MODE" != test-failure ]
`,
			}
			for name, script := range scripts {
				if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0700); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(filepath.Join(products, "test_iphonesimulator.xctestrun"), nil, 0600); err != nil {
				t.Fatal(err)
			}
			d := iosDriver{root: root, products: products, output: output, device: "iphone", deviceType: "owned-type", runtime: "owned-runtime"}
			timeout := 5 * time.Second
			if mode == "canceled" {
				timeout = 200 * time.Millisecond
			}
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			result := d.run(ctx, Case{ID: "ios.stub", Fixture: "none", Native: &Native{Target: "DieterIOSUITests", Class: "RemoteNodeUITests", Methods: []string{"testOne"}}})
			if (result.Status == "passed" && result.CleanupError == "") != (mode == "success") {
				t.Fatalf("%+v", result)
			}
			data, err := os.ReadFile(filepath.Join(root, "commands"))
			if err != nil {
				t.Fatal(err)
			}
			log := string(data)
			for _, action := range []string{"shutdown", "delete"} {
				if !strings.Contains(log, "simctl "+action+" AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") {
					t.Fatal(log)
				}
			}
			if mode != "boot-failure" && mode != "canceled" && !strings.Contains(log, "-only-testing:DieterIOSUITests/RemoteNodeUITests/testOne") {
				t.Fatal(log)
			}
			if strings.Contains(log, "simctl erase") || strings.Contains(log, " all") {
				t.Fatal("touched unrelated simulators")
			}
			// The private xctestrun directory must no longer exist after any result.
			for _, line := range strings.Split(log, "\n") {
				fields := strings.Fields(line)
				for i, arg := range fields {
					if arg == "-xctestrun" {
						if _, err := os.Stat(fields[i+1]); !os.IsNotExist(err) {
							t.Fatal("private config retained", err)
						}
					}
				}
			}
		})
	}
}

func TestIOSPrivateConfigurationWithNativePlutil(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("plutil round trip requires macOS")
	}
	root := t.TempDir()
	products := filepath.Join(root, "products")
	state := filepath.Join(root, "private")
	for _, p := range []string{products, state} {
		if err := os.Mkdir(p, 0700); err != nil {
			t.Fatal(err)
		}
	}
	source := filepath.Join(products, "DieterIOS_iphonesimulator.xctestrun")
	original := map[string]any{"DieterIOSUITests": map[string]any{"BlueprintName": "DieterIOSUITests", "TestBundlePath": "__TESTROOT__/test.xctest", "IsUITestBundle": true}, "DieterIOSNativeTests": map[string]any{"BlueprintName": "DieterIOSNativeTests", "TestBundlePath": "__TESTROOT__/native.xctest"}, "__xctestrun_metadata__": map[string]any{"FormatVersion": 1}}
	if err := writeJSON(source, original); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := command(ctx, root, nil, "plutil", "-convert", "binary1", source); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(source)
	path, err := (iosDriver{root: root, products: products}).testRun(ctx, state, map[string]string{"DIETER_IOS_TEST_TOKEN": "private-token"}, "DieterIOSUITests")
	if err != nil {
		t.Fatal(err)
	}
	out, err := command(ctx, root, nil, "plutil", "-convert", "json", "-o", "-", path)
	if err != nil || !strings.Contains(out, "private-token") || strings.Contains(out, "__TESTROOT__") {
		t.Fatal("invalid native plist round trip", err)
	}
	after, _ := os.ReadFile(source)
	if string(before) != string(after) {
		t.Fatal("build product mutated")
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("private test configuration permissions", err)
	}
}
