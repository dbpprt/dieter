package pipeline

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

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

// A freshly selected Xcode installation can spend well over 30 seconds
// starting CoreSimulatorService on a hosted runner. Keep the inventory probe
// bounded without treating that normal cold start as an unavailable platform.
const iosSimulatorInventoryTimeout = 2 * time.Minute

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
	detail := ""
	var visit func([]iosTestNode)
	visit = func(nodes []iosTestNode) {
		for _, node := range nodes {
			if node.Type == "Failure Message" && detail == "" {
				// The remaining lines can include the entire accessibility tree.
				line, _, _ := strings.Cut(node.Name, "\n")
				runes := []rune(line)
				detail = string(runes[:min(len(runes), 512)])
			}
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
		if detail != "" {
			reason += ": " + detail
		}
		return "failed", reason
	}
	if len(seen) != len(expected) {
		return "failed", fmt.Sprintf("incomplete XCTest results: %d/%d methods", len(seen), len(expected))
	}
	return "passed", ""
}
