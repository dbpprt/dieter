package cli

import (
	"bytes"
	"strings"
	"testing"

	_ "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
)

// rpcCommand is an intentionally explicit contract: every native-app daemon
// RPC must have an equivalent, documented CLI entry point. Adding an RPC makes
// this test fail until the feature team wires and documents its CLI operation.
var rpcCommand = map[string]string{
	"GetKV": "kv get", "ListKV": "kv list", "PutKV": "kv put", "DeleteKV": "kv delete", "MoveKV": "kv move", "WatchKV": "kv watch",
	"GetPeerRecord": "peer show", "GetPeerChanges": "peer changes", "GetPeerStoreStatus": "peer status", "ListPeerRecords": "peer list", "PutPeerRecord": "peer put", "MergePeerRecords": "peer merge",
	"StartControlConnection": "machine connection start", "GetControlConnection": "machine connection show", "CloseControlConnection": "machine connection close",
	"GetRemoteDesktopVirtualDisplay":     "screen virtual status",
	"SetRemoteDesktopVirtualDisplay":     "screen virtual set",
	"ConfirmRemoteDesktopVirtualDisplay": "screen virtual presented",
	"RestoreRemoteDesktopVirtualDisplay": "screen virtual restore",
	"ListRemoteDesktopDisplayModes":      "screen resolution modes",
	"SetRemoteDesktopDisplayMode":        "screen resolution set",
	"RestoreRemoteDesktopDisplayMode":    "screen resolution restore",
	"ProbeRemoteDesktopPermissions":      "screen permissions",
	"PresentConversationContent":         "card present",
	"UpdateBoardHostnames":               "board hostnames",
	"Health":                             "status", "GetRuntimeStatus": "status", "GetMachineInformation": "machine info", "PerformMachineOperation": "machine restart",
	"GetState": "status", "WatchChanges": "watch changes", "GetHarnesses": "harness list",
	"ConsolidateProject": "project consolidate",
	"AttachCheckout":     "project attach", "DetachCheckout": "project detach", "ListCheckouts": "project checkouts",
	"GetSettings": "settings show", "GetSettingsOptions": "settings options", "UpdateSettings": "settings update",
	"GetPromptSettings": "prompt show", "UpdatePromptSettings": "prompt update", "SetProjectPromptTemplate": "prompt project", "SetBoardPromptTemplate": "prompt board", "PreviewPrompt": "prompt preview",
	"ListDirectories": "project directories", "CreateProject": "project open", "UpdateProject": "project update", "UpdateProjectWorkspaceSettings": "project workspace", "ArchiveProject": "project remove", "ListArchivedProjects": "project list",
	"GetBoard": "board show", "ListRetiredBoards": "board list", "SetBoardRetired": "board retire", "CreateBoard": "board create", "RenameBoard": "board rename", "SetBoardArchivePolicy": "board retention", "UpdateBoardGitSettings": "board git", "ListArchivedCards": "card list", "CreateBoardLabel": "board label add", "UpdateBoardLabel": "board label update", "DeleteBoardLabel": "board label remove",
	"CreateCard": "card create", "CreateChat": "chat create", "ForkChat": "card fork", "ListChats": "chat list", "GetCard": "card show", "GetConversation": "card transcript", "PollConversation": "card poll", "WatchConversation": "card watch", "GetToolOutput": "card tool-output", "SendMessage": "card send", "RemoveQueuedMessage": "card queue remove", "MarkConversationRead": "card read", "MoveCard": "card move", "MergeCard": "card merge", "StartCard": "card start", "SetCardLabels": "card labels", "CancelCard": "card cancel", "RenameCard": "card rename", "UpdateCard": "card update", "ArchiveCard": "card archive", "PinChat": "chat pin",
	"UpdateConversationWorkspace": "card workspace", "GetWorkspace": "workspace show", "ListProjectWorkspaces": "workspace list", "GetChangeset": "workspace changes", "GetFileDiff": "workspace diff", "GetCommitDiff": "workspace diff", "AddChangeComment": "workspace comment", "ListChangeComments": "workspace comments", "GetSCMCapabilities": "workspace scm", "StartGitOperation": "workspace run", "GetGitOperation": "workspace operation", "WatchGitOperation": "workspace watch", "CancelGitOperation": "workspace cancel",
	"ListFiles": "file list", "ReadFile": "file read", "SaveFile": "file save", "CreateFile": "file create", "MoveFile": "file move", "DeleteFile": "file delete",
	"ListTerminals": "terminal list", "CreateTerminal": "terminal create", "WatchTerminal": "terminal watch", "WriteTerminal": "terminal write", "ResizeTerminal": "terminal resize", "RenameTerminal": "terminal rename", "CloseTerminal": "terminal close",
	"ListExecutions": "remote list", "StartExecution": "remote exec", "GetExecution": "remote show", "WatchExecution": "remote watch", "WriteExecutionInput": "remote input", "SignalExecution": "remote signal", "ResizeExecution": "remote resize", "CancelExecution": "remote cancel", "CloseExecution": "remote close",
	"GetRemoteDesktopCapabilities": "screen capabilities", "StartRemoteDesktop": "screen start", "SendRemoteDesktopSignal": "screen signal", "CloseRemoteDesktop": "screen close", "ListRemoteDesktopSessions": "screen sessions",
	"SetRemoteDesktopControl":        "screen control",
	"ExchangeRemoteDesktopClipboard": "screen clipboard",
	"GetRemoteDesktopSession":        "screen status", "UpdateRemoteDesktopSession": "screen configure",
	"GetSchedule": "schedule show", "ListSchedules": "schedule list", "PreviewSchedule": "schedule preview", "CreateSchedule": "schedule create", "UpdateSchedule": "schedule update", "DeleteSchedule": "schedule delete", "RunSchedule": "schedule run", "SetScheduleEnabled": "schedule pause", "ListScheduleRuns": "schedule runs",
	"GetVaultStatus": "vault status", "InitVault": "vault init", "JoinVault": "vault join", "ApproveVaultMember": "vault approve", "RemoveVaultMember": "vault remove-member", "RotateVault": "vault rotate",
	"GetTrustStatus": "device status", "GetDeviceRoster": "device roster", "SyncDeviceRoster": "device sync", "InitializeDeviceRoster": "device init",
	"ListPairingRequests": "device requests", "ApproveDevice": "device approve", "RevokeDevice": "device revoke", "RecoverDeviceTrust": "device recover",
	"ListVaultItems": "vault list", "GetVaultItem": "vault show", "RevealVaultItem": "vault get", "CreateVaultItem": "vault add", "UpdateVaultItem": "vault edit", "DeleteVaultItem": "vault remove", "ListVaultAudit": "vault audit",
}

