package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const appPackage = "com.dbpprt.dieter.e2e"
const flowClass = "com.dbpprt.dieter.e2e.FlowTest"

type android struct{ root, adb, serial, output, fixtureBinary, variant string }

func (a android) pkg() string {
	if a.variant == "performance" {
		return appPackage + ".performance"
	}
	return appPackage
}
func (a android) buildType() string {
	if a.variant == "performance" {
		return "performance"
	}
	return "e2e"
}

func (a android) shell(ctx context.Context, input []byte, args ...string) (string, error) {
	return command(ctx, a.root, input, a.adb, "-s", a.serial, "shell", "-T", shellArgs(args))
}
func (a android) check(ctx context.Context, args ...string) error {
	out, err := a.shell(ctx, nil, args...)
	if err != nil {
		return fmt.Errorf("adb %s: %w: %s", args[0], err, out)
	}
	return nil
}
func (a android) preflight(ctx context.Context) error {
	if !regexp.MustCompile(`^[A-Za-z0-9._:-]+$`).MatchString(a.serial) {
		return fmt.Errorf("invalid device serial")
	}
	out, err := command(ctx, a.root, nil, a.adb, "-s", a.serial, "get-state")
	if err != nil || strings.TrimSpace(out) != "device" {
		return fmt.Errorf("Android device %s unavailable; start the checked visible emulator", a.serial)
	}
	for _, property := range []struct{ key, value string }{{"sys.boot_completed", "1"}, {"init.svc.bootanim", "stopped"}} {
		out, err = a.shell(ctx, nil, "getprop", property.key)
		if err != nil || strings.TrimSpace(out) != property.value {
			return fmt.Errorf("device has not completed boot: %s", property.key)
		}
	}
	out, _ = a.shell(ctx, nil, "pidof", a.pkg())
	if strings.TrimSpace(out) != "" {
		return fmt.Errorf("%s already running; preserving its owner", a.pkg())
	}
	return nil
}
func sourceDigest(root string) (string, error) {
	out, err := command(context.Background(), root, nil, "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "apps/android", "api/proto", "native/android-webrtc")
	if err != nil {
		return "", err
	}
	h := sha256.New()
	for _, p := range strings.Split(out, "\x00") {
		if p == "" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, p))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return "", err
		}
		fmt.Fprintf(h, "%s\x00", p)
		h.Write(data)
	}
	return fmt.Sprintf("%x", h.Sum(nil)), nil
}
func (a android) prepare(ctx context.Context) ([]string, error) {
	cache := filepath.Join(a.root, "tmp/e2e-cache")
	if err := os.MkdirAll(cache, 0700); err != nil {
		return nil, err
	}
	key, err := sourceDigest(a.root)
	if err != nil {
		return nil, err
	}
	java, err := command(ctx, a.root, nil, filepath.Join(os.Getenv("JAVA_HOME"), "bin/java"), "-version")
	if err != nil {
		return nil, fmt.Errorf("JAVA_HOME must select the Android JDK: %w", err)
	}
	key += java + os.Getenv("ANDROID_HOME") + os.Getenv("ANDROID_SDK_ROOT") + a.buildType()
	if keystore, err := digest(filepath.Join(os.Getenv("HOME"), ".android/debug.keystore")); err == nil {
		key += keystore
	}
	apks := []string{filepath.Join(a.root, "apps/android/app/build/outputs/apk/"+a.buildType()+"/app-"+a.buildType()+".apk"), filepath.Join(a.root, "apps/android/app/build/outputs/apk/androidTest/"+a.buildType()+"/app-"+a.buildType()+"-androidTest.apk")}
	type manifest struct {
		Key    string
		Hashes []string
	}
	var previous manifest
	data, _ := os.ReadFile(filepath.Join(cache, "android-"+a.buildType()+".json"))
	_ = json.Unmarshal(data, &previous)
	valid := previous.Key == key && len(previous.Hashes) == 2
	for i, p := range apks {
		sum, err := digest(p)
		if err != nil || !valid || sum != previous.Hashes[i] {
			valid = false
			break
		}
	}
	if !valid {
		fmt.Println("Preparing Android app and instrumentation (one Gradle invocation)")
		variant := "E2e"
		property := "-Pdieter.testBuildType=e2e"
		if a.variant == "performance" {
			variant = "Performance"
			property = "-Pdieter.testBuildType=performance"
		}
		out, err := command(ctx, a.root, nil, filepath.Join(a.root, "apps/android/gradlew"), "--project-dir", "apps/android", ":app:assemble"+variant, ":app:assemble"+variant+"AndroidTest", property)
		_ = os.WriteFile(filepath.Join(a.output, "build.log"), []byte(out), 0600)
		if err != nil {
			return nil, fmt.Errorf("Android build failed: %w; see build.log\n%s", err, last(out, 3000))
		}
		m := manifest{Key: key}
		for _, p := range apks {
			sum, err := digest(p)
			if err != nil {
				return nil, err
			}
			m.Hashes = append(m.Hashes, sum)
		}
		if err = writeJSON(filepath.Join(cache, "android-"+a.buildType()+".json"), m); err != nil {
			return nil, err
		}
	} else {
		fmt.Println("Reusing verified Android app and instrumentation; flow edits do not rebuild APKs")
	}
	out, err := command(ctx, a.root, nil, "go", "build", "-o", a.fixtureBinary, "./scripts/isolated-gateway")
	if err != nil {
		return nil, fmt.Errorf("fixture build failed: %w\n%s", err, last(out, 3000))
	}
	return apks, nil
}
func (a android) install(ctx context.Context, apks []string) error {
	for i, p := range apks {
		pkg := a.pkg()
		if i == 1 {
			pkg += ".test"
		}
		path, _ := a.shell(ctx, nil, "pm", "path", pkg)
		remote := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(path), "package:"))
		localSum, err := digest(p)
		if err != nil {
			return err
		}
		if strings.HasPrefix(remote, "/data/app/") && !strings.ContainsAny(remote, "\r\n") {
			remoteSum, _ := a.shell(ctx, nil, "sha256sum", remote)
			if strings.HasPrefix(remoteSum, localSum+" ") {
				fmt.Println("Reusing installed " + pkg)
				continue
			}
		}
		out, err := command(ctx, a.root, nil, a.adb, "-s", a.serial, "install", "-r", "-t", p)
		if err != nil || !strings.Contains(out, "Success") {
			return fmt.Errorf("install %s failed: %v %s", pkg, err, out)
		}
	}
	return nil
}
func last(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}
func redact(s string, args map[string]string) string {
	for k, v := range args {
		if (strings.Contains(strings.ToLower(k), "token") || k == "screenFixture") && v != "" {
			s = strings.ReplaceAll(s, v, "<redacted>")
		}
	}
	return regexp.MustCompile(`isolated_[0-9a-fA-F]{48}`).ReplaceAllString(s, "<redacted>")
}

