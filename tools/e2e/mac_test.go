package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestMacReportsRequireEveryAssertion(t *testing.T) {
	for _, tc := range []struct {
		name   string
		report map[string]string
		want   string
	}{
		{"complete", map[string]string{"prepare.window": "passed", "verify.restore": "passed"}, "passed"},
		{"missing phase", map[string]string{"prepare.window": "passed"}, "failed"},
		{"skip", map[string]string{"prepare.window": "passed", "verify.restore": "skipped"}, "failed"},
		{"extra failure", map[string]string{"prepare.window": "passed", "verify.restore": "passed", "unexpected": "failed: broken"}, "failed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			status, _ := macReportResult(tc.report, []string{"prepare.window", "verify.restore"})
			if status != tc.want {
				t.Fatal(status)
			}
		})
	}
}
func TestMacNativeContract(t *testing.T) {
	if err := validateMacNative(Native{Suite: "sidebar", Checks: []string{"prepare.window", "verify.restore"}}, "none"); err != nil {
		t.Fatal(err)
	}
	for _, n := range []Native{{Suite: "unknown", Checks: []string{"unknown.x"}}, {Suite: "sidebar"}, {Suite: "sidebar", Checks: []string{"wrong.x"}}, {Suite: "sidebar", Checks: []string{"prepare.x", "prepare.x"}}} {
		if validateMacNative(n, "none") == nil {
			t.Fatalf("accepted %+v", n)
		}
	}
	if validateMacNative(Native{Suite: "core", Checks: []string{"core.window"}}, "none") == nil {
		t.Fatal("wrong fixture")
	}
}
func TestSharedRunnerStopsAfterCleanupFailure(t *testing.T) {
	dir := t.TempDir()
	report := Report{Version: 1}
	calls := 0
	cases := []Case{{ID: "one", Timeout: "1s"}, {ID: "two", Timeout: "1s"}}
	err := runCases(context.Background(), dir, time.Now(), &report, cases, func(context.Context, Case) Result {
		calls++
		return Result{Status: "passed", CleanupError: "owned process still running"}
	})
	if err == nil || calls != 1 || len(report.Results) != 2 || report.Results[0].Status != "failed" || report.Results[1].Status != "interrupted" {
		t.Fatalf("%v %+v calls=%d", err, report, calls)
	}
	for _, name := range []string{"results.json", "junit.xml"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Fatal(err)
		}
	}
}
func TestSharedRunnerCancellationAccountsForEveryCase(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	report := Report{Version: 1}
	err := runCases(ctx, t.TempDir(), time.Now(), &report, []Case{{ID: "one", Timeout: "1s"}}, func(context.Context, Case) Result { t.Fatal("started canceled case"); return Result{} })
	if err == nil || len(report.Results) != 1 || report.Results[0].Status != "interrupted" {
		t.Fatal(report, err)
	}
}
func TestAffectedNativePlatforms(t *testing.T) {
	cases := []Case{{ID: "mac", Platform: "mac"}, {ID: "android", Platform: "android"}}
	for _, tc := range []struct{ path, want string }{{"apps/mac/Sources/DieterMac/UI/WorkspaceSplit.swift", "mac"}, {"apps/android/app/build.gradle.kts", "android"}} {
		got := affected(cases, []string{tc.path})
		if len(got) != 1 || got[0].ID != tc.want {
			t.Fatal(tc, got)
		}
	}
	if len(affected(cases, []string{"api/contract-version"})) != 2 {
		t.Fatal("shared contract must select both")
	}
}

func TestMacReportReadAfterProcessExit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "report.json")
	if err := os.WriteFile(path, []byte(`{"window":"passed"}`), 0600); err != nil {
		t.Fatal(err)
	}
	p := &ownedProcess{done: make(chan struct{})}
	close(p.done)
	got, err := awaitMacReport(context.Background(), p, path)
	if err != nil || got["window"] != "passed" {
		t.Fatal(got, err)
	}
	if _, err := awaitMacReport(context.Background(), p, path+".missing"); err == nil {
		t.Fatal("accepted exited process without report")
	}
}

func TestMacReportPublishedImmediatelyBeforeExit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "report.json")
	p := &ownedProcess{done: make(chan struct{})}
	go func() {
		time.Sleep(20 * time.Millisecond)
		p.err = os.WriteFile(path, []byte(`{"window":"passed"}`), 0600)
		close(p.done)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	result, err := awaitMacReport(ctx, p, path)
	if err != nil || result["window"] != "passed" {
		t.Fatal(result, err)
	}
}

func TestSharedFixtureReadinessRequiresLoopbackAndToken(t *testing.T) {
	for _, tc := range []struct {
		name, output string
		pass         bool
	}{
		{"ready", "DIETER_ISOLATED_ADDR=127.0.0.1:1234\nDIETER_ISOLATED_TOKEN=fixture-token\nREADY\n", true},
		{"remote", "DIETER_ISOLATED_ADDR=example.com:1234\nDIETER_ISOLATED_TOKEN=fixture-token\nREADY\n", false},
		{"missing token", "DIETER_ISOLATED_ADDR=127.0.0.1:1234\nREADY\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := &ownedProcess{out: &tailBuffer{limit: 1024}, done: make(chan struct{})}
			_, _ = p.out.Write([]byte(tc.output))
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_, err := awaitGateway(ctx, p)
			if (err == nil) != tc.pass {
				t.Fatal(err)
			}
		})
	}
}