func TestEveryDaemonRPCMapsToCLICommand(t *testing.T) {
	t.Parallel()
	declared := map[string]bool{}
	protoregistry.GlobalFiles.RangeFilesByPackage("dieter.v1", func(file protoreflect.FileDescriptor) bool {
		for service := 0; service < file.Services().Len(); service++ {
			methods := file.Services().Get(service).Methods()
			for index := 0; index < methods.Len(); index++ {
				name := string(methods.Get(index).Name())
				declared[name] = true
				if strings.TrimSpace(rpcCommand[name]) == "" {
					t.Errorf("RPC %s has no CLI command mapping", name)
				}
			}
		}
		return true
	})
	if len(declared) == 0 {
		t.Fatal("no dieter.v1 services are registered")
	}
	for name, command := range rpcCommand {
		if !declared[name] {
			t.Errorf("CLI mapping %s -> %q refers to a removed RPC", name, command)
		}
	}
}

// Every documented command path comes from the command table that also
// dispatches commands and generates the reference, so a new subcommand is
// covered once it is declared there. "serve" and "daemon start" are daemon
// entry points; cmd/dieter routes them to internal/daemon, whose tests cover
// their help.
func TestEveryDaemonCLICommandHasOfflineHelp(t *testing.T) {
	t.Parallel()
	paths := commandPaths()
	if len(paths) < 200 {
		t.Fatalf("command table documents only %d paths", len(paths))
	}
	for _, path := range paths {
		t.Run(strings.ReplaceAll(path, " ", "/"), func(t *testing.T) {
			t.Parallel()
			var output bytes.Buffer
			client := New(t.TempDir())
			client.Out, client.Err = &output, &output
			args := append(strings.Fields(path), "--help")
			if err := client.Run(args); err != nil {
				t.Fatalf("dieter %s --help: %v", path, err)
			}
			if !strings.Contains(output.String(), "Usage:") {
				t.Fatalf("dieter %s --help did not print usage: %q", path, output.String())
			}
		})
	}
}

