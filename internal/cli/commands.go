package cli

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
)

// command is one entry of the CLI command table: the top-level name and
// aliases that dispatch to it, its root-help summary, and every subcommand
// path it documents. Each documented path prints usage for --help without a
// daemon. The table drives dispatch, the root help command list, the offline
// help contract test, and the generated Markdown reference (tools/clidocs).
type command struct {
	name        string
	aliases     []string
	summary     string
	run         func(*CLI, []string) error
	subcommands []string
	// entryPoint commands run the daemon; cmd/dieter routes them to
	// internal/daemon before the CLI sees them.
	entryPoint bool
	// noOptions commands take no options and print no usage.
	noOptions bool
}

func (c command) matches(name string) bool {
	return name == c.name || slices.Contains(c.aliases, name)
}

// commandTable lists every top-level command in root help order.
func commandTable() []command {
	return []command{
		{
			name:        "machine",
			aliases:     []string{"machines"},
			summary:     "List, route, rename, revoke, inspect, control, or privately lock machines",
			run:         (*CLI).machineCommand,
			subcommands: []string{"list", "gateway", "watch", "show", "route", "info", "rename", "revoke", "restart", "shutdown", "update", "rtc", "connection", "connection start", "connection show", "connection close", "privacy", "privacy status", "privacy setup", "privacy on", "privacy off"},
		},
		{
			name:    "status",
			summary: "Show target daemon health, runtime, route, and state counts",
			run:     (*CLI).daemonBackedStatus,
		},
		{
			name:        "harness",
			aliases:     []string{"harnesses"},
			summary:     "List target daemon harnesses, models, and options",
			run:         (*CLI).harnessCommand,
			subcommands: []string{"list"},
		},
		{
			name:        "quota",
			aliases:     []string{"quotas"},
			summary:     "Show, summarize, refresh, and reset provider-account quotas",
			run:         (*CLI).quotaCommand,
			subcommands: []string{"list", "watch", "refresh", "include", "exclude", "reset"},
		},
		{
			name:        "project",
			aliases:     []string{"projects"},
			summary:     "Create, browse, map hostnames, relocate, archive, and restore projects",
			run:         (*CLI).rpcProject,
			subcommands: []string{"create", "open", "directories", "list", "show", "update", "workspace", "remove", "restore", "consolidate", "attach", "detach", "checkouts"},
		},
		{
			name:        "board",
			aliases:     []string{"boards"},
			summary:     "Manage boards, retirement/restore, hostnames, workflows, and labels",
			run:         (*CLI).rpcBoard,
			subcommands: []string{"retire", "restore", "hostnames", "create", "list", "show", "rename", "retention", "git", "label", "label add", "label list", "label update", "label remove"},
		},
		{
			name:        "card",
			aliases:     []string{"cards"},
			summary:     "Create, edit, read, present files, merge, and manage board conversations",
			run:         func(c *CLI, args []string) error { return c.rpcCard(args, false) },
			subcommands: []string{"present", "create", "list", "show", "context", "transcript", "poll", "watch", "tool-output", "fork", "send", "queue", "queue remove", "read", "merge", "move", "start", "labels", "cancel", "rename", "update", "archive", "unarchive", "workspace"},
		},
		{
			name:        "chat",
			aliases:     []string{"chats"},
			summary:     "Manage standalone conversations and present files or URLs",
			run:         func(c *CLI, args []string) error { return c.rpcCard(args, true) },
			subcommands: []string{"present", "create", "list", "show", "context", "transcript", "poll", "watch", "tool-output", "fork", "send", "queue", "queue remove", "read", "start", "labels", "cancel", "rename", "update", "archive", "unarchive", "workspace", "pin", "unpin"},
		},
		{
			name:        "workspace",
			aliases:     []string{"workspaces", "git"},
			summary:     "Inspect changes and run durable Git/SCM operations",
			run:         (*CLI).rpcWorkspace,
			subcommands: []string{"show", "list", "changes", "diff", "comments", "comment", "scm", "operation", "watch", "run", "cancel"},
		},
		{
			name:        "file",
			aliases:     []string{"files"},
			summary:     "Browse, edit, copy and sync project/workspace files",
			run:         (*CLI).rpcFile,
			subcommands: []string{"list", "read", "save", "create", "move", "delete", "cp", "sync", "stat", "scan", "upload"},
		},
		{
			name:        "terminal",
			aliases:     []string{"terminals"},
			summary:     "Create, attach, control, and close daemon-host PTYs",
			run:         (*CLI).rpcTerminal,
			subcommands: []string{"list", "create", "attach", "watch", "write", "resize", "rename", "close"},
		},
		{
			name:        "remote",
			summary:     "Run resumable commands and native shells on a daemon host",
			run:         (*CLI).rpcRemote,
			subcommands: []string{"exec", "shell", "list", "show", "watch", "wait", "attach", "input", "signal", "resize", "cancel", "close"},
		},
		{
			name:        "screen",
			aliases:     []string{"screens"},
			summary:     "Share screens/clipboard, configure virtual displays, inspect latency",
			run:         (*CLI).rpcScreen,
			subcommands: []string{"virtual", "virtual status", "virtual set", "virtual presented", "virtual restore", "resolution", "resolution modes", "resolution set", "resolution restore", "clipboard", "clipboard read", "clipboard write", "clipboard paste", "clipboard copy", "clipboard cut", "clipboard enable", "clipboard disable", "sessions", "control", "control take", "control release", "capabilities", "permissions", "start", "signal", "close", "status", "configure", "refresh"},
		},
		{
			name:        "schedule",
			aliases:     []string{"schedules"},
			summary:     "Create, preview, dispatch, pause, and inspect schedules",
			run:         (*CLI).rpcSchedule,
			subcommands: []string{"create", "list", "show", "preview", "update", "run", "pause", "resume", "runs", "delete"},
		},
		{
			name:        "kv",
			summary:     "Shared portable JSON, ordering, and live account subscriptions",
			run:         (*CLI).rpcKV,
			subcommands: []string{"get", "list", "put", "delete", "move", "watch"},
		},
		{
			name:        "vault",
			summary:     "End-to-end encrypted passwords and TOTP shared by your machines",
			run:         (*CLI).rpcVault,
			subcommands: []string{"status", "members", "init", "join", "approve", "remove-member", "rotate", "list", "show", "add", "edit", "remove", "get", "totp", "exec", "audit"},
		},
		{
			name:        "device",
			aliases:     []string{"devices"},
			summary:     "Pair, approve, revoke, and inspect the account's trusted devices",
			run:         (*CLI).rpcDevice,
			subcommands: []string{"status", "roster", "sync", "init", "requests", "approve", "revoke", "recover"},
		},
		{
			name:        "peer",
			summary:     "Inspect and edit account peer settings (leaderless sync)",
			run:         (*CLI).rpcPeer,
			subcommands: []string{"show", "changes", "status", "list", "put", "delete", "merge"},
		},
		{
			name:        "settings",
			summary:     "Inspect and update prompt and daemon settings",
			run:         (*CLI).rpcSettings,
			subcommands: []string{"show", "options", "update"},
		},
		{
			name:        "prompt",
			aliases:     []string{"prompts"},
			summary:     "Inspect, update, scope, and preview prompt templates",
			run:         (*CLI).rpcPrompt,
			subcommands: []string{"show", "update", "project", "board", "preview"},
		},
		{
			name:        "watch",
			summary:     "Stream this machine's change frames as JSON Lines",
			run:         (*CLI).rpcWatch,
			subcommands: []string{"changes"},
		},
		{
			name:    "storage",
			summary: "Print the target daemon's central storage path",
			run:     (*CLI).daemonBackedStorage,
		},
		{
			name:    "doctor",
			summary: "Check local Linux/macOS runtime and service prerequisites",
			run:     (*CLI).doctor,
		},
		{
			name:    "setup",
			summary: "Authorize, enroll, and install the daemon and macOS privacy helper",
			run:     (*CLI).setup,
		},
		{
			name:        "daemon",
			summary:     "Start, enroll, recover, inspect, or manage this local daemon service",
			run:         (*CLI).daemon,
			subcommands: []string{"service", "service install", "service start", "service restart", "service stop", "service status", "service uninstall", "enroll", "unenroll", "recover", "status", "logs", "permissions"},
		},
		{
			name:       "serve",
			summary:    "Alias for \"dieter daemon start\"",
			run:        func(*CLI, []string) error { return errDaemonEntryPoint },
			entryPoint: true,
		},
		{
			name:    "version",
			summary: "Print the version",
			run: func(c *CLI, _ []string) error {
				_, err := fmt.Fprintln(c.Out, Version)
				return err
			},
			noOptions: true,
		},
	}
}

