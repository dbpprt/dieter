package main

import (
	"encoding/json"
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type Result struct {
	ID           string `json:"id"`
	Status       string `json:"status"`
	Reason       string `json:"reason,omitempty"`
	DurationMS   int64  `json:"durationMs"`
	SetupMS      int64  `json:"setupMs"`
	ExecutionMS  int64  `json:"executionMs"`
	CleanupError string `json:"cleanupError,omitempty"`
}
type Report struct {
	Version    int      `json:"version"`
	Platform   string   `json:"platform"`
	Serial     string   `json:"serial"`
	BuildMS    int64    `json:"buildMs"`
	InstallMS  int64    `json:"installMs"`
	DurationMS int64    `json:"durationMs"`
	Results    []Result `json:"results"`
}

// Require exact completions, not just am instrument's (usually zero) shell exit.
func instrumentationResult(output string, n Native) (string, string) {
	expected := map[string]bool{}
	for _, m := range n.Methods {
		expected[n.Class+"#"+m] = true
	}
	completed := map[string]bool{}
	started := map[string]bool{}
	fields := map[string]string{}
	status, reason := "passed", ""
	final := false
	for _, line := range strings.Split(strings.ReplaceAll(output, "\r", ""), "\n") {
		if strings.HasPrefix(line, "INSTRUMENTATION_STATUS: ") {
			pair := strings.SplitN(strings.TrimPrefix(line, "INSTRUMENTATION_STATUS: "), "=", 2)
			if len(pair) == 2 {
				fields[pair[0]] = pair[1]
			}
		}
		if strings.HasPrefix(line, "INSTRUMENTATION_STATUS_CODE: ") {
			code, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "INSTRUMENTATION_STATUS_CODE: ")))
			if err != nil {
				return "failed", "invalid instrumentation status"
			}
			key := fields["class"] + "#" + fields["test"]
			if code == 1 {
				if !expected[key] || started[key] {
					return "failed", "unexpected/duplicate test start: " + key
				}
				started[key] = true
			}
			if code <= 0 {
				if !expected[key] || completed[key] || !started[key] {
					return "failed", "unexpected, missing start, or duplicate completion: " + key
				}
				completed[key] = true
				if code == -3 || code == -4 {
					if status != "failed" {
						status = "unavailable"
					}
					reason = "required native test skipped: " + key
				} else if code != 0 {
					status = "failed"
					reason = "native assertion failed: " + key
				}
			}
			fields = map[string]string{}
		}
		if strings.HasPrefix(line, "INSTRUMENTATION_CODE: ") {
			if strings.TrimSpace(strings.TrimPrefix(line, "INSTRUMENTATION_CODE: ")) != "-1" {
				return "failed", "instrumentation did not complete successfully"
			}
			final = true
		}
		if strings.HasPrefix(line, "INSTRUMENTATION_FAILED:") {
			return "failed", "instrumentation startup failed"
		}
	}
	if !final || len(completed) != len(expected) {
		return "failed", fmt.Sprintf("incomplete results: %d/%d expected tests; final=%t", len(completed), len(expected), final)
	}
	return status, reason
}
func writeJSON(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return atomicFile(path, append(data, '\n'))
}
func writeReport(dir string, r Report) error {
	if err := writeJSON(filepath.Join(dir, "results.json"), r); err != nil {
		return err
	}
	type failure struct {
		Message string `xml:"message,attr"`
	}
	type testcase struct {
		Name    string   `xml:"name,attr"`
		Class   string   `xml:"classname,attr"`
		Time    string   `xml:"time,attr"`
		Failure *failure `xml:"failure,omitempty"`
	}
	type suite struct {
		XMLName  xml.Name   `xml:"testsuite"`
		Name     string     `xml:"name,attr"`
		Tests    int        `xml:"tests,attr"`
		Failures int        `xml:"failures,attr"`
		Cases    []testcase `xml:"testcase"`
	}
	s := suite{Name: "Dieter " + r.Platform, Tests: len(r.Results)}
	for _, v := range r.Results {
		c := testcase{Name: v.ID, Class: r.Platform, Time: fmt.Sprintf("%.3f", float64(v.DurationMS)/1000)}
		if v.Status != "passed" || v.CleanupError != "" {
			s.Failures++
			c.Failure = &failure{Message: v.Status + ": " + v.Reason + " " + v.CleanupError}
		}
		s.Cases = append(s.Cases, c)
	}
	data, err := xml.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return atomicFile(filepath.Join(dir, "junit.xml"), append([]byte(xml.Header), data...))
}

func atomicFile(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".e2e-write-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
