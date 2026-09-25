package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"time"
)

type macPhase struct {
	name, report string
	args         []string
}

var macSuites = []string{"core", "board", "conversation", "machine", "sidebar", "terminal", "island", "workspace", "inbox"}
var macCheck = regexp.MustCompile(`^[^\x00-\x1F\x7F]{1,201}$`)

func validateMacNative(n Native, fixture string) error {
	if !slices.Contains(macSuites, n.Suite) || n.Class != "" || len(n.Methods) != 0 || len(n.Checks) == 0 || len(n.Checks) > 2048 {
		return fmt.Errorf("Mac native requires a known suite and explicit checks")
	}
	expectedFixture := "gateway"
	if n.Suite == "sidebar" || n.Suite == "island" {
		expectedFixture = "none"
	}
	if fixture != expectedFixture {
		return fmt.Errorf("Mac %s requires fixture %s", n.Suite, expectedFixture)
	}
	phases := macPhases(n.Suite, "", "")
	prefixes := map[string]bool{}
	for _, phase := range phases {
		prefixes[phase.name] = true
	}
	seen := map[string]bool{}
	for _, check := range n.Checks {
		prefix, _, qualified := strings.Cut(check, ".")
		if !qualified || !prefixes[prefix] || !macCheck.MatchString(check) || seen[check] {
			return fmt.Errorf("invalid/duplicate Mac check %q", check)
		}
		seen[check] = true
	}
	return nil
}
func macPhases(suite, dir, preferences string) []macPhase {
	if suite == "sidebar" {
		return []macPhase{{"prepare", "prepare/report.json", []string{"--sidebar-ui-smoke", "prepare", "--sidebar-preferences-suite", preferences, "--ui-smoke-output", filepath.Join(dir, "prepare")}}, {"verify", "verify/report.json", []string{"--sidebar-ui-smoke", "verify", "--sidebar-preferences-suite", preferences, "--ui-smoke-output", filepath.Join(dir, "verify")}}}
	}
	if suite == "terminal" {
		return []macPhase{{"create", "create-report.json", []string{"--terminal-ui-smoke", "create", "--ui-smoke-output", dir}}, {"resume", "report.json", []string{"--terminal-ui-smoke", "resume", "--ui-smoke-output", dir}}}
	}
	flags := []string{"--" + suite + "-ui-smoke", "--ui-smoke-output", dir}
	switch suite {
	case "core", "board":
		flags = []string{"--ui-smoke", "--ui-smoke-output", dir, "--ui-smoke-offline-trigger", filepath.Join(dir, "daemon-offline")}
		if suite == "board" {
			flags = append(flags, "--board-stress-ui-smoke", "--lane-sort-ui-smoke")
		}
	case "machine":
		flags = []string{"--machine-ui-smoke", "--machine-ui-smoke-output", dir}
	case "island":
		flags = []string{"--island-ui-smoke", "--island-ui-smoke-output", dir}
	}
	return []macPhase{{suite, "report.json", flags}}
}

type macDriver struct{ root, output, app, fixtureBinary string }

