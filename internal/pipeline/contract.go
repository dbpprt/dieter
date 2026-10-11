package pipeline

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
)

// ContractRequest is bounded data. It never contains an executable or an
// execution operation: Fastlane owns stage scheduling and runs every check.
type ContractRequest struct {
	Base  string   `json:"base,omitempty"`
	Paths []string `json:"paths,omitempty"`
	Kind  string   `json:"kind,omitempty"`
}

const contractHelp = `pipeline-contract affected-checks
Bounded JSON request on stdin ({"base","paths","kind"}); JSON check plan on stdout.
Pure change planning; no builds, devices or test execution.`

func Contract(ctx context.Context, root string, args []string, input io.Reader, output io.Writer) error {
	if len(args) != 1 || args[0] == "--help" || args[0] == "help" {
		_, err := fmt.Fprintln(output, contractHelp)
		return err
	}
	if args[0] != "affected-checks" {
		return fmt.Errorf("unknown contract operation %q", args[0])
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
	plan, err := affectedChecks(ctx, root, request)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(plan)
}
