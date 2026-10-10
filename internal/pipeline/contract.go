package pipeline

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// ContractRequest is bounded data. It never contains an executable or a suite
// execution operation: Fastlane owns stage and case scheduling.
type ContractRequest struct {
	Platform string            `json:"platform,omitempty"`
	Suite    string            `json:"suite,omitempty"`
	IDs      []string          `json:"ids,omitempty"`
	Device   string            `json:"device,omitempty"`
	Changed  bool              `json:"changed,omitempty"`
	Base     string            `json:"base,omitempty"`
	Paths    []string          `json:"paths,omitempty"`
	Path     string            `json:"path,omitempty"`
	Output   string            `json:"output,omitempty"`
	Products string            `json:"products,omitempty"`
	Target   string            `json:"target,omitempty"`
	Kind     string            `json:"kind,omitempty"`
	Values   map[string]string `json:"values,omitempty"`
	Case     *Case             `json:"case,omitempty"`
	Cases    []Case            `json:"cases,omitempty"`
	Report   *Report           `json:"report,omitempty"`
}

func Contract(ctx context.Context, root string, args []string, input io.Reader, output io.Writer) error {
	if len(args) != 1 || args[0] == "--help" || args[0] == "help" {
		_, err := fmt.Fprintln(output, "pipeline-contract <affected-checks|lint|plan|qualify|report|xctestrun|mac-phases|android-digest>\nBounded JSON request on stdin; JSON response on stdout. Pure planning, codecs and qualification; no builds, devices or case execution.")
		return err
	}
	var request ContractRequest
	decoder := json.NewDecoder(io.LimitReader(input, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return fmt.Errorf("invalid contract request: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return fmt.Errorf("request must contain one JSON object")
	}
	emit := func(value any) error { return json.NewEncoder(output).Encode(value) }
	read := func(path string, maximum int64) ([]byte, error) {
		file, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		defer file.Close()
		data, err := io.ReadAll(io.LimitReader(file, maximum+1))
		if int64(len(data)) > maximum {
			return nil, fmt.Errorf("input exceeds %d bytes", maximum)
		}
		return data, err
	}
	switch args[0] {
	case "affected-checks":
		plan, err := affectedChecks(ctx, root, request)
		if err != nil {
			return err
		}
		return emit(plan)
	case "lint", "plan":
		cases, err := catalog(root)
		if err != nil {
			return err
		}
		if args[0] == "lint" {
			return emit(map[string]any{"version": 1, "count": len(cases), "passed": true})
		}
		if !slices.Contains([]string{"android", "ios", "mac"}, request.Platform) {
			return fmt.Errorf("invalid platform %q", request.Platform)
		}
		if request.Device == "" {
			request.Device = "iphone"
		}
		selected := []Case{}
		for _, c := range cases {
			if c.Platform == request.Platform && (len(c.Devices) == 0 || slices.Contains(c.Devices, request.Device)) && (request.Suite == "" || slices.Contains(c.Suites, request.Suite)) && (len(request.IDs) == 0 || slices.Contains(request.IDs, c.ID)) {
				selected = append(selected, c)
			}
		}
		for _, id := range request.IDs {
			if !slices.ContainsFunc(selected, func(c Case) bool { return c.ID == id }) {
				return fmt.Errorf("requested case %q is incompatible or missing", id)
			}
		}
		if len(selected) == 0 {
			return fmt.Errorf("no cases match the selection")
		}
		if request.Changed {
			paths, err := changedPaths(ctx, root, request.Base)
			if err != nil {
				return err
			}
			selected = affected(selected, paths)
		}
		return emit(map[string]any{"version": 1, "platform": request.Platform, "device": request.Device, "cases": selected})
	case "qualify":
		if request.Case == nil || request.Case.Native == nil {
			return fmt.Errorf("native qualification requires an explicit case")
		}
		data, err := read(request.Path, 32<<20)
		if err != nil {
			return err
		}
		status, reason := "failed", "unknown native result"
		switch request.Platform {
		case "android":
			status, reason = instrumentationResult(string(data), *request.Case.Native)
		case "ios":
			status, reason = iosTestResult(data, *request.Case.Native)
		case "mac":
			var values map[string]string
			if err = json.Unmarshal(data, &values); err != nil {
				return err
			}
			status, reason = macReportResult(values, request.Case.Native.Checks)
		default:
			return fmt.Errorf("unknown result platform")
		}
		return emit(map[string]string{"status": status, "reason": reason})
	case "report":
		if request.Report == nil || len(request.Cases) == 0 {
			return fmt.Errorf("report requires its complete nonempty case plan")
		}
		expected := map[string]bool{}
		for _, c := range request.Cases {
			if expected[c.ID] {
				return fmt.Errorf("duplicate planned case %s", c.ID)
			}
			expected[c.ID] = true
		}
		seen := map[string]bool{}
		for _, result := range request.Report.Results {
			if !expected[result.ID] || seen[result.ID] || !slices.Contains([]string{"passed", "failed", "unavailable", "interrupted"}, result.Status) {
				return fmt.Errorf("unexpected, duplicate or invalid case result %s", result.ID)
			}
			seen[result.ID] = true
		}
		if len(seen) != len(expected) {
			return fmt.Errorf("report is missing required case results")
		}
		return writeReport(request.Output, *request.Report)
	case "xctestrun":
		data, err := read(request.Path, 4<<20)
		if err != nil {
			return err
		}
		var value any
		if err = json.Unmarshal(data, &value); err != nil {
			return err
		}
		if configureIOSTestRun(value, request.Products, request.Values, request.Target) != 1 {
			return fmt.Errorf("expected exactly one XCTest target %s", request.Target)
		}
		return writeJSON(request.Output, value)
	case "mac-phases":
		phases := []map[string]any{}
		for _, phase := range macPhases(request.Suite, request.Output, request.Target) {
			phases = append(phases, map[string]any{"name": phase.name, "report": phase.report, "argv": phase.args})
		}
		return emit(phases)
	case "android-digest":
		value, err := sourceDigest(ctx, root)
		if err != nil {
			return err
		}
		return emit(map[string]string{"sha256": value})
	default:
		return fmt.Errorf("unknown contract operation %q", args[0])
	}
}

func repositoryRoot(root string) error {
	if _, err := os.Stat(filepath.Join(root, "api/proto/dieter/v1/dieter.proto")); err != nil {
		return fmt.Errorf("run from the repository root")
	}
	return nil
}

// Support keeps primitive argv process/lease semantics available independently
// of Ruby. It never selects cases, discovers products, or sequences builds.
func Support(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] == "--help" {
		fmt.Println("pipeline-support device-lease SERIAL COMMAND [ARGS...]\nHold one exact-device lease across an exact-argv child; cancellation waits for owned children.")
		return nil
	}
	if strings.TrimSpace(args[0]) != "device-lease" {
		return fmt.Errorf("unknown primitive %q", args[0])
	}
	return leasedCommand(ctx, args[1:])
}
