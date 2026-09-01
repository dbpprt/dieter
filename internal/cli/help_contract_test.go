package cli

import (
	"bytes"
	"strings"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
)

// rpcCommand is an intentionally explicit contract: every native-app daemon
// RPC must have an equivalent, documented CLI entry point. Adding an RPC makes
// this test fail until the feature team wires and documents its CLI operation.
var rpcCommand = map[string]string{
	"Health": "status", "GetRuntimeStatus": "status", "GetMachineInformation": "machine info", "PerformMachineOperation": "machine restart",
	"GetState": "status", "WatchState": "watch state", "WatchSync": "watch sync", "GetHarnesses": "harness list",
	"GetSettings": "settings show", "GetSettingsOptions": "settings options", "UpdateSettings": "settings update",
	"GetPromptSettings": "prompt show", "UpdatePromptSettings": "prompt update", "SetProjectPromptTemplate": "prompt project", "SetBoardPromptTemplate": "prompt board", "PreviewPrompt": "prompt preview",
	"ListDirectories": "project directories", "CreateProject": "project open", "UpdateProject": "project update", "UpdateProjectWorkspaceSettings": "project workspace", "ArchiveProject": "project remove", "ListArchivedProjects": "project list",
	"CreateBoard": "board create", "RenameBoard": "board rename", "SetBoardArchivePolicy": "board retention", "ListArchivedCards": "card list", "CreateBoardLabel": "board label add", "UpdateBoardLabel": "board label update", "DeleteBoardLabel": "board label remove",
	"CreateCard": "card create", "CreateChat": "chat create", "ForkChat": "card fork", "ListChats": "chat list", "GetCard": "card show", "GetConversation": "card transcript", "PollConversation": "card poll", "WatchConversation": "card watch", "GetToolOutput": "card tool-output", "SendMessage": "card send", "AddComment": "card comment", "MoveCard": "card move", "StartCard": "card start", "SetCardLabels": "card labels", "CancelCard": "card cancel", "RenameCard": "card rename", "UpdateCard": "card update", "ArchiveCard": "card archive", "PinChat": "chat pin",
	"UpdateConversationWorkspace": "card workspace", "GetWorkspace": "workspace show", "ListProjectWorkspaces": "workspace list", "GetChangeset": "workspace changes", "GetFileDiff": "workspace diff", "GetCommitDiff": "workspace diff", "AddChangeComment": "workspace comment", "ListChangeComments": "workspace comments", "GetSCMCapabilities": "workspace scm", "StartGitOperation": "workspace run", "GetGitOperation": "workspace operation", "WatchGitOperation": "workspace watch", "CancelGitOperation": "workspace cancel",
	"ListFiles": "file list", "ReadFile": "file read", "SaveFile": "file save", "CreateFile": "file create", "MoveFile": "file move", "DeleteFile": "file delete",
	"ListTerminals": "terminal list", "CreateTerminal": "terminal create", "WatchTerminal": "terminal watch", "WriteTerminal": "terminal write", "ResizeTerminal": "terminal resize", "RenameTerminal": "terminal rename", "CloseTerminal": "terminal close",
	"ListExecutions": "remote list", "StartExecution": "remote exec", "GetExecution": "remote show", "WatchExecution": "remote watch", "WriteExecutionInput": "remote input", "SignalExecution": "remote signal", "ResizeExecution": "remote resize", "CancelExecution": "remote cancel", "CloseExecution": "remote close",
	"GetRemoteDesktopCapabilities": "screen capabilities", "GetRemoteDesktopSettings": "screen settings", "UpdateRemoteDesktopSettings": "screen update", "StartRemoteDesktop": "screen start", "SendRemoteDesktopSignal": "screen signal", "CloseRemoteDesktop": "screen close",
	"ListSchedules": "schedule list", "PreviewSchedule": "schedule preview", "CreateSchedule": "schedule create", "UpdateSchedule": "schedule update", "DeleteSchedule": "schedule delete", "RunSchedule": "schedule run", "SetScheduleEnabled": "schedule pause", "ListScheduleRuns": "schedule runs",
}

func TestEveryDaemonRPCMapsToCLICommand(t *testing.T) {
	service := dieterv1.File_dieter_v1_dieter_proto.Services().ByName("DieterService")
	if service == nil {
		t.Fatal("DieterService descriptor is missing")
	}
	declared := map[string]bool{}
	for index := 0; index < service.Methods().Len(); index++ {
		name := string(service.Methods().Get(index).Name())
		declared[name] = true
		if strings.TrimSpace(rpcCommand[name]) == "" {
			t.Errorf("RPC %s has no CLI command mapping", name)
		}
	}
	for name, command := range rpcCommand {
		if !declared[name] {
			t.Errorf("CLI mapping %s -> %q refers to a removed RPC", name, command)
		}
	}
}

func TestEveryDaemonCLICommandHasOfflineHelp(t *testing.T) {
	paths := []string{
		"auth", "auth login", "auth status", "auth logout",
		"machine", "machine list", "machine watch", "machine show", "machine route", "machine info", "machine rename", "machine revoke", "machine restart", "machine shutdown", "machine rtc",
		"status", "storage", "harness", "harness list", "watch", "watch state", "watch sync",
		"project", "project create", "project open", "project directories", "project list", "project show", "project update", "project workspace", "project remove", "project restore",
		"board", "board create", "board list", "board show", "board rename", "board retention", "board label", "board label add", "board label list", "board label update", "board label remove",
		"card", "card create", "card list", "card show", "card context", "card transcript", "card poll", "card watch", "card tool-output", "card fork", "card send", "card comment", "card move", "card start", "card labels", "card cancel", "card rename", "card update", "card archive", "card unarchive", "card workspace",
		"chat", "chat create", "chat list", "chat show", "chat context", "chat transcript", "chat poll", "chat watch", "chat tool-output", "chat fork", "chat send", "chat comment", "chat start", "chat labels", "chat cancel", "chat rename", "chat update", "chat archive", "chat unarchive", "chat workspace", "chat pin", "chat unpin",
		"workspace", "workspace show", "workspace list", "workspace changes", "workspace diff", "workspace comments", "workspace comment", "workspace scm", "workspace operation", "workspace watch", "workspace run", "workspace cancel",
		"file", "file list", "file read", "file save", "file create", "file move", "file delete",
		"terminal", "terminal list", "terminal create", "terminal attach", "terminal watch", "terminal write", "terminal resize", "terminal rename", "terminal close",
		"remote", "remote exec", "remote shell", "remote list", "remote show", "remote watch", "remote wait", "remote attach", "remote input", "remote signal", "remote resize", "remote cancel", "remote close",
		"screen", "screen capabilities", "screen settings", "screen update", "screen start", "screen signal", "screen close",
		"schedule", "schedule create", "schedule list", "schedule show", "schedule preview", "schedule update", "schedule run", "schedule pause", "schedule resume", "schedule runs", "schedule delete",
		"settings", "settings show", "settings options", "settings update",
		"prompt", "prompt show", "prompt update", "prompt project", "prompt board", "prompt preview",
		"daemon", "daemon start", "daemon enroll", "daemon unenroll", "daemon status", "daemon logs", "daemon permissions", "setup", "serve",
	}
	for _, path := range paths {
		t.Run(strings.ReplaceAll(path, " ", "/"), func(t *testing.T) {
			var output bytes.Buffer
			client := New(store.New(t.TempDir()))
			client.DaemonMode = true
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