// commandPaths returns every documented command path that prints offline
// help: each command with options and each of its subcommands.
func commandPaths() []string {
	var paths []string
	for _, command := range commandTable() {
		if command.entryPoint || command.noOptions {
			continue
		}
		paths = append(paths, command.name)
		for _, subcommand := range command.subcommands {
			paths = append(paths, command.name+" "+subcommand)
		}
	}
	return paths
}

// WriteReference writes a Markdown reference of the CLI generated from the
// command table: the root help, then each command's and subcommand's offline
// help. entryPointUsage documents the daemon entry points (serve and daemon
// start), whose help internal/daemon owns. Help never contacts a daemon.
func WriteReference(w io.Writer, entryPointUsage string) error {
	root, err := os.MkdirTemp("", "dieter-clidocs-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	help := func(args ...string) (string, error) {
		var output bytes.Buffer
		client := New(root)
		client.Out, client.Err = &output, &output
		defer client.Close()
		if len(args) == 0 {
			client.rootHelp()
		} else if err := client.Run(append(args, "--help")); err != nil {
			return "", fmt.Errorf("dieter %s --help: %w", strings.Join(args, " "), err)
		}
		return strings.TrimRight(output.String(), "\n"), nil
	}
	block := func(heading, text string) {
		fmt.Fprintf(w, "%s\n\n```text\n%s\n```\n\n", heading, text)
	}
	fmt.Fprint(w, "# Dieter CLI reference\n\nGenerated from the CLI command table by `go run ./tools/clidocs`. Every\nsection is the command's offline `--help` output.\n\n")
	text, err := help()
	if err != nil {
		return err
	}
	block("## dieter", text)
	for _, command := range commandTable() {
		heading := "## dieter " + command.name
		if len(command.aliases) > 0 {
			heading += " (alias: " + strings.Join(command.aliases, ", ") + ")"
		}
		switch {
		case command.entryPoint:
			fmt.Fprintf(w, "%s\n\n%s.\n\n", heading, command.summary)
			block("### dieter daemon start", strings.TrimRight(entryPointUsage, "\n"))
			continue
		case command.noOptions:
			fmt.Fprintf(w, "%s\n\n%s.\n\n", heading, command.summary)
			continue
		}
		if text, err = help(command.name); err != nil {
			return err
		}
		block(heading, text)
		for _, subcommand := range command.subcommands {
			if text, err = help(append([]string{command.name}, strings.Fields(subcommand)...)...); err != nil {
				return err
			}
			block("### dieter "+command.name+" "+subcommand, text)
		}
	}
	return nil
}
