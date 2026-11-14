package config

import (
	"slices"
	"testing"
)

func TestEnvAccessors(t *testing.T) {
	t.Parallel()
	env := EnvFrom([]string{"A=first", "A= later ", "EMPTY=", "=ignored", "NOEQUALS", "LIST= a, ,b ,", "ONE=1", "TRUE=true", "ZERO=0", "N=42", "BAD=-1"})
	if env.Value("A") != "later" || env["A"] != " later " {
		t.Fatalf("later entries win and Value trims: %q", env["A"])
	}
	if _, ok := env[""]; ok {
		t.Fatal("kept an entry without a name")
	}
	if _, ok := env["NOEQUALS"]; ok {
		t.Fatal("kept an entry without a value separator")
	}
	if !env.Enabled("ONE") || env.Enabled("TRUE") || env.Enabled("MISSING") {
		t.Fatal(`Enabled accepts exactly "1"`)
	}
	if !env.NotDisabled("MISSING") || !env.NotDisabled("ONE") || env.NotDisabled("ZERO") {
		t.Fatal(`NotDisabled rejects exactly "0"`)
	}
	if got := env.Fields("LIST"); !slices.Equal(got, []string{"a", "b"}) {
		t.Fatalf("Fields=%q", got)
	}
	if got := env.Fields("MISSING"); len(got) != 0 {
		t.Fatalf("missing Fields=%q", got)
	}
	if value := env.Uint("N"); value == nil || *value != 42 {
		t.Fatalf("Uint=%v", value)
	}
	if env.Uint("BAD") != nil || env.Uint("MISSING") != nil || env.Uint("EMPTY") != nil {
		t.Fatal("Uint accepted an invalid or unset value")
	}
	if list := env.List(); !slices.IsSorted(list) || !slices.Contains(list, "A= later ") {
		t.Fatalf("List=%q", list)
	}
}

func TestLoadDaemonParsesEveryVariable(t *testing.T) {
	t.Parallel()
	env := Env{
		"DIETER_HARNESS_CONFIG": " /etc/harnesses.yaml ", "DIETER_SERVICE_MANAGER": "systemd-user", "NOTIFY_SOCKET": "@notify",
		"DIETER_ENABLE_MOCK_HARNESS": "1", "DIETER_MIN_FREE_BYTES": "1024", "DIETER_HARNESS_RUNTIME_DIR": "/runtime",
		"DIETER_HARNESS_ENV": "GH_TOKEN, NPM_TOKEN", "CODEX_HOME": "/codex", "CLAUDE_CONFIG_DIR": "/claude",
		"DIETER_CODEX_ACCOUNT_HOMES": "/a:/b", "DIETER_CLAUDE_ACCOUNT_HOMES": "/c", "SHELL": "/bin/zsh",
		"DIETER_REMOTE_DESKTOP_SOURCE": "synthetic", "DIETER_REMOTE_DESKTOP_HELPER": "/helper", "DIETER_REMOTE_DESKTOP_DISPLAY": "2",
		"DIETER_SCREEN_FEC": "0", "DIETER_SCREEN_FAST_BITRATE": "0", "DIETER_SCREEN_LTR": "0",
		"DIETER_SCREEN_CONTENT_ADAPTATION": "1", "DIETER_SCREEN_OVERLAP": "1", "DIETER_SCREEN_VIRTUAL_DISPLAY": "1", "DIETER_SCREEN_VIRTUAL_DISABLE": "1",
	}
	daemon := LoadDaemon(env)
	if daemon.HarnessConfig != "/etc/harnesses.yaml" || daemon.ServiceManager != "systemd-user" || daemon.NotifySocket != "@notify" ||
		!daemon.MockHarness || daemon.MinimumFreeBytes == nil || *daemon.MinimumFreeBytes != 1024 || daemon.HarnessRuntimeDir != "/runtime" ||
		!slices.Equal(daemon.HarnessEnv, []string{"GH_TOKEN", "NPM_TOKEN"}) || daemon.CodexHome != "/codex" || daemon.ClaudeConfigDir != "/claude" ||
		daemon.CodexAccountHomes != "/a:/b" || daemon.ClaudeAccountHomes != "/c" || daemon.Shell != "/bin/zsh" {
		t.Fatalf("daemon=%+v", daemon)
	}
	want := RemoteDesktop{Source: "synthetic", Helper: "/helper", Display: "2", DisableFEC: true, DisableFastBitrate: true, DisableLongTermReferences: true, ContentAdaptation: true, FrameOverlap: true, VirtualDisplay: true, VirtualDisable: true}
	if daemon.RemoteDesktop != want {
		t.Fatalf("remote desktop=%+v", daemon.RemoteDesktop)
	}
	defaults := LoadDaemon(Env{})
	if defaults.MockHarness || defaults.MinimumFreeBytes != nil || defaults.RemoteDesktop != (RemoteDesktop{}) {
		t.Fatalf("unset environment changed defaults: %+v", defaults)
	}
}

func TestLoadClientAndServiceHandoff(t *testing.T) {
	t.Parallel()
	env := Env{"DIETER_GATEWAY": " https://gateway.example ", "DIETER_TURN_TOKEN": "turn", "DIETER_REMOTE_DESKTOP_HELPER": "/helper", "SHELL": "/bin/sh",
		ServiceLockFDVar: "3", ServiceActivationVar: "activation"}
	client := LoadClient(env)
	if client.Gateway != "https://gateway.example" || client.TurnToken != "turn" || client.RemoteDesktopHelper != "/helper" || client.Shell != "/bin/sh" || client.Environment["SHELL"] != "/bin/sh" {
		t.Fatalf("client=%+v", client)
	}
	if handoff := LoadServiceHandoff(env); handoff.LockFD != "3" || handoff.Activation != "activation" {
		t.Fatalf("handoff=%+v", handoff)
	}
}
