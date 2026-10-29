// Command spike runs the agent-workspace spike: fixtures, views, scenario
// turns through a script driver or real Codex/Claude sessions, recorders and
// an independent oracle, and reports.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"dieter.spike/workspaces/core"
	"dieter.spike/workspaces/linuxfs"
	"dieter.spike/workspaces/tree"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: spike fixture|scan|exec-steps|run|e1|snapcost|concurrency|report …")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "fixture":
		err = cmdFixture(os.Args[2:])
	case "scan":
		err = cmdScan(os.Args[2:])
	case "exec-steps":
		err = cmdExecSteps(os.Args[2:])
	case "run":
		err = cmdRun(os.Args[2:])
	case "e1":
		err = cmdE1(os.Args[2:])
	case "snapcost":
		err = cmdSnapCost(os.Args[2:])
	case "concurrency":
		err = cmdConcurrency(os.Args[2:])
	case "bwrap-retry":
		err = cmdBwrapRetry(os.Args[2:])
	case "clone":
		err = cmdClone(os.Args[2:])
	case "report":
		err = cmdReport(os.Args[2:])
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "spike:", err)
		os.Exit(1)
	}
}

func cmdFixture(args []string) error {
	fs := flag.NewFlagSet("fixture", flag.ExitOnError)
	dir := fs.String("dir", "", "fixture directory (must not exist or be empty)")
	profile := fs.String("profile", "small", "small|js|huge")
	assets := fs.String("assets", "", "assets directory (dep.tgz)")
	subvol := fs.Bool("subvolume", false, "linux: create the fixture as a btrfs subvolume")
	_ = fs.Parse(args)
	if *subvol && runtime.GOOS == "linux" {
		if err := os.MkdirAll(filepath.Dir(*dir), 0o755); err != nil {
			return err
		}
		if err := linuxfs.SubvolumeCreate(*dir); err != nil {
			return err
		}
	}
	info, err := tree.BuildFixture(*dir, *profile, *assets)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(info)
}

// cmdScan is the oracle entry point; it also runs inside namespaces.
func cmdScan(args []string) error {
	fs := flag.NewFlagSet("scan", flag.ExitOnError)
	root := fs.String("root", ".", "directory to scan")
	out := fs.String("out", "", "output JSON file")
	_ = fs.Parse(args)
	t, _, err := tree.Scan(*root, tree.ScanOptions{})
	if err != nil {
		return err
	}
	b, err := json.Marshal(t)
	if err != nil {
		return err
	}
	return os.WriteFile(*out, b, 0o644)
}

// cmdExecSteps performs scripted steps in the current directory: edit steps
// with direct file writes (standing in for an edit tool), shell steps with sh.
func cmdExecSteps(args []string) error {
	fs := flag.NewFlagSet("exec-steps", flag.ExitOnError)
	stepsFile := fs.String("steps", "", "steps JSON")
	_ = fs.Parse(args)
	b, err := os.ReadFile(*stepsFile)
	if err != nil {
		return err
	}
	var steps []core.Step
	if err := json.Unmarshal(b, &steps); err != nil {
		return err
	}
	for i, s := range steps {
		if err := execStep(s); err != nil {
			return fmt.Errorf("step %d: %w", i+1, err)
		}
	}
	return nil
}

func execStep(s core.Step) error {
	switch {
	case s.Tool == "edit" && s.Create:
		if err := os.MkdirAll(filepath.Dir(s.Path), 0o755); err != nil {
			return err
		}
		return os.WriteFile(s.Path, []byte(s.Content+"\n"), 0o644)
	case s.Tool == "edit":
		b, err := os.ReadFile(s.Path)
		if err != nil {
			return err
		}
		if !strings.Contains(string(b), s.Old) {
			return fmt.Errorf("%s: text %q not found", s.Path, s.Old)
		}
		fi, err := os.Stat(s.Path)
		if err != nil {
			return err
		}
		return os.WriteFile(s.Path, []byte(strings.Replace(string(b), s.Old, s.New, 1)), fi.Mode().Perm())
	default:
		cmd := exec.Command("sh", "-c", s.Command)
		cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
		return cmd.Run()
	}
}