func (m macDriver) preflight(ctx context.Context) error {
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("Mac execution requires an interactive macOS desktop")
	}
	out, err := command(ctx, m.root, nil, "/usr/bin/pgrep", "-x", "DieterMac")
	if strings.TrimSpace(out) != "" {
		return fmt.Errorf("DieterMac already running (PIDs %s); preserving the operator app", strings.TrimSpace(out))
	}
	if err != nil && !strings.Contains(err.Error(), "exit status 1") {
		return fmt.Errorf("cannot inventory DieterMac: %w", err)
	}
	out, err = command(ctx, m.root, nil, "/usr/bin/stat", "-f", "%Su", "/dev/console")
	if err != nil || strings.TrimSpace(out) == "root" || strings.TrimSpace(out) == "loginwindow" || strings.TrimSpace(out) == "" {
		return fmt.Errorf("Mac execution requires a logged-in desktop session")
	}
	return nil
}
func runMac(ctx context.Context, root, output string, cases []Case) error {
	started := time.Now()
	report := Report{Version: 1, Platform: "mac", Serial: "local-desktop", Results: []Result{}}
	unavailable := func(err error) error {
		for _, c := range cases {
			report.Results = append(report.Results, Result{ID: c.ID, Status: "unavailable", Reason: err.Error()})
		}
		report.DurationMS = time.Since(started).Milliseconds()
		if writeErr := writeReport(output, report); writeErr != nil {
			return fmt.Errorf("%w; report: %v", err, writeErr)
		}
		return err
	}
	fmt.Println("E2E evidence: " + output)
	if err := writeJSON(filepath.Join(output, "plan.json"), cases); err != nil {
		return err
	}
	// One visible desktop journey at a time, including builds that replace the bundle.
	unlock, err := acquireLease(filepath.Join(os.TempDir(), fmt.Sprintf("dieter-mac-e2e-%d.lock", os.Getuid())))
	if err != nil {
		return unavailable(err)
	}
	defer unlock()
	m := macDriver{root: root, output: output, app: filepath.Join(root, "apps/mac/build/Dieter.app/Contents/MacOS/DieterMac"), fixtureBinary: filepath.Join(root, "tmp/e2e-cache/isolated-gateway")}
	if err = m.preflight(ctx); err != nil {
		return unavailable(err)
	}
	unlockBuild, err := acquireLease(filepath.Join(os.TempDir(), fmt.Sprintf("dieter-e2e-build-%x.lock", sha256.Sum256([]byte(root)))))
	if err != nil {
		return unavailable(err)
	}
	buildCtx, cancel := context.WithTimeout(ctx, 20*time.Minute)
	fmt.Println("Preparing packaged Mac app with the canonical SwiftPM cache")
	buildStarted := time.Now()
	out, buildErr := command(buildCtx, root, nil, "just", "mac", "build")
	_ = os.WriteFile(filepath.Join(output, "build.log"), []byte(out), 0600)
	if buildErr == nil {
		buildErr = os.MkdirAll(filepath.Dir(m.fixtureBinary), 0700)
	}
	if buildErr == nil {
		out, buildErr = command(buildCtx, root, nil, "go", "build", "-o", m.fixtureBinary, "./scripts/isolated-gateway")
		_ = os.WriteFile(filepath.Join(output, "fixture-build.log"), []byte(out), 0600)
	}
	cancel()
	unlockBuild()
	report.BuildMS = time.Since(buildStarted).Milliseconds()
	if buildErr != nil {
		return unavailable(fmt.Errorf("Mac preparation failed: %w; see build.log and fixture-build.log", buildErr))
	}
	return runCases(ctx, output, started, &report, cases, m.run)
}
func (m macDriver) run(ctx context.Context, c Case) (result Result) {
	started := time.Now()
	result = Result{ID: c.ID, Status: "failed"}
	dir := filepath.Join(m.output, c.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		result.Reason = err.Error()
		return
	}
	if err := m.preflight(ctx); err != nil {
		result.Status = "unavailable"
		result.Reason = err.Error()
		return
	}
	state, err := os.MkdirTemp("", "dieter-mac-e2e-")
	if err != nil {
		result.Reason = err.Error()
		return
	}
	preferences := fmt.Sprintf("com.dbpprt.dieter.e2e.%x", sha256.Sum256([]byte(state)))
	var fixture, app *ownedProcess
	var secrets = map[string]string{}
	defer func() {
		var problems []string
		if result.CleanupError != "" {
			problems = append(problems, result.CleanupError)
		}
		if app != nil {
			if err := app.stop(); err != nil {
				problems = append(problems, err.Error())
			}
		}
		if fixture != nil {
			if err := fixture.stop(); err != nil {
				problems = append(problems, err.Error())
			}
			_ = os.WriteFile(filepath.Join(dir, "fixture.log"), []byte(redact(fixture.out.String(), secrets)), 0600)
		}
		cleanCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_, _ = command(cleanCtx, m.root, nil, "/usr/bin/defaults", "delete", preferences)
		if len(problems) == 0 {
			if err := os.RemoveAll(state); err != nil {
				problems = append(problems, err.Error())
			}
		}
		result.CleanupError = strings.Join(problems, "; ")
		if result.CleanupError != "" {
			result.Status = "failed"
		}
		result.DurationMS = time.Since(started).Milliseconds()
	}()
	base := []string{"--dieter-state-root", filepath.Join(state, "client"), "--appearance-defaults-suite", preferences}
	suite := "flow"
	if c.Native != nil {
		suite = c.Native.Suite
	}
	if c.Fixture == "gateway" {
		flags := []string{"--addr", "127.0.0.1:0", "--home", filepath.Join(state, "gateway")}
		if suite == "core" || suite == "board" {
			flags = append(flags, "--offline-trigger", filepath.Join(dir, "daemon-offline"))
		}
		if suite == "board" {
			flags = append(flags, "--board-stress-fixture")
		}
		if suite == "inbox" {
			flags = append(flags, "--inbox-fixture")
		}
		if suite == "terminal" {
			flags = append(flags, "--daemon-restart-trigger", filepath.Join(dir, "daemon-restart"))
		}
		fixture, err = startOwned(m.root, append([]string{m.fixtureBinary}, flags...)...)
		if err != nil {
			result.Reason = err.Error()
			return
		}
		values, readyErr := awaitGateway(ctx, fixture)
		if readyErr != nil {
			result.Reason = readyErr.Error()
			return
		}
		secrets["token"] = values["DIETER_ISOLATED_TOKEN"]
		tokenFile := filepath.Join(state, "session-token")
		if err = os.WriteFile(tokenFile, []byte(secrets["token"]), 0600); err != nil {
			result.Reason = err.Error()
			return
		}
		base = append(base, "--dieter-endpoint", "http://"+values["DIETER_ISOLATED_ADDR"], "--dieter-access-token-file", tokenFile,
			"--ui-smoke-fixture-root", filepath.Join(state, "gateway"))
	}
	if suite == "island" {
		if _, err = command(ctx, m.root, nil, "/usr/bin/defaults", "write", preferences, "DieterAppearance", "-string", "dark"); err != nil {
			result.Reason = err.Error()
			return
		}
	}
	phases := macPhases(suite, dir, preferences)
	if c.Native == nil {
		plan := filepath.Join(state, "plan.json")
		if err = writeJSON(plan, struct {
			Version int  `json:"version"`
			Case    Case `json:"case"`
		}{protocolVersion, c}); err != nil {
			result.Reason = err.Error()
			return
		}
		phases = []macPhase{{"flow", "report.json", []string{"--flow-ui-smoke", "--e2e-plan", plan, "--ui-smoke-output", dir}}}
	}
	result.SetupMS = time.Since(started).Milliseconds()
	executed := time.Now()
	all := map[string]string{}
	for _, phase := range phases {
		if suite == "terminal" && phase.name == "resume" {
			if err = requestMacRestart(ctx, dir, fixture); err != nil {
				result.Reason = err.Error()
				return
			}
		}
		if err = m.preflight(ctx); err != nil {
			result.Reason = err.Error()
			return
		}
		reportPath := filepath.Join(dir, phase.report)
		if err = os.MkdirAll(filepath.Dir(reportPath), 0700); err != nil {
			result.Reason = err.Error()
			return
		}
		app, err = startOwned(m.root, append([]string{m.app}, append(slices.Clone(base), phase.args...)...)...)
		if err != nil {
			result.Reason = err.Error()
			return
		}
		phaseResults, phaseErr := awaitMacReport(ctx, app, reportPath)
		// Reports request normal NSApp termination. Only a non-exiting owned PID is signalled.
		if stopErr := app.stop(); stopErr != nil {
			result.CleanupError = stopErr.Error()
			result.Reason = "Mac app did not stop"
			return
		}
		_ = os.WriteFile(filepath.Join(dir, "app-"+phase.name+".log"), []byte(redact(app.out.String(), secrets)), 0600)
		app = nil
		if phaseErr != nil {
			result.Reason = phaseErr.Error()
			return
		}
		for key, value := range phaseResults {
			all[phase.name+"."+key] = value
		}
	}
	result.ExecutionMS = time.Since(executed).Milliseconds()
	required := []string{}
	if c.Native != nil {
		required = c.Native.Checks
	} else {
		for index := range c.Steps {
			required = append(required, fmt.Sprintf("flow.step-%d", index))
		}
	}
	result.Status, result.Reason = macReportResult(all, required)
	return
}
func awaitMacReport(ctx context.Context, p *ownedProcess, path string) (map[string]string, error) {
	exited := false
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		info, err := os.Stat(path)
		if err == nil {
			if !info.Mode().IsRegular() || info.Size() > 1<<20 {
				return nil, fmt.Errorf("invalid/big Mac report")
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return nil, err
			}
			var results map[string]string
			if err = json.Unmarshal(data, &results); err != nil {
				return nil, err
			}
			select {
			case <-p.done:
				if p.err != nil {
					return nil, fmt.Errorf("Mac app exited unsuccessfully: %w", p.err)
				}
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(5 * time.Second):
			}
			return results, nil
		}
		if !os.IsNotExist(err) {
			return nil, err
		}
		if exited {
			return nil, fmt.Errorf("Mac app exited before report: %v", p.err)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-p.done:
			exited = true // Recheck the atomic report after observing process exit.
		case <-tick.C:
		}
	}
}
func macReportResult(results map[string]string, required []string) (string, string) {
	for key, value := range results {
		if strings.HasPrefix(strings.ToLower(value), "failed") {
			return "failed", key + ": " + value
		}
	}
	if len(required) == 0 {
		return "failed", "no required Mac checks"
	}
	for _, key := range required {
		if results[key] != "passed" {
			return "failed", fmt.Sprintf("required Mac check %s missing or not passed: %q", key, results[key])
		}
	}
	return "passed", ""
}
func requestMacRestart(ctx context.Context, dir string, p *ownedProcess) error {
	trigger := filepath.Join(dir, "daemon-restart")
	if err := os.WriteFile(trigger, nil, 0600); err != nil {
		return err
	}
	timeout, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		if _, err := os.Stat(trigger + ".ready"); err == nil {
			return nil
		}
		select {
		case <-timeout.Done():
			return timeout.Err()
		case <-p.done:
			return fmt.Errorf("fixture exited during restart")
		case <-tick.C:
		}
	}
}
