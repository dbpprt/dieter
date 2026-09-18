package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type doctorCheck struct {
	Name     string `json:"name"`
	Status   string `json:"status"`
	Required bool   `json:"required"`
	Detail   string `json:"detail"`
}

func (c *CLI) doctor(args []string) error {
	const usage = `Usage: dieter doctor [--format table|json]

Check the local daemon's runtime, storage, service-manager, shell, and optional
durability dependencies. Doctor is read-only apart from normal DIETER_HOME
permission migration performed by every local CLI invocation.
`
	set := flags("doctor")
	format := set.String("format", "table", "table or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || (*format != "table" && *format != "json") {
		return errors.New(usage)
	}
	checks := []doctorCheck{
		commandDoctorCheck("git", true, "--version", nil),
		commandDoctorCheck("node", true, "--version", nodeVersionSupported),
		commandDoctorCheck("npm", true, "--version", nil),
		commandDoctorCheck("tmux", false, "-V", nil),
		commandDoctorCheck("xdg-open", false, "--help", nil),
	}
	if runtime.GOOS == "darwin" {
		checks[4] = commandDoctorCheck("open", false, "--help", nil)
	}
	rootInfo, statErr := os.Stat(c.Store.Root)
	storage := doctorCheck{Name: "storage", Required: true, Status: "ok", Detail: c.Store.Root + " is private"}
	if statErr != nil {
		storage.Status, storage.Detail = "failed", statErr.Error()
	} else if rootInfo.Mode().Perm() != 0o700 {
		storage.Status, storage.Detail = "failed", fmt.Sprintf("mode is %04o; expected 0700", rootInfo.Mode().Perm())
	}
	checks = append(checks, storage)
	shell := strings.TrimSpace(os.Getenv("SHELL"))
	if shell != "" {
		if resolved, lookErr := exec.LookPath(shell); lookErr == nil {
			shell = resolved
		} else {
			shell = ""
		}
	}
	if shell == "" {
		for _, candidate := range []string{"zsh", "bash", "sh"} {
			if path, lookErr := exec.LookPath(candidate); lookErr == nil {
				shell = path
				break
			}
		}
	}
	shellCheck := doctorCheck{Name: "shell", Required: true, Status: "ok", Detail: shell}
	if shell == "" {
		shellCheck.Status, shellCheck.Detail = "failed", "no supported zsh, bash, or sh executable found"
	}
	checks = append(checks, shellCheck)
	checks = append(checks, platformDoctorChecks()...)
	executable, executableErr := os.Executable()
	pathCheck := doctorCheck{Name: "service-path", Required: true, Status: "ok"}
	if executableErr != nil {
		pathCheck.Status, pathCheck.Detail = "failed", executableErr.Error()
	} else {
		executable, _ = filepath.Abs(executable)
		pathCheck.Detail = executable
	}
	checks = append(checks, pathCheck)

	failed := false
	for _, check := range checks {
		failed = failed || check.Required && check.Status != "ok"
	}
	if *format == "json" {
		if err := json.NewEncoder(c.Out).Encode(struct {
			OK     bool          `json:"ok"`
			Checks []doctorCheck `json:"checks"`
		}{OK: !failed, Checks: checks}); err != nil {
			return err
		}
	} else {
		for _, check := range checks {
			marker := "OK"
			if check.Status == "warning" {
				marker = "WARN"
			} else if check.Status != "ok" {
				marker = "FAIL"
			}
			fmt.Fprintf(c.Out, "%-4s %-22s %s\n", marker, check.Name, check.Detail)
		}
	}
	if failed {
		return errors.New("required local prerequisites are unavailable")
	}
	return nil
}

func commandDoctorCheck(name string, required bool, argument string, validate func(string) error) doctorCheck {
	check := doctorCheck{Name: name, Required: required, Status: "ok"}
	path, err := exec.LookPath(name)
	if err != nil {
		check.Status, check.Detail = "missing", "not found in PATH"
		if !required {
			check.Status = "warning"
		}
		return check
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	raw, runErr := exec.CommandContext(ctx, path, argument).CombinedOutput()
	value := strings.TrimSpace(string(raw))
	if runErr != nil && value == "" {
		check.Status, check.Detail = "failed", runErr.Error()
		if !required {
			check.Status = "warning"
		}
		return check
	}
	if validate != nil {
		if err := validate(value); err != nil {
			check.Status, check.Detail = "failed", err.Error()
			return check
		}
	}
	check.Detail = path
	if value != "" {
		if line, _, _ := strings.Cut(value, "\n"); line != "" {
			check.Detail += " (" + line + ")"
		}
	}
	return check
}

func nodeVersionSupported(raw string) error {
	value := strings.TrimPrefix(strings.TrimSpace(raw), "v")
	parts := strings.Split(value, ".")
	if len(parts) < 2 {
		return fmt.Errorf("could not parse Node.js version %q", raw)
	}
	major, majorErr := strconv.Atoi(parts[0])
	minor, minorErr := strconv.Atoi(parts[1])
	if majorErr != nil || minorErr != nil {
		return fmt.Errorf("could not parse Node.js version %q", raw)
	}
	if major < 22 || major == 22 && minor < 19 {
		return fmt.Errorf("Node.js %s is unsupported; install 22.19 or newer", value)
	}
	return nil
}
