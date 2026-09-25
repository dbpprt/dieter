package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// iOS uses owned, disposable simulators. No existing simulator or operator app
// is installed over, shut down, or deleted. A repository lease protects Xcode's
// build products for the entire run, including private xctestrun preparation.
type iosDriver struct{ root, output, device, deviceType, runtime, products, fixtureBinary string }
type simulatorInventory struct {
	DeviceTypes []struct {
		Name       string `json:"name"`
		Identifier string `json:"identifier"`
	} `json:"devicetypes"`
	Runtimes []struct {
		Identifier string `json:"identifier"`
		Version    string `json:"version"`
		Available  bool   `json:"isAvailable"`
	} `json:"runtimes"`
}

func iosDestination(data []byte, device string) (string, string, error) {
	var inventory simulatorInventory
	if err := json.Unmarshal(data, &inventory); err != nil {
		return "", "", fmt.Errorf("invalid simulator inventory")
	}
	name := map[string]string{"iphone": "iPhone 17 Pro", "ipad": "iPad Pro 11-inch (M5)"}[device]
	kind, selected, version := "", "", ""
	for _, d := range inventory.DeviceTypes {
		if d.Name == name {
			kind = d.Identifier
		}
	}
	for _, r := range inventory.Runtimes {
		if r.Available && strings.HasPrefix(r.Identifier, "com.apple.CoreSimulator.SimRuntime.iOS-") && (selected == "" || newerIOSVersion(r.Version, version)) {
			selected, version = r.Identifier, r.Version
		}
	}
	if kind == "" {
		return "", "", fmt.Errorf("unavailable simulator type: %s", name)
	}
	if selected == "" {
		return "", "", fmt.Errorf("an installed iOS Simulator runtime is required")
	}
	return kind, selected, nil
}
func newerIOSVersion(a, b string) bool {
	aa, bb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < max(len(aa), len(bb)); i++ {
		x, y := 0, 0
		if i < len(aa) {
			x, _ = strconv.Atoi(aa[i])
		}
		if i < len(bb) {
			y, _ = strconv.Atoi(bb[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}
func runIOS(ctx context.Context, root, output, device string, cases []Case) error {
	started := time.Now()
	report := Report{Version: 1, Platform: "ios", Serial: device, Results: []Result{}}
	unavailable := func(err error) error {
		for _, c := range cases {
			report.Results = append(report.Results, Result{ID: c.ID, Status: "unavailable", Reason: err.Error()})
		}
		report.DurationMS = time.Since(started).Milliseconds()
		if e := writeReport(output, report); e != nil {
			return fmt.Errorf("%w; report: %v", err, e)
		}
		return err
	}
	fmt.Println("E2E evidence: " + output)
	if err := writeJSON(filepath.Join(output, "plan.json"), cases); err != nil {
		return err
	}
	if runtime.GOOS != "darwin" {
		return unavailable(fmt.Errorf("iOS execution requires macOS and Xcode"))
	}
	unlock, err := acquireLease(filepath.Join(os.TempDir(), fmt.Sprintf("dieter-ios-e2e-%x.lock", sha256.Sum256([]byte(root)))))
	if err != nil {
		return unavailable(err)
	}
	defer unlock()
	preflight, cancel := context.WithTimeout(ctx, 30*time.Second)
	out, err := binaryCommand(preflight, root, "xcrun", "simctl", "list", "-j")
	cancel()
	if err != nil {
		return unavailable(fmt.Errorf("simulator inventory: %w", err))
	}
	kind, rt, err := iosDestination([]byte(out), device)
	if err != nil {
		return unavailable(err)
	}
	private, err := os.MkdirTemp("", "dieter-ios-build-")
	if err != nil {
		return unavailable(err)
	}
	defer os.RemoveAll(private)
	d := iosDriver{root: root, output: output, device: device, deviceType: kind, runtime: rt, products: filepath.Join(root, "apps/ios/.build/DerivedData/Build/Products"), fixtureBinary: filepath.Join(private, "isolated-gateway")}
	build, cancel := context.WithTimeout(ctx, 20*time.Minute)
	buildStarted := time.Now()
	for _, argv := range [][]string{{"just", "ios", "build"}, {"go", "build", "-o", d.fixtureBinary, "./scripts/isolated-gateway"}} {
		out, err = command(build, root, nil, argv...)
		name := "build.log"
		if argv[0] == "go" {
			name = "fixture-build.log"
		}
		_ = os.WriteFile(filepath.Join(output, name), []byte(out), 0600)
		if err != nil {
			break
		}
	}
	cancel()
	report.BuildMS = time.Since(buildStarted).Milliseconds()
	if err != nil {
		return unavailable(fmt.Errorf("iOS preparation failed: %w; see build logs", err))
	}
	return runCases(ctx, output, started, &report, cases, d.run)
}

var simulatorID = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

func (d iosDriver) run(ctx context.Context, c Case) (result Result) {
	started := time.Now()
	result = Result{ID: c.ID, Status: "failed"}
	dir := filepath.Join(d.output, c.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		result.Reason = err.Error()
		return
	}
	state, err := os.MkdirTemp("", "dieter-ios-case-")
	if err != nil {
		result.Reason = err.Error()
		return
	}
	simulator := ""
	var gateway *ownedProcess
	var screenCleanup func() error
	values := map[string]string{}
	defer func() {
		var problems []string
		gatewayStopped := true
		if screenCleanup != nil {
			if e := screenCleanup(); e != nil {
				problems = append(problems, e.Error())
			}
		}
		if gateway != nil {
			if e := gateway.stop(); e != nil {
				gatewayStopped = false
				problems = append(problems, e.Error())
			}
			if e := os.WriteFile(filepath.Join(dir, "gateway.log"), []byte(redact(gateway.out.String(), values)), 0600); e != nil {
				problems = append(problems, "retain gateway log: "+e.Error())
			}
		}
		if simulator != "" {
			// Cleanup gets independent bounded contexts even after cancellation. Attempt
			// deletion after shutdown failure; deletion is the final ownership check.
			for _, action := range []string{"shutdown", "delete"} {
				cleanup, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				_, e := command(cleanup, d.root, nil, "xcrun", "simctl", action, simulator)
				cancel()
				if e != nil && action == "delete" {
					problems = append(problems, "delete owned simulator: "+e.Error())
				}
			}
		}
		// The raw result bundle and private test configuration may contain launch
		// credentials. Retain only sanitized reports, console and attachments.
		for _, name := range []string{"DieterIOS.xctestrun", "result.xcresult"} {
			if e := os.RemoveAll(filepath.Join(state, name)); e != nil {
				problems = append(problems, e.Error())
			}
		}
		if gatewayStopped {
			if e := os.RemoveAll(state); e != nil {
				problems = append(problems, e.Error())
			}
		} else {
			problems = append(problems, "live fixture state retained at "+state)
		}
		result.CleanupError = strings.Join(problems, "; ")
		result.DurationMS = time.Since(started).Milliseconds()
	}()
	fail := func(err error) { result.Reason = redact(err.Error(), values) }
	testEnv := map[string]string{"DIETER_IOS_TEST_LANDSCAPE": "0"}
	if d.device == "ipad" {
		testEnv["DIETER_IOS_TEST_LANDSCAPE"] = "1"
	}
	if c.ID == "ios.https-auth" {
		endpoint := os.Getenv("DIETER_IOS_TEST_HTTPS_GATEWAY")
		u, e := url.Parse(endpoint)
		if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			fail(fmt.Errorf("ios.https-auth requires DIETER_IOS_TEST_HTTPS_GATEWAY with a credential-free HTTPS URL"))
			return
		}
		testEnv["DIETER_IOS_TEST_HTTPS_GATEWAY"] = endpoint
	}
	if c.Fixture == "gateway" {
		gateway, err = startOwned(d.root, d.fixtureBinary, "--addr", "127.0.0.1:0", "--home", filepath.Join(state, "fixture"), "--offline-trigger", filepath.Join(state, "offline"))
		if err != nil {
			fail(err)
			return
		}
		values, err = awaitGateway(ctx, gateway)
		if err != nil {
			fail(err)
			return
		}
		for _, key := range []string{"TOKEN", "DAEMON", "INCOMPATIBLE_DAEMON", "PROJECT", "BOARD"} {
			if values["DIETER_ISOLATED_"+key] == "" {
				fail(fmt.Errorf("gateway missing %s", key))
				return
			}
			testEnv["DIETER_IOS_TEST_"+key] = values["DIETER_ISOLATED_"+key]
		}
		testEnv["DIETER_IOS_TEST_GATEWAY"] = "http://" + values["DIETER_ISOLATED_ADDR"]
		testEnv["DIETER_IOS_TEST_OFFLINE_TRIGGER"] = filepath.Join(state, "offline")
	}
	if c.Fixture == "screen" {
		var screenValues map[string]string
		screenValues, _, screenCleanup, err = (screenDriver{root: d.root, nativeOnly: true}).start(ctx, dir)
		if err != nil {
			fail(err)
			return
		}
		for k, v := range screenValues {
			values[k] = v
		}
		testEnv["DIETER_IOS_TEST_SCREEN_FIXTURE"] = screenValues["screenFixture"]
	}
	create, cancel := context.WithTimeout(ctx, 30*time.Second)
	out, err := binaryCommand(create, d.root, "xcrun", "simctl", "create", "Dieter E2E "+filepath.Base(state), d.deviceType, d.runtime)
	cancel()
	simulator = strings.TrimSpace(out)
	if err != nil {
		if !simulatorID.MatchString(simulator) {
			simulator = ""
		}
		fail(fmt.Errorf("create simulator: %w", err))
		return
	}
	if !simulatorID.MatchString(simulator) {
		simulator = ""
		fail(fmt.Errorf("simctl returned invalid owned simulator identity"))
		return
	}
	_ = os.WriteFile(filepath.Join(dir, "simulator.txt"), []byte(simulator+"\n"), 0600)
	out, err = command(ctx, d.root, nil, "xcrun", "simctl", "bootstatus", simulator, "-b")
	_ = os.WriteFile(filepath.Join(dir, "boot.log"), []byte(out), 0600)
	if err != nil {
		fail(fmt.Errorf("boot simulator: %w", err))
		return
	}
	if c.ID == "ios.share-extension" {
		if _, err = command(ctx, d.root, nil, "xcrun", "simctl", "addmedia", simulator, filepath.Join(d.root, "apps/android/design/reference/phone-board.png")); err != nil {
			fail(fmt.Errorf("load share fixture: %w", err))
			return
		}
	}
	testRun, err := d.testRun(ctx, state, testEnv, c.Native.Target)
	if err != nil {
		fail(err)
		return
	}
	result.SetupMS = time.Since(started).Milliseconds()
	bundle := filepath.Join(state, "result.xcresult")
	argv := []string{"xcodebuild", "test-without-building", "-xctestrun", testRun, "-destination", "platform=iOS Simulator,id=" + simulator, "-parallel-testing-enabled", "NO", "-resultBundlePath", bundle}
	for _, method := range c.Native.Methods {
		argv = append(argv, "-only-testing:"+c.Native.Target+"/"+c.Native.Class+"/"+method)
	}
	execution := time.Now()
	out, testErr := command(ctx, d.root, nil, argv...)
	result.ExecutionMS = time.Since(execution).Milliseconds()
	_ = os.WriteFile(filepath.Join(dir, "tests.log"), []byte(redact(out, values)), 0600)
	evidence, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	nodes, exportErr := command(evidence, d.root, nil, "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle, "--compact")
	if exportErr == nil {
		_ = os.WriteFile(filepath.Join(dir, "test-results.json"), []byte(redact(nodes, values)), 0600)
	}
	if testErr != nil || exportErr != nil {
		fail(fmt.Errorf("XCTest did not complete: test=%v result=%v", testErr, exportErr))
	} else {
		result.Status, result.Reason = iosTestResult([]byte(nodes), *c.Native)
	}
	_, _ = command(evidence, d.root, nil, "xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", filepath.Join(dir, "attachments"))
	if result.Status != "passed" {
		retainIOSConsole(evidence, d.root, bundle, dir, values)
	}
	return
}

func (d iosDriver) testRun(ctx context.Context, state string, environment map[string]string, target string) (string, error) {
	candidates, err := filepath.Glob(filepath.Join(d.products, "*iphonesimulator*.xctestrun"))
	if err != nil {
		return "", err
	}
	// Build-for-testing owns this directory under the run lease. Require one
	// unambiguous product instead of silently selecting a stale test plan.
	if len(candidates) != 1 {
		return "", fmt.Errorf("expected one Simulator xctestrun product, found %d", len(candidates))
	}
	raw, err := binaryCommand(ctx, d.root, "plutil", "-convert", "json", "-o", "-", candidates[0])
	if err != nil {
		return "", fmt.Errorf("read xctestrun: %w", err)
	}
	var spec any
	if err = json.Unmarshal([]byte(raw), &spec); err != nil {
		return "", err
	}
	count := configureIOSTestRun(spec, d.products, environment, target)
	if count != 1 {
		return "", fmt.Errorf("expected one XCTest target, found %d", count)
	}
	path := filepath.Join(state, "DieterIOS.xctestrun")
	if err = writeJSON(path, spec); err != nil {
		return "", err
	}
	_, err = command(ctx, d.root, nil, "plutil", "-convert", "xml1", path)
	return path, err
}
func configureIOSTestRun(value any, products string, environment map[string]string, target string) int {
	count := 0
	switch v := value.(type) {
	case map[string]any:
		if _, ok := v["TestBundlePath"]; ok && v["BlueprintName"] == target {
			vars, _ := v["EnvironmentVariables"].(map[string]any)
			if vars == nil {
				vars = map[string]any{}
			}
			for k, s := range environment {
				vars[k] = s
			}
			v["EnvironmentVariables"] = vars
			count++
		}
		for k, child := range v {
			if s, ok := child.(string); ok {
				v[k] = strings.ReplaceAll(s, "__TESTROOT__", products)
			} else {
				count += configureIOSTestRun(child, products, environment, target)
			}
		}
	case []any:
		for i, child := range v {
			if s, ok := child.(string); ok {
				v[i] = strings.ReplaceAll(s, "__TESTROOT__", products)
			} else {
				count += configureIOSTestRun(child, products, environment, target)
			}
		}
	}
	return count
}

type iosTestNode struct {
	Type     string        `json:"nodeType"`
	Name     string        `json:"name"`
	ID       string        `json:"nodeIdentifier"`
	Result   string        `json:"result"`
	Children []iosTestNode `json:"children"`
}

func iosTestResult(data []byte, n Native) (string, string) {
	var report struct {
		Nodes []iosTestNode `json:"testNodes"`
	}
	if err := json.Unmarshal(data, &report); err != nil {
		return "failed", "invalid XCTest result JSON"
	}
	expected := map[string]bool{}
	for _, m := range n.Methods {
		expected[n.Class+"/"+m] = true
	}
	seen := map[string]bool{}
	reason := ""
	var visit func([]iosTestNode)
	visit = func(nodes []iosTestNode) {
		for _, node := range nodes {
			if node.Type == "Test Case" {
				key := strings.TrimSuffix(strings.TrimPrefix(node.ID, n.Target+"/"), "()")
				if !expected[key] || seen[key] {
					reason = "unexpected or duplicate XCTest: " + key
				} else if node.Result != "Passed" {
					reason = "required XCTest did not pass: " + key + " (" + node.Result + ")"
				}
				seen[key] = true
			}
			if node.Type == "Repetition" {
				reason = "unexpected XCTest repetition"
			}
			visit(node.Children)
		}
	}
	visit(report.Nodes)
	if reason != "" {
		return "failed", reason
	}
	if len(seen) != len(expected) {
		return "failed", fmt.Sprintf("incomplete XCTest results: %d/%d methods", len(seen), len(expected))
	}
	return "passed", ""
}

// Only test output is retained, excluding debugger input and command/environment
// sections. Redact before bounding the tail so partial tokens cannot escape.
func iosConsole(data []byte, kind string, values map[string]string) string {
	var payload map[string]any
	if len(data) >= 4<<20 || json.Unmarshal(data, &payload) != nil {
		return ""
	}
	var lines []string
	if kind == "console" {
		items, _ := payload["items"].([]any)
		for _, item := range items {
			m, _ := item.(map[string]any)
			s, _ := m["content"].(string)
			if s != "" && m["kind"] != "input" && m["adaptorType"] != "debugger" {
				lines = append(lines, s)
			}
		}
	} else {
		var visit func(map[string]any)
		visit = func(m map[string]any) {
			details, _ := m["testDetails"].(map[string]any)
			if s, ok := details["emittedOutput"].(string); ok {
				lines = append(lines, s)
			}
			children, _ := m["subsections"].([]any)
			for _, child := range children {
				v, _ := child.(map[string]any)
				visit(v)
			}
		}
		visit(payload)
	}
	text := redact(strings.Join(lines, "\n"), values)
	lines = strings.Split(text, "\n")
	if len(lines) > 400 {
		lines = lines[len(lines)-400:]
	}
	return strings.ToValidUTF8(last(strings.Join(lines, "\n"), 64<<10), "")
}
func retainIOSConsole(ctx context.Context, root, bundle, dir string, values map[string]string) {
	text := "unavailable: no test console output"
	for _, kind := range []string{"console", "action"} {
		export, cancel := context.WithTimeout(ctx, 15*time.Second)
		out, err := command(export, root, nil, "xcrun", "xcresulttool", "get", "log", "--type", kind, "--compact", "--path", bundle)
		cancel()
		if err == nil {
			if s := iosConsole([]byte(out), kind, values); strings.TrimSpace(s) != "" {
				text = s
				break
			}
		}
	}
	_ = os.WriteFile(filepath.Join(dir, "failure-console.log"), []byte(text), 0600)
}
