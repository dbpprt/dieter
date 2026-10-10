package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func runVaultCLIWithInput(t *testing.T, client *CLI, output *bytes.Buffer, input string, args ...string) string {
	t.Helper()
	client.In = strings.NewReader(input)
	defer func() { client.In = os.Stdin }()
	return runDaemonCLI(t, client, output, args...)
}

func TestVaultCLIManagesItemsAndConversationAccess(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	t.Setenv("DIETER_TURN_TOKEN", "")
	client, output, _ := daemonCLIForTest(t)

	if status := runDaemonCLI(t, client, output, "vault", "status"); !regexp.MustCompile(`State:\s+none`).MatchString(status) {
		t.Fatalf("initial status = %q", status)
	}
	initialized := runDaemonCLI(t, client, output, "vault", "init", "--name", "laptop")
	if !regexp.MustCompile(`DVR1-[0-9A-Z-]+`).MatchString(initialized) {
		t.Fatalf("init did not print a recovery key: %q", initialized)
	}

	const password = "pa ss-word with spaces"
	totpFile := filepath.Join(t.TempDir(), "totp")
	if err := os.WriteFile(totpFile, []byte("otpauth://totp/GitHub:octo?secret=JBSWY3DPEHPK3PXP&issuer=GitHub\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	created := runVaultCLIWithInput(t, client, output, password+"\n", "vault", "add", "--name", "GitHub", "--url", "https://github.com/login", "--username", "octo", "--password-file", "-", "--totp-file", totpFile)
	var item struct {
		ID          string `json:"id"`
		HasPassword bool   `json:"hasPassword"`
		HasTotp     bool   `json:"hasTotp"`
	}
	if err := json.Unmarshal([]byte(created), &item); err != nil || !item.HasPassword || !item.HasTotp || strings.Contains(created, password) {
		t.Fatalf("add = %q, %v", created, err)
	}
	generatedID := strings.TrimSpace(runDaemonCLI(t, client, output, "vault", "add", "--name", "AWS", "--generate", "--length", "32", "--format", "id"))
	if !strings.HasPrefix(generatedID, "vi_") {
		t.Fatalf("generated id = %q", generatedID)
	}

	if list := runDaemonCLI(t, client, output, "vault", "list"); !strings.Contains(list, "GitHub") || !strings.Contains(list, "password,totp") || strings.Contains(list, password) {
		t.Fatalf("list = %q", list)
	}
	if ids := runDaemonCLI(t, client, output, "vault", "list", "--url", "github.com", "--format", "ids"); strings.TrimSpace(ids) != item.ID {
		t.Fatalf("list by URL = %q", ids)
	}

	output.Reset()
	if err := client.Run([]string{"vault", "get", "github"}); err == nil || !strings.Contains(err.Error(), "--reveal") {
		t.Fatalf("get without --reveal = %v", err)
	}
	if value := runDaemonCLI(t, client, output, "vault", "get", "github", "--reveal"); value != password+"\n" {
		t.Fatalf("get password = %q", value)
	}
	if value := runDaemonCLI(t, client, output, "vault", "get", item.ID, "--field", "username"); value != "octo\n" {
		t.Fatalf("get username = %q", value)
	}
	if value := runDaemonCLI(t, client, output, "vault", "get", "AWS", "--reveal"); len(strings.TrimSpace(value)) != 32 {
		t.Fatalf("generated password = %q", value)
	}
	if code := runDaemonCLI(t, client, output, "vault", "totp", "GitHub", "--no-wait"); !regexp.MustCompile(`^\d{6}\n$`).MatchString(code) {
		t.Fatalf("totp = %q", code)
	}

	// exec injects fields without printing them and preserves exit status.
	if value := runDaemonCLI(t, client, output, "vault", "exec", "GitHub", "--env", "VAULT_PW=password", "--env", "VAULT_USER=username", "--", "/bin/sh", "-c", `test "$VAULT_PW" = "`+password+`" && printf '%s' "$VAULT_USER"`); value != "octo" {
		t.Fatalf("exec output = %q", value)
	}
	output.Reset()
	err := client.Run([]string{"vault", "exec", "GitHub", "--env", "PW=password", "--", "/bin/sh", "-c", "exit 7"})
	var exit *exitStatusError
	if !errors.As(err, &exit) || exit.code != 7 {
		t.Fatalf("exec exit = %v", err)
	}

	edited := runDaemonCLI(t, client, output, "vault", "edit", "GitHub", "--name", "GitHub Work", "--url", "https://github.com/enterprise", "--clear-totp")
	var editedItem struct {
		Name    string   `json:"name"`
		URLs    []string `json:"urls"`
		HasTOTP bool     `json:"hasTotp"`
	}
	if err := json.Unmarshal([]byte(edited), &editedItem); err != nil || editedItem.Name != "GitHub Work" || editedItem.HasTOTP || len(editedItem.URLs) != 2 {
		t.Fatalf("edit = %q, %v", edited, err)
	}
	if value := runDaemonCLI(t, client, output, "vault", "get", "GitHub Work", "--reveal"); value != password+"\n" {
		t.Fatalf("password changed by edit: %q", value)
	}
	runDaemonCLI(t, client, output, "vault", "remove", "AWS")
	if list := runDaemonCLI(t, client, output, "vault", "list", "--format", "ids"); strings.Contains(list, generatedID) {
		t.Fatalf("removed item listed: %q", list)
	}
	audit := runDaemonCLI(t, client, output, "vault", "audit", "--format", "jsonl")
	if strings.Contains(audit, password) || !strings.Contains(audit, `"action":"exec"`) || !strings.Contains(audit, `"action":"get"`) {
		t.Fatalf("audit = %q", audit)
	}

	// A stale or foreign turn token is rejected rather than treated as the operator.
	t.Setenv("DIETER_TURN_TOKEN", "dtt1:c_missing:turn_missing:forged")
	client.Close()
	output.Reset()
	if err := client.Run([]string{"vault", "list"}); err == nil || !strings.Contains(err.Error(), "turn token") {
		t.Fatalf("forged token = %v", err)
	}
	client.Machine = "elsewhere"
	if err := client.Run([]string{"vault", "list"}); err == nil || !strings.Contains(err.Error(), "own machine") {
		t.Fatalf("agent --machine = %v", err)
	}
}

func TestVaultCLIGrantsAccessAtCreation(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	client, output, data := daemonCLIForTest(t)
	repository := initTestRepository(t, "vault")
	var created struct {
		Project struct {
			ID string `json:"id"`
		} `json:"project"`
		Board struct {
			ID string `json:"id"`
		} `json:"board"`
	}
	if err := json.Unmarshal([]byte(runDaemonCLI(t, client, output, "project", "open", "--name", "Vault", "--format", "json", repository)), &created); err != nil {
		t.Fatal(err)
	}
	vaultAccess := func(raw string) bool {
		t.Helper()
		var value struct {
			VaultAccess bool `json:"vaultAccess"`
		}
		if err := json.Unmarshal([]byte(raw), &value); err != nil {
			t.Fatalf("decode %q: %v", raw, err)
		}
		return value.VaultAccess
	}
	if card := runDaemonCLI(t, client, output, "card", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--title", "Uses vault", "--workspace", "project", "--provider", "mock", "--model", "mock", "--vault"); !vaultAccess(card) {
		t.Fatalf("card = %q", card)
	}
	if plain := runDaemonCLI(t, client, output, "card", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--title", "No vault", "--workspace", "project", "--provider", "mock", "--model", "mock"); vaultAccess(plain) {
		t.Fatalf("card without --vault = %q", plain)
	}
	chat := runDaemonCLI(t, client, output, "chat", "create", "--project", created.Project.ID, "--title", "Vault chat", "--workspace", "project", "--provider", "mock", "--model", "mock", "--vault", "--format", "id")
	stored, err := data.ResolveCard(strings.TrimSpace(chat))
	if err != nil || !stored.VaultAccess {
		t.Fatalf("chat = %q %+v %v", chat, stored, err)
	}
	// Chats start immediately; let the mock turn finish before cleanup.
	for deadline := time.Now().Add(10 * time.Second); stored.Runtime != "idle" && time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		stored, _ = data.ResolveCard(stored.ID)
	}
	if _, err := data.GlobalStateContext(t.Context()); err != nil {
		t.Fatal(err)
	}
	schedule := runDaemonCLI(t, client, output, "schedule", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--name", "Nightly login", "--cron", "0 3 * * *", "--title", "Login", "--prompt", "Check login", "--provider", "mock", "--model", "mock", "--vault")
	var value struct {
		ID          string `json:"id"`
		VaultAccess bool   `json:"vaultAccess"`
	}
	if err := json.Unmarshal([]byte(schedule), &value); err != nil || !value.VaultAccess {
		t.Fatalf("schedule = %q, %v", schedule, err)
	}
	if updated := runDaemonCLI(t, client, output, "schedule", "update", "--name", "Nightly check", value.ID); !vaultAccess(updated) {
		t.Fatalf("update dropped vault access: %q", updated)
	}
	if revoked := runDaemonCLI(t, client, output, "schedule", "update", "--vault=false", value.ID); vaultAccess(revoked) {
		t.Fatalf("update could not revoke vault access: %q", revoked)
	}
}

// assertVaultDirectCLI runs on a machine reached over verified direct TLS.
func assertVaultDirectCLI(t *testing.T, client *CLI, output *bytes.Buffer) {
	t.Helper()
	runDaemonCLI(t, client, output, "vault", "init", "--name", "remote")
	runVaultCLIWithInput(t, client, output, "remote-secret\n", "vault", "add", "--name", "Remote", "--password-file", "-")
	if value := runDaemonCLI(t, client, output, "vault", "get", "Remote", "--reveal"); value != "remote-secret\n" {
		t.Fatalf("direct vault get = %q", value)
	}
}

// assertVaultRelayRefusedCLI runs on the gateway relay route, where the
// gateway sees payloads: status works, decrypted content is refused.
func assertVaultRelayRefusedCLI(t *testing.T, client *CLI, output *bytes.Buffer) {
	t.Helper()
	if status := runDaemonCLI(t, client, output, "vault", "status"); !strings.Contains(status, "unlocked") || !strings.Contains(status, "via relay") {
		t.Fatalf("relay vault status = %q", status)
	}
	output.Reset()
	if err := client.Run([]string{"vault", "get", "Remote", "--reveal"}); err == nil || !strings.Contains(err.Error(), "gateway relay") {
		t.Fatalf("relay vault get = %v %q", err, output.String())
	}
}
