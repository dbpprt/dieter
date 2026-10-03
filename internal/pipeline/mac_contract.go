package pipeline

import (
	"fmt"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
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
	// The sidebar needs an account for shared navigation, so only the Island
	// runs without a gateway.
	expectedFixture := "gateway"
	if n.Suite == "island" {
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
