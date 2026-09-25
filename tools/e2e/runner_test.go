package main

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

const validCase = `version: 1
id: machines.test
platform: android
suites: [smoke]
components: [machines]
fixture: gateway
timeout: 30s
steps:
  - launch: connected
  - tap: {id: machine}
  - expect: {id: cpu, visible: true}
`

func TestOutputDoesNotReuseOtherRunsOrCaches(t *testing.T) {
	root := t.TempDir()
	first, err := createOutput(root, "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := createOutput(root, "")
	if err != nil || first == second {
		t.Fatalf("default outputs must be unique: %q %q %v", first, second, err)
	}
	output, err := createOutput(root, "tmp/ci-123")
	if err != nil {
		t.Fatal(err)
	}
	evidence := filepath.Join(output, "results.json")
	if err := os.WriteFile(evidence, []byte("retained"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, requested := range []string{"tmp/ci-123", output, evidence} {
		if _, err := createOutput(root, requested); err == nil {
			t.Fatalf("reused existing path %q", requested)
		}
	}
	if data, err := os.ReadFile(evidence); err != nil || string(data) != "retained" {
		t.Fatal("existing evidence modified")
	}
}

func TestCaseValidation(t *testing.T) {
	c, err := decodeCase([]byte(validCase), "case.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if c.Steps[1].Line != 10 {
		t.Fatalf("source line lost: %+v", c.Steps)
	}
	for name, input := range map[string]string{
		"unknown field":         validCase + "shell: rm\n",
		"unknown probe":         strings.Replace(validCase, "tap: {id: machine}", "probe: unknown", 1),
		"version":               strings.Replace(validCase, "version: 1", "version: 2", 1),
		"duplicate":             validCase + "id: another\n",
		"documents":             validCase + "---\n" + validCase,
		"ambiguous selector":    strings.Replace(validCase, "{id: machine}", "{id: machine, text: machine}", 1),
		"alias":                 strings.Replace(validCase, "{id: machine}", "&target {id: machine}", 1),
		"variable":              strings.Replace(validCase, "id: machine}", "id: '${env.TOKEN}'}", 1),
		"missing typed value":   strings.Replace(validCase, "tap: {id: machine}", "type: {id: machine}", 1),
		"contradictory absence": strings.Replace(validCase, "visible: true", "visible: false, enabled: true", 1),
		"empty assertion":       strings.Replace(validCase, ", visible: true", "", 1),
		"unbounded":             strings.Replace(validCase, "30s", "1h", 1),
		"action count":          strings.Replace(validCase, "launch: connected", "launch: connected\n    press: back", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeCase([]byte(input), "bad.yaml"); err == nil {
				t.Fatal("accepted invalid case")
			}
		})
	}
}
func nativeOutput(code string) string {
	return "INSTRUMENTATION_STATUS: class=com.dbpprt.dieter.Test\nINSTRUMENTATION_STATUS: test=works\nINSTRUMENTATION_STATUS_CODE: 1\nINSTRUMENTATION_STATUS: class=com.dbpprt.dieter.Test\nINSTRUMENTATION_STATUS: test=works\nINSTRUMENTATION_STATUS_CODE: " + code + "\nINSTRUMENTATION_CODE: -1\n"
}
func TestExactNativeResults(t *testing.T) {
	n := Native{Class: "com.dbpprt.dieter.Test", Methods: []string{"works"}}
	for _, v := range []struct{ output, want string }{{nativeOutput("0"), "passed"}, {nativeOutput("-2"), "failed"}, {nativeOutput("-3"), "unavailable"}, {nativeOutput("-4"), "unavailable"}, {"", "failed"}, {"INSTRUMENTATION_CODE: -1\n", "failed"}, {strings.ReplaceAll(nativeOutput("0"), "works", "other"), "failed"}, {nativeOutput("0") + nativeOutput("0"), "failed"}, {strings.ReplaceAll(nativeOutput("0"), "INSTRUMENTATION_CODE: -1\n", ""), "failed"}} {
		got, reason := instrumentationResult(v.output, n)
		if got != v.want {
			t.Errorf("got %s (%s), want %s", got, reason, v.want)
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
func TestBoundedOutputAndRedaction(t *testing.T) {
	b := &tailBuffer{limit: 4}
	_, _ = b.Write([]byte("abcdef"))
	if b.String() != "cdef" {
		t.Fatal(b.String())
	}
	if got := redact("token abcdef", map[string]string{"isolatedGatewayToken": "abcdef"}); strings.Contains(got, "abcdef") {
		t.Fatal("credential leaked")
	}
	if shellArgs([]string{"hello world", "x'y"}) != "'hello world' 'x'\"'\"'y'" {
		t.Fatal("unsafe ADB argument quoting")
	}
}
func TestSelectionPreservesBroadFallbackAndDeletedPaths(t *testing.T) {
	cases := []Case{{ID: "machines", Platform: "android", Components: []string{"machines"}}, {ID: "conversation", Platform: "android", Components: []string{"conversation"}}}
	if got := affected(cases, []string{"apps/android/app/src/main/java/ui/MachinesScreen.kt"}); len(got) != 1 || got[0].ID != "machines" {
		t.Fatal(got)
	}
	for _, p := range []string{"apps/android/app/src/main/java/Unknown.kt", "apps/android/app/build.gradle.kts", "api/contract-version", "tests/e2e/deleted.yaml"} {
		if len(affected(cases, []string{p})) != 2 {
			t.Fatal("unsafe narrowing:", p)
		}
	}
	if len(affected(cases, []string{"docs/plan.md", "apps/android/app/src/test/Unit.kt"})) != 0 {
		t.Fatal("unnecessary device work")
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

func TestEvidenceRejectsTraversalLinksAndTruncation(t *testing.T) {
	for _, name := range []string{"../escape", "/absolute", "e2e/../../escape", "other/file"} {
		var b bytes.Buffer
		w := tar.NewWriter(&b)
		_ = w.WriteHeader(&tar.Header{Name: name, Mode: 0600, Size: 1})
		_, _ = w.Write([]byte("x"))
		_ = w.Close()
		if err := extractEvidence(b.Bytes(), t.TempDir()); err == nil {
			t.Fatal("accepted", name)
		}
	}
	var b bytes.Buffer
	w := tar.NewWriter(&b)
	_ = w.WriteHeader(&tar.Header{Name: "e2e/events.jsonl", Mode: 0600, Size: 3})
	_, _ = w.Write([]byte("{}\n"))
	_ = w.Close()
	dir := t.TempDir()
	if err := extractEvidence(b.Bytes(), dir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "e2e/events.jsonl")); err != nil {
		t.Fatal(err)
	}
	if err := extractEvidence(b.Bytes()[:513], t.TempDir()); err == nil {
		t.Fatal("accepted truncated archive")
	}
	b.Reset()
	w = tar.NewWriter(&b)
	_ = w.WriteHeader(&tar.Header{Name: "e2e/link", Typeflag: tar.TypeSymlink, Linkname: "/outside"})
	_ = w.Close()
	if err := extractEvidence(b.Bytes(), t.TempDir()); err == nil {
		t.Fatal("accepted symlink")
	}
}
func TestHostInputRequiresAllPostconditions(t *testing.T) {
	value := map[string]any{"ups": 1, "text": "Android écran 世界 Android native paste marker", "scrolls": 1, "keys": []string{"0:up"}}
	data, _ := json.Marshal(value)
	if err := validateHostInput(data); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"ups", "text", "scrolls", "keys"} {
		copy := map[string]any{}
		for k, v := range value {
			copy[k] = v
		}
		delete(copy, key)
		data, _ := json.Marshal(copy)
		if err := validateHostInput(data); err == nil {
			t.Fatal("accepted missing", key)
		}
	}
}
func TestLeaseFailureStillWritesResults(t *testing.T) {
	serial := "test-e2e-lease-report"
	unlock, err := deviceLease(serial)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	dir := t.TempDir()
	err = runAndroid(context.Background(), t.TempDir(), dir, serial, []Case{{ID: "required"}})
	if err == nil {
		t.Fatal("accepted second owner")
	}
	data, err := os.ReadFile(filepath.Join(dir, "results.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "unavailable") {
		t.Fatal(string(data))
	}
}

// Missing coverage must be an explicit decision, never an accidental generated
// manifest omission. These exceptions are manual/external fixtures, not gates.
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
	exceptions := map[string]bool{
		"runFlow": true,
		"webRTCControlCarriesRPCAndReportsICEPath":                  true,
		"archiveVisibleFixtureAndRestoreProductionGateway":          true,
		"terminalSurvivesAndroidTransportLossThroughTheRealGateway": true,
		"cardAttachmentDraftRoundTripsThroughTheRealGateway":        true,
		"completeNativeGrpcPathReadsTheLocalWorkspace":              true,
		"liveModeKeepsRealWorkspaceSynchronizedInBackground":        true,
		"appSettingsPersistReasoningAndOrderedConnections":          true,
	}
	method := regexp.MustCompile(`@Test\s+(?:public\s+)?(?:fun|void)\s+(\w+)`)
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
			if !registered[m[1]] && !exceptions[m[1]] {
				t.Errorf("uncataloged native test %s in %s", m[1], path)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestActivityReplyProbes(t *testing.T) {
	for _, probe := range []string{"activity-replies-unread", "activity-card-seen", "activity-chat-seen"} {
		input := strings.Replace(validCase, "tap: {id: machine}", "probe: "+probe, 1)
		if _, err := decodeCase([]byte(input), "activity.yaml"); err != nil {
			t.Fatal(err)
		}
	}
}