func TestCommandTableDispatchesNamesAndAliasesOnly(t *testing.T) {
	t.Parallel()
	seen := map[string]bool{}
	for _, command := range commandTable() {
		for _, name := range append([]string{command.name}, command.aliases...) {
			if seen[name] {
				t.Errorf("command name %q is declared twice", name)
			}
			seen[name] = true
		}
		if command.run == nil || command.summary == "" {
			t.Errorf("command %q lacks a handler or summary", command.name)
		}
	}
	err := New(t.TempDir()).Run([]string{"undeclared-command"})
	if err == nil || !strings.Contains(err.Error(), `unknown command "undeclared-command"`) {
		t.Fatalf("undeclared command: %v", err)
	}
	var output bytes.Buffer
	client := New(t.TempDir())
	client.Out = &output
	client.rootHelp()
	for _, command := range commandTable() {
		if !strings.Contains(output.String(), "\n  "+command.name+" ") {
			t.Errorf("root help omits %q", command.name)
		}
	}
}

func TestEveryRPCCommandIsDocumented(t *testing.T) {
	t.Parallel()
	documented := map[string]bool{}
	for _, path := range commandPaths() {
		documented[path] = true
	}
	for rpc, path := range rpcCommand {
		if !documented[path] {
			t.Errorf("RPC %s maps to %q, which the command table does not document", rpc, path)
		}
	}
}

func TestProjectCreationHelpKeepsPublishingInBoardSettings(t *testing.T) {
	t.Parallel()
	for _, command := range [][]string{{"project", "create"}, {"project", "open"}} {
		t.Run(strings.Join(command, "/"), func(t *testing.T) {
			client := New(t.TempDir())
			var output bytes.Buffer
			client.Out = &output
			if err := client.Run(append(command, "--help")); err != nil {
				t.Fatal(err)
			}
			if strings.Contains(output.String(), "--remote-publish") {
				t.Fatalf("project creation still advertises publishing: %q", output.String())
			}
		})
	}
	for _, command := range [][]string{{"board", "create"}, {"board", "git"}} {
		t.Run(strings.Join(command, "/"), func(t *testing.T) {
			client := New(t.TempDir())
			var output bytes.Buffer
			client.Out = &output
			if err := client.Run(append(command, "--help")); err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(output.String(), "--remote-publish") {
				t.Fatalf("board settings lost publishing: %q", output.String())
			}
		})
	}
}

func TestHostnameCommandsOfferHostnameFlags(t *testing.T) {
	t.Parallel()
	for _, command := range []struct {
		args  []string
		clear string
	}{
		{[]string{"project", "update"}, "--clear-hostnames"},
		{[]string{"board", "hostnames"}, "--clear"},
	} {
		t.Run(strings.Join(command.args, " "), func(t *testing.T) {
			c := New(t.TempDir())

			var output bytes.Buffer
			c.Out = &output
			if err := c.Run(append(command.args, "--help")); err != nil {
				t.Fatal(err)
			}
			for _, text := range []string{"--hostname", command.clear} {
				if !strings.Contains(output.String(), text) {
					t.Fatalf("missing %s in %s", text, output.String())
				}
			}
		})
	}
}

func TestReferenceCoversTheCommandTable(t *testing.T) {
	t.Parallel()
	var reference bytes.Buffer
	if err := WriteReference(&reference, "Usage: dieter daemon start [options]\n"); err != nil {
		t.Fatal(err)
	}
	text := reference.String()
	for _, path := range commandPaths() {
		level := "### "
		if !strings.Contains(path, " ") {
			level = "## "
		}
		if !strings.Contains(text, "\n"+level+"dieter "+path) {
			t.Errorf("reference omits dieter %s", path)
		}
	}
	if !strings.Contains(text, "### dieter daemon start\n\n```text\nUsage: dieter daemon start [options]\n```") {
		t.Error("reference omits the daemon entry point")
	}
}
