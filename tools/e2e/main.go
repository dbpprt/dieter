// Dieter's repository test runner. It never targets the running Dieter daemon.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := execute(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "e2e:", err)
		os.Exit(1)
	}
}
func execute(ctx context.Context, args []string) error {
	if len(args) > 0 && args[0] == "device-lease" {
		return leasedCommand(ctx, args[1:])
	}
	if len(args) == 0 || args[0] == "--help" || args[0] == "help" {
		fmt.Println("Usage: just e2e <list|lint|plan|prepare|run> [--platform android|ios] [--suite smoke|functional|component|sync|screens|performance] [--case ID] [--serial SERIAL] [--changed] [--base REF]\nAndroid executes against isolated app/daemon state. iOS supports plan/prepare only. Mac is disabled. Required skipped/missing tests fail. --changed selects conservatively from Git; --base includes branch changes. prepare emits a versioned native-driver JSON plan without starting apps.")
		return nil
	}
	action := args[0]
	if !slices.Contains([]string{"list", "lint", "plan", "prepare", "run"}, action) {
		return fmt.Errorf("unknown command %q", action)
	}
	flags := flag.NewFlagSet(action, flag.ContinueOnError)
	platform := flags.String("platform", "android", "Android executes; iOS is preparation-only; Mac is disabled")
	suite := flags.String("suite", "", "Suite (run defaults to smoke); performance is separate")
	id := flags.String("case", "", "Exact case IDs, comma-separated")
	serial := flags.String("serial", env("ANDROID_SERIAL", "emulator-5554"), "Exact Android device serial; never auto-select a device")
	device := flags.String("device", "iphone", "Prepared iOS layout: iphone or ipad")
	changed := flags.Bool("changed", false, "Select cases affected by Git changes")
	base := flags.String("base", "", "Include changes since merge base with this ref")
	outputDir := flags.String("output", "", "Run artifact directory; must not already exist (default tmp/e2e-<run>)")
	if err := flags.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	if *outputDir != "" && action != "run" {
		return fmt.Errorf("--output is only supported by run")
	}
	if *device != "iphone" && *device != "ipad" {
		return fmt.Errorf("unknown iOS device layout %q", *device)
	}
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	if _, err = os.Stat(filepath.Join(root, "api/contract-version")); err != nil {
		return fmt.Errorf("run from the repository root")
	}
	cases, err := catalog(root)
	if err != nil {
		return err
	}
	if action == "lint" {
		fmt.Printf("Validated %d cases (strict version, references, steps, selectors and bounds)\n", len(cases))
		return nil
	}
	if *platform != "android" && *platform != "ios" {
		return fmt.Errorf("platform %q is disabled; Mac adapter is not yet implemented", *platform)
	}
	if action == "run" && *platform != "android" {
		return fmt.Errorf("iOS execution is prepared, not enabled; use prepare --platform ios")
	}
	if *suite == "" && *id == "" && action == "run" {
		*suite = "smoke"
	}
	selected := []Case{}
	for _, c := range cases {
		if c.Platform == *platform && (*suite == "" || slices.Contains(c.Suites, *suite)) && (*id == "" || slices.Contains(strings.Split(*id, ","), c.ID)) {
			selected = append(selected, c)
		}
	}
	if *id != "" {
		for _, requested := range strings.Split(*id, ",") {
			found := false
			for _, c := range selected {
				found = found || c.ID == requested
			}
			if !found {
				return fmt.Errorf("requested case %q was not selected", requested)
			}
		}
	}
	if len(selected) == 0 {
		return fmt.Errorf("no cases match platform=%s suite=%s case=%s", *platform, *suite, *id)
	}
	if *changed {
		paths, err := changedPaths(ctx, root, *base)
		if err != nil {
			return err
		}
		selected = affected(selected, paths)
		if len(selected) == 0 {
			fmt.Println("No affected E2E cases.")
			return nil
		}
	}
	if action == "list" {
		for _, c := range selected {
			kind := "flow"
			if c.Native != nil {
				kind = "native"
			}
			fmt.Printf("%-48s %-8s %-8s %s\n", c.ID, c.Platform, kind, strings.Join(c.Suites, ","))
		}
		return nil
	}
	if action == "plan" || action == "prepare" {
		data, err := json.MarshalIndent(struct {
			Version   int    `json:"version"`
			Platform  string `json:"platform"`
			Execution string `json:"execution"`
			Device    string `json:"device"`
			Cases     []Case `json:"cases"`
		}{1, *platform, map[string]string{"android": "enabled", "ios": "prepared"}[*platform], *device, selected}, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}
	output, err := createOutput(root, *outputDir)
	if err != nil {
		return err
	}
	return runAndroid(ctx, root, output, *serial, selected)
}

func createOutput(root, requested string) (string, error) {
	if requested == "" {
		parent := filepath.Join(root, "tmp")
		if err := os.MkdirAll(parent, 0700); err != nil {
			return "", err
		}
		return os.MkdirTemp(parent, "e2e-")
	}
	if !filepath.IsAbs(requested) {
		requested = filepath.Join(root, requested)
	}
	if err := os.MkdirAll(filepath.Dir(requested), 0700); err != nil {
		return "", err
	}
	// Never mix another run's evidence (or cache files) into this run.
	if err := os.Mkdir(requested, 0700); err != nil {
		return "", fmt.Errorf("create fresh output directory: %w", err)
	}
	return requested, nil
}
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
func runAndroid(ctx context.Context, root, output, serial string, cases []Case) error {
	started := time.Now()
	report := Report{Version: 1, Platform: "android", Serial: serial, Results: []Result{}}
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
	unlock, err := deviceLease(serial)
	if err != nil {
		return unavailable(err)
	}
	defer unlock()
	unlockCache, err := acquireLease(filepath.Join("/tmp", fmt.Sprintf("dieter-e2e-build-%x.lock", sha256.Sum256([]byte(root)))))
	if err != nil {
		return unavailable(err)
	}
	defer func() {
		if unlockCache != nil {
			unlockCache()
		}
	}()
	sdk := env("ANDROID_HOME", env("ANDROID_SDK_ROOT", filepath.Join(os.Getenv("HOME"), "Library/Android/sdk")))
	a := android{root: root, adb: filepath.Join(sdk, "platform-tools/adb"), serial: serial, output: output, fixtureBinary: filepath.Join(root, "tmp/e2e-cache/isolated-gateway")}
	prepared := map[string]bool{}
	for _, c := range cases {
		a.variant = c.Build
		if prepared[a.buildType()] {
			continue
		}
		if a.variant == "performance" && !strings.HasPrefix(serial, "emulator-") {
			return unavailable(fmt.Errorf("performance qualification requires the selected emulator"))
		}
		preflight, cancel := context.WithTimeout(ctx, 30*time.Second)
		err = a.preflight(preflight)
		cancel()
		if err != nil {
			return unavailable(err)
		}
		build, cancel := context.WithTimeout(ctx, 20*time.Minute)
		buildStarted := time.Now()
		apks, buildErr := a.prepare(build)
		report.BuildMS += time.Since(buildStarted).Milliseconds()
		if buildErr == nil {
			installed := time.Now()
			buildErr = a.install(build, apks)
			report.InstallMS += time.Since(installed).Milliseconds()
		}
		cancel()
		if buildErr != nil {
			return unavailable(buildErr)
		}
		prepared[a.buildType()] = true
	}
	unlockCache()
	unlockCache = nil // Device execution can overlap on different leased devices.
	failed := 0
	for _, c := range cases {
		a.variant = c.Build
		fmt.Printf("Running %s (%s, fresh app state)\n", c.ID, c.Fixture)
		duration, _ := time.ParseDuration(c.Timeout)
		caseCtx, cancel := context.WithTimeout(ctx, duration)
		result := a.run(caseCtx, c)
		cancel()
		report.Results = append(report.Results, result)
		fmt.Printf("%s %s: %d ms %s %s\n", strings.ToUpper(result.Status), c.ID, result.DurationMS, result.Reason, result.CleanupError)
		if result.Status != "passed" {
			failed++
		}
		report.DurationMS = time.Since(started).Milliseconds()
		if err = writeReport(output, report); err != nil {
			return err
		}
		if ctx.Err() != nil || result.CleanupError != "" {
			for _, remaining := range cases[len(report.Results):] {
				report.Results = append(report.Results, Result{ID: remaining.ID, Status: "interrupted", Reason: "previous case interrupted or cleanup failed"})
				failed++
			}
			break
		}
	}
	report.DurationMS = time.Since(started).Milliseconds()
	if err = writeReport(output, report); err != nil {
		return err
	}
	fmt.Printf("%d requested, %d passed, %d failed/unavailable; build=%d ms install=%d ms total=%d ms\n", len(cases), len(cases)-failed, failed, report.BuildMS, report.InstallMS, report.DurationMS)
	if err := writeSDKReport(output, serial, cases, report.Results); err != nil {
		return err
	}
	if failed > 0 {
		return fmt.Errorf("%d required cases did not pass; %s", failed, output)
	}
	return nil
}

func changedPaths(ctx context.Context, root, base string) ([]string, error) {
	ref := "HEAD"
	if base != "" {
		out, err := command(ctx, root, nil, "git", "merge-base", base, "HEAD")
		if err != nil {
			return nil, err
		}
		ref = strings.TrimSpace(out)
	}
	tracked, err := command(ctx, root, nil, "git", "diff", "--name-only", "--no-renames", "-z", ref, "--")
	if err != nil {
		return nil, err
	}
	untracked, err := command(ctx, root, nil, "git", "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return nil, err
	}
	return strings.Split(tracked+untracked, "\x00"), nil
}

// Feature-specific paths narrow device work; shared and unknown app paths fail broad.
func affected(cases []Case, paths []string) []Case {
	components := map[string]bool{}
	broad := false
	for _, p := range paths {
		if p == "" || strings.HasSuffix(p, ".md") || strings.HasSuffix(p, ".txt") {
			continue
		}
		if strings.HasPrefix(p, "tests/e2e/") || strings.HasPrefix(p, "tools/e2e/") || strings.HasPrefix(p, "api/") || strings.HasPrefix(p, "scripts/isolated-gateway/") || p == "just/e2e.just" || p == "just/android.just" {
			broad = true
			continue
		}
		if !strings.HasPrefix(p, "apps/android/") && !strings.HasPrefix(p, "native/android-webrtc/") {
			continue
		}
		if strings.HasPrefix(p, "apps/android/app/src/test/") {
			continue
		}
		lower := strings.ToLower(p)
		found := false
		for key, terms := range map[string][]string{"machines": {"machines", "machineinformation"}, "activity": {"activityscreen", "activityfeed"}, "screens": {"/screens/", "webrtc", "screensscreen"}, "schedules": {"schedule"}, "conversation": {"conversation", "composer", "message"}, "workspace": {"workspace", "project"}} {
			for _, term := range terms {
				if strings.Contains(lower, term) {
					components[key] = true
					found = true
				}
			}
		}
		if !found {
			broad = true
		}
	}
	result := []Case{}
	for _, c := range cases {
		match := broad
		for _, component := range c.Components {
			match = match || components[component]
		}
		if match {
			result = append(result, c)
		}
	}
	return result
}
