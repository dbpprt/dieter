package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Android screen qualification still requires the native capture host. This is
// not a Mac app adapter; Mac viewer/multi-client execution remains disabled.
func screenAvailable() error {
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("native screen fixture requires a macOS capture host (unavailable on %s)", runtime.GOOS)
	}
	if os.Getenv("DIETER_SCREEN_TEST_MULTI") == "1" {
		return fmt.Errorf("Mac companion execution is disabled")
	}
	return nil
}
func waitFile(ctx context.Context, p *ownedProcess, path string) error {
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		if info, err := os.Stat(path); err == nil && info.Size() > 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-p.done:
			return fmt.Errorf("owned fixture exited before %s", filepath.Base(path))
		case <-tick.C:
		}
	}
}
func (a android) startScreen(ctx context.Context, dir string) (values map[string]string, port string, cleanup func() error, err error) {
	values = map[string]string{}
	state, err := os.MkdirTemp("", "dieter-e2e-screen-")
	if err != nil {
		return nil, "", nil, err
	}
	var processes []*ownedProcess
	cleanup = func() error {
		var problems []string
		for i := len(processes) - 1; i >= 0; i-- {
			if e := processes[i].stop(); e != nil {
				problems = append(problems, e.Error())
			}
			_ = os.WriteFile(filepath.Join(dir, fmt.Sprintf("screen-process-%d.log", i)), []byte(redact(processes[i].out.String(), values)), 0600)
		}
		if len(problems) > 0 {
			return fmt.Errorf("%s", strings.Join(problems, "; "))
		}
		if data, e := os.ReadFile(filepath.Join(state, "input.json")); e == nil {
			_ = os.WriteFile(filepath.Join(dir, "input.json"), data, 0600)
		}
		return os.RemoveAll(state)
	}
	source := env("DIETER_SCREEN_TEST_SOURCE", "native-synthetic")
	if source != "native-synthetic" && source != "screen" {
		return values, "", cleanup, fmt.Errorf("unknown screen source")
	}
	helper := filepath.Join(state, "dieter-capture")
	binary := filepath.Join(state, "screens-fixture")
	target := filepath.Join(state, "InputTarget.app/Contents/MacOS/InputTarget")
	if err = os.MkdirAll(filepath.Dir(target), 0700); err != nil {
		return
	}
	plist := `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>InputTarget</string><key>CFBundleIdentifier</key><string>com.dbpprt.dieter.screen-input-fixture</string><key>CFBundleName</key><string>Dieter Input Fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>`
	if err = os.WriteFile(filepath.Join(state, "InputTarget.app/Contents/Info.plist"), []byte(plist), 0600); err != nil {
		return
	}
	for _, argv := range [][]string{{"bash", "native/macos-capture/build.sh", helper}, {"go", "build", "-o", binary, "./scripts/screens-fixture"}, {"xcrun", "swiftc", "-parse-as-library", "-O", "-framework", "AppKit", "native/macos-capture/tests/InputTarget.swift", "-o", target}, {"codesign", "--force", "--sign", "-", filepath.Join(state, "InputTarget.app")}} {
		var out string
		out, err = command(ctx, a.root, nil, argv...)
		if err != nil {
			err = fmt.Errorf("screen preparation: %w: %s", err, last(out, 1500))
			return
		}
	}
	var fixture *ownedProcess
	fixture, err = startOwned(a.root, binary, "--helper", helper, "--source", source, "--authenticate", "--ready", filepath.Join(state, "ready.json"))
	if err != nil {
		return
	}
	processes = append(processes, fixture)
	readyCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	if err = waitFile(readyCtx, fixture, filepath.Join(state, "ready.json")); err != nil {
		return
	}
	var data []byte
	data, err = os.ReadFile(filepath.Join(state, "ready.json"))
	if err != nil {
		return
	}
	var ready map[string]any
	if err = json.Unmarshal(data, &ready); err != nil {
		return
	}
	if token, ok := ready["token"].(string); ok {
		values["screenToken"] = token
	}
	clipboard, ok := ready["clipboardName"].(string)
	if !ok {
		err = fmt.Errorf("screen fixture missing clipboard identity")
		return
	}
	var input *ownedProcess
	input, err = startOwned(a.root, target, filepath.Join(state, "input.json"), fmt.Sprint(os.Getpid()), clipboard)
	if err != nil {
		return
	}
	processes = append(processes, input)
	if err = waitFile(readyCtx, input, filepath.Join(state, "input.json")); err != nil {
		return
	}
	data, err = os.ReadFile(filepath.Join(state, "input.json"))
	if err != nil {
		return
	}
	var position map[string]any
	if err = json.Unmarshal(data, &position); err != nil {
		return
	}
	if position["active"] != true {
		err = fmt.Errorf("owned input fixture is not focused")
		return
	}
	address, ok := ready["url"].(string)
	if !ok {
		err = fmt.Errorf("missing screen address")
		return
	}
	var endpoint *url.URL
	endpoint, err = url.Parse(address)
	if err != nil {
		return
	}
	port = endpoint.Port()
	ready["port"] = json.Number(port)
	ready["real"] = source == "screen"
	ready["multi"] = false
	ready["targetX"] = position["x"]
	ready["targetY"] = position["y"]
	data, err = json.Marshal(ready)
	if err != nil {
		return
	}
	values["screenFixture"] = base64.StdEncoding.EncodeToString(data)
	for key, envName := range map[string]string{"screenLowLatency": "DIETER_SCREEN_TEST_LOW_LATENCY", "screenSurface": "DIETER_SCREEN_TEST_SURFACE", "screenDirectSurface": "DIETER_SCREEN_TEST_DIRECT_SURFACE", "forceTURN": "DIETER_TEST_FORCE_TURN"} {
		fallback := "0"
		if key == "screenLowLatency" {
			fallback = "1"
		}
		v := env(envName, fallback)
		if v != "0" && v != "1" {
			err = fmt.Errorf("invalid %s", envName)
			return
		}
		values[key] = v
	}
	return
}