func (a android) run(ctx context.Context, c Case) (result Result) {
	started := time.Now()
	result = Result{ID: c.ID, Status: "failed"}
	dir := filepath.Join(a.output, c.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		result.Reason = err.Error()
		return
	}
	args := map[string]string{"additionalTestOutputDir": "/sdcard/Android/data/" + a.pkg() + "/files", "isolatedGatewayHost": "127.0.0.1"}
	for k, v := range c.Arguments {
		args[k] = v
	}
	var fixture *ownedProcess
	var screenCleanup func() error
	var state, port string
	ownedApp := false
	reverseOwned := false
	defer func() {
		cleanCtx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		var problems []string
		if ownedApp {
			_, _ = command(cleanCtx, a.root, nil, a.adb, "-s", a.serial, "pull", "/sdcard/Android/data/"+a.pkg()+"/files", filepath.Join(dir, "captures"))
			data, err := "", fmt.Errorf("no flow artifacts")
			if c.Native == nil {
				data, err = binaryCommand(cleanCtx, a.root, a.adb, "-s", a.serial, "exec-out", "run-as", a.pkg(), "tar", "-cf", "-", "-C", "files", "e2e")
			}
			if c.Native == nil && err != nil {
				problems = append(problems, "missing flow evidence")
			}
			if err == nil {
				if captureErr := extractEvidence([]byte(data), dir); captureErr != nil {
					problems = append(problems, "flow evidence: "+captureErr.Error())
				} else if _, eventErr := os.Stat(filepath.Join(dir, "e2e/events.jsonl")); eventErr != nil {
					problems = append(problems, "missing step events")
				}
			}
			if err = a.check(cleanCtx, "am", "force-stop", a.pkg()); err != nil {
				problems = append(problems, err.Error())
			}
			out, _ := a.shell(cleanCtx, nil, "pidof", a.pkg())
			if strings.TrimSpace(out) != "" {
				problems = append(problems, "fixture app did not stop")
			}
			if a.variant != "performance" {
				if _, err = a.shell(cleanCtx, nil, "run-as", a.pkg(), "rm", "-f", "files/plan.json"); err != nil {
					problems = append(problems, "could not remove private test plan")
				}
			}
		}
		if reverseOwned {
			if out, err := command(cleanCtx, a.root, nil, a.adb, "-s", a.serial, "reverse", "--remove", "tcp:"+port); err != nil {
				problems = append(problems, "reverse cleanup: "+out)
			}
		}
		if screenCleanup != nil {
			if err := screenCleanup(); err != nil {
				problems = append(problems, err.Error())
			}
		}
		if fixture != nil {
			if err := fixture.stop(); err != nil {
				problems = append(problems, err.Error())
			} else {
				_ = os.WriteFile(filepath.Join(dir, "fixture.log"), []byte(redact(fixture.out.String(), args)), 0600)
				if state != "" {
					if err = os.RemoveAll(state); err != nil {
						problems = append(problems, err.Error())
					}
				}
			}
		}
		if result.Status == "passed" {
			if err := normalizeScreenEvidence(dir, c); err != nil {
				result.Status = "failed"
				result.Reason = err.Error()
			}
		}
		result.CleanupError = strings.Join(problems, "; ")
		if result.CleanupError != "" {
			result.Status = "failed"
		}
		result.DurationMS = time.Since(started).Milliseconds()
	}()
	if c.Fixture == "screen" {
		if err := screenAvailable(); err != nil {
			result.Status = "unavailable"
			result.Reason = err.Error()
			return
		}
		var screenArgs map[string]string
		var err error
		screenArgs, port, screenCleanup, err = a.startScreen(ctx, dir)
		if err != nil {
			result.Reason = err.Error()
			return
		}
		for k, v := range screenArgs {
			args[k] = v
		}
		if out, err := command(ctx, a.root, nil, a.adb, "-s", a.serial, "reverse", "--no-rebind", "tcp:"+port, "tcp:"+port); err != nil {
			result.Reason = out
			return
		}
		reverseOwned = true
	}

	if c.Fixture == "gateway" || c.Fixture == "activity" {
		var err error
		state, err = os.MkdirTemp("", "dieter-e2e-")
		if err != nil {
			result.Reason = err.Error()
			return
		}
		fixture, err = startOwned(a.root, a.fixtureBinary, "--addr", "127.0.0.1:0", "--home", state)
		if err != nil {
			_ = os.RemoveAll(state)
			result.Reason = err.Error()
			return
		}
		ready := time.NewTimer(60 * time.Second)
		defer ready.Stop()
		tick := time.NewTicker(100 * time.Millisecond)
		defer tick.Stop()
		for !strings.Contains(fixture.out.String(), "\nREADY\n") {
			select {
			case <-ctx.Done():
				result.Status = "interrupted"
				result.Reason = ctx.Err().Error()
				return
			case <-fixture.done:
				result.Reason = "fixture exited before readiness"
				return
			case <-ready.C:
				result.Reason = "fixture readiness timed out"
				return
			case <-tick.C:
			}
		}
		values := map[string]string{}
		for _, line := range strings.Split(fixture.out.String(), "\n") {
			if strings.HasPrefix(line, "DIETER_ISOLATED_") {
				p := strings.SplitN(line, "=", 2)
				if len(p) == 2 {
					values[p[0]] = p[1]
				}
			}
		}
		address := values["DIETER_ISOLATED_ADDR"]
		_, port, _ = strings.Cut(address, "127.0.0.1:")
		if port == "" || values["DIETER_ISOLATED_TOKEN"] == "" {
			result.Reason = "invalid fixture readiness"
			return
		}
		args["isolatedGatewayPort"] = port
		args["isolatedGatewayToken"] = values["DIETER_ISOLATED_TOKEN"]
		args["isolatedMachineId"] = values["DIETER_ISOLATED_DAEMON"]
		args["isolatedBoardId"] = values["DIETER_ISOLATED_BOARD"]
		if out, err := command(ctx, a.root, nil, a.adb, "-s", a.serial, "reverse", "--no-rebind", "tcp:"+port, "tcp:"+port); err != nil {
			result.Reason = "ADB reverse: " + out
			return
		}
		reverseOwned = true
	}
	// Explicit case arguments take precedence over environment defaults.
	for k, v := range c.Arguments {
		args[k] = v
	}
	// The package is exclusively owned under the serial lease. Never clear the operator app.
	if out, err := a.shell(ctx, nil, "pm", "clear", a.pkg()); err != nil || !strings.Contains(out, "Success") {
		result.Reason = "cannot reset isolated app: " + out
		return
	}
	ownedApp = true
	if a.variant != "performance" {
		if err := a.check(ctx, "run-as", a.pkg(), "mkdir", "-p", "files"); err != nil {
			result.Reason = err.Error()
			return
		}
		plan := struct {
			Version   int               `json:"version"`
			Case      Case              `json:"case"`
			Arguments map[string]string `json:"arguments"`
		}{protocolVersion, c, args}
		data, err := json.Marshal(plan)
		if err != nil {
			result.Reason = err.Error()
			return
		}
		if _, err = a.shell(ctx, data, "run-as", a.pkg(), "tee", "files/plan.json"); err != nil {
			result.Reason = "private plan transfer failed"
			return
		}
	}
	native := Native{Class: flowClass, Methods: []string{"runFlow"}}
	if c.Native != nil {
		native = *c.Native
	}
	filters := []string{}
	for _, m := range native.Methods {
		filters = append(filters, native.Class+"#"+m)
	}
	result.SetupMS = time.Since(started).Milliseconds()
	executed := time.Now()
	instrumentArgs := []string{"am", "instrument", "-w", "-r", "-e", "class", strings.Join(filters, ",")}
	if a.variant == "performance" {
		for k, v := range args {
			instrumentArgs = append(instrumentArgs, "-e", k, v)
		}
	} else {
		instrumentArgs = append(instrumentArgs, "-e", "e2ePlan", "plan.json")
	}
	instrumentArgs = append(instrumentArgs, a.pkg()+".test/com.dbpprt.dieter.e2e.DieterTestRunner")
	out, err := a.shell(ctx, nil, instrumentArgs...)
	result.ExecutionMS = time.Since(executed).Milliseconds()
	_ = os.WriteFile(filepath.Join(dir, "instrumentation.log"), []byte(redact(out, args)), 0600)
	result.Status, result.Reason = instrumentationResult(out, native)
	if err != nil {
		result.Status = "failed"
		result.Reason = "instrumentation command failed: " + err.Error()
	}
	if ctx.Err() != nil {
		result.Status = "interrupted"
		result.Reason = ctx.Err().Error()
	}
	logCtx, logCancel := context.WithTimeout(context.Background(), 10*time.Second)
	log, _ := a.shell(logCtx, nil, "logcat", "-d", "-T", fmt.Sprintf("%d.000", started.Unix()), "-m", "500", "-s", "DieterPerformance:I", "DieterSync:I", "DieterRecovery:I")
	logCancel()
	_ = os.WriteFile(filepath.Join(dir, "device.log"), []byte(redact(log, args)), 0600)
	if result.Status != "passed" {
		captureCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		png, _ := command(captureCtx, a.root, nil, a.adb, "-s", a.serial, "exec-out", "screencap", "-p")
		if strings.HasPrefix(png, "\x89PNG") {
			_ = os.WriteFile(filepath.Join(dir, "failure.png"), []byte(png), 0600)
		}
		log, _ := a.shell(captureCtx, nil, "logcat", "-d", "-T", fmt.Sprintf("%d.000", started.Unix()), "-m", "300", "-s", "AndroidRuntime:E", "TestRunner:I")
		_ = os.WriteFile(filepath.Join(dir, "failure.log"), []byte(redact(log, args)), 0600)
	}
	return
}
