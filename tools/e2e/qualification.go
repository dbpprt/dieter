package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var sdkClasses = []string{"org.webrtc.DieterSurfaceOutputTest", "org.webrtc.DieterLowLatencyCodecTest", "com.dbpprt.dieter.settings.DieterLauncherIconTest"}

func writeSDKReport(dir, serial string, cases []Case, results []Result) error {
	selected := map[string]bool{}
	passed := map[string]bool{}
	for _, r := range results {
		passed[r.ID] = r.Status == "passed"
	}
	methods := []map[string]string{}
	for _, c := range cases {
		if c.Native == nil {
			continue
		}
		for _, class := range sdkClasses {
			if c.Native.Class == class && passed[c.ID] {
				selected[class] = true
				for _, method := range c.Native.Methods {
					methods = append(methods, map[string]string{"class": class, "name": method})
				}
			}
		}
	}
	if len(selected) != len(sdkClasses) {
		return nil
	}
	if len(methods) < 16 {
		return fmt.Errorf("SDK coverage requires at least 16 exact methods")
	}
	return writeJSON(filepath.Join(dir, "decoder-sdk.json"), map[string]any{"schemaVersion": 1, "serial": serial, "tests": len(methods), "failures": 0, "skipped": 0, "cases": methods})
}

func normalizeScreenEvidence(dir string, c Case) error {
	if c.Native == nil || c.Fixture != "screen" {
		return nil
	}
	required := map[string]string{}
	optional := map[string]string{}
	switch c.Native.Class {
	case "com.dbpprt.dieter.screens.ScreenEndToEndTest":
		required = map[string]string{"screen-e2e.png": "viewer.png", "screen-e2e-stats.json": "stats.json"}
		for _, phase := range []string{"fit", "pan", "pinch"} {
			required["screen-canvas-"+phase+".png"] = "canvas-" + phase + ".png"
		}
	case "com.dbpprt.dieter.screens.ScreenCodecEndToEndTest":
		required = map[string]string{"screen-codec.png": "viewer.png", "screen-decoder-H264.json": "decoder-H264.json"}
		optional = map[string]string{"screen-hevc.png": "hevc.png", "screen-decoder-H265.json": "decoder-H265.json"}
	case "com.dbpprt.dieter.screens.ScreenRecoveryEndToEndTest":
		required = map[string]string{"screen-recovery.json": "recovery.json", "screen-recovery-H264.png": "recovery-H264.png", "screen-recovery-H265.png": "recovery-H265.png"}
	}
	for source, dest := range optional {
		if _, err := os.Stat(filepath.Join(dir, "captures", source)); err == nil {
			required[source] = dest
		}
	}
	for source, dest := range required {
		path := filepath.Join(dir, "captures", source)
		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("required screen evidence %s: %w", source, err)
		}
		if !info.Mode().IsRegular() || info.Size() == 0 || info.Size() > 16<<20 {
			return fmt.Errorf("invalid screen evidence %s", source)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(dir, dest), data, 0600); err != nil {
			return err
		}
	}
	if c.Native.Class == "com.dbpprt.dieter.screens.ScreenEndToEndTest" && os.Getenv("DIETER_SCREEN_TEST_SOURCE") == "screen" {
		data, err := os.ReadFile(filepath.Join(dir, "input.json"))
		if err != nil {
			return err
		}
		return validateHostInput(data)
	}
	return nil
}
func validateHostInput(data []byte) error {
	var input struct {
		Ups     int      `json:"ups"`
		Text    string   `json:"text"`
		Scrolls int      `json:"scrolls"`
		Keys    []string `json:"keys"`
	}
	if err := json.Unmarshal(data, &input); err != nil {
		return err
	}
	if input.Ups < 1 || input.Scrolls < 1 || !strings.Contains(input.Text, "Android écran 世界") || !strings.Contains(input.Text, "Android native paste marker") || strings.Contains(input.Text, "temporary") || !strings.Contains(strings.Join(input.Keys, ","), "0:up") {
		return fmt.Errorf("owned host input did not confirm click, Unicode, paste, scroll and held-key release")
	}
	return nil
}
