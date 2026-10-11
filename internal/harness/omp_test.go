package harness

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAwaitingOMPInput(t *testing.T) {
	valid := json.RawMessage(`{"harnessId":"omp","data":{"ompRPC":{"version":1,"sessionFile":"session.jsonl","promptId":"prompt","pendingDialog":{"id":"dialog","method":"select"}}}}`)
	if !AwaitingOMPInput(valid) {
		t.Fatal("native dialog should retain its provider bridge")
	}
	for _, state := range []json.RawMessage{nil, []byte(`{"harnessId":"claude-code"}`), []byte(strings.ReplaceAll(string(valid), `"version":1`, `"version":2`)), []byte(strings.ReplaceAll(string(valid), `"select"`, `"notify"`))} {
		if AwaitingOMPInput(state) {
			t.Fatalf("invalid native dialog retained a provider bridge: %s", state)
		}
	}
}

func TestLegacyOMPContinuationKeepsDispatchedACPTransport(t *testing.T) {
	if !legacyOMPContinuation(json.RawMessage(`{"continueFrom":{"data":{"acpSessionId":"existing"}}}`)) {
		t.Fatal("a dispatched ACP turn must retain its transport")
	}
	if legacyOMPContinuation(json.RawMessage(`{"data":{"acpSessionId":"completed"}}`)) || legacyOMPContinuation(json.RawMessage(`{"continueFrom":{"data":{"ompRPC":{"version":1}}}}`)) {
		t.Fatal("completed or native sessions must use native RPC")
	}
}

// This gate runs the actual Go worker, pinned Bun/OMP, native RPC, discovered
// extension and MCP, and GLM inference in private Dieter/session roots. It does
// not install over or restart a running daemon, or edit user OMP configuration.
func TestSubprocessRunnerOMPNativeRPC(t *testing.T) {
	if os.Getenv("DIETER_TEST_OMP_RPC_E2E") != "1" {
		t.Skip("set DIETER_TEST_OMP_RPC_E2E=1 for real native OMP RPC/GLM integration")
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", "")
	fixtureDir := filepath.Join(cwd, "../../tools/fixtures/omp-rpc")
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	plugin := filepath.Join(base, "plugin")
	for _, dir := range []string{filepath.Join(repo, ".omp"), plugin} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	extension, err := os.ReadFile(filepath.Join(fixtureDir, "extension.ts"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(plugin, "index.ts"), extension, 0o600); err != nil {
		t.Fatal(err)
	}
	config := fmt.Sprintf("extensions:\n  - %q\n", plugin)
	if err := os.WriteFile(filepath.Join(repo, ".omp/config.yml"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	challenge := fmt.Sprintf("OMP_MCP_%d", time.Now().UnixNano())
	mcpLog := filepath.Join(base, "mcp-calls.ndjson")
	if err := os.WriteFile(mcpLog, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal(err)
	}
	mcp, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{
		"dieter-rpc-fixture":      map[string]any{"command": node, "args": []string{filepath.Join(fixtureDir, "mcp.mjs"), challenge, mcpLog}, "enabled": true},
		"dieter-disabled-fixture": map[string]any{"command": "/nonexistent-disabled-mcp", "enabled": false},
	}})
	// Packaged MCP discovery proves native extension roots participate too.
	if err := os.WriteFile(filepath.Join(plugin, ".mcp.json"), mcp, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "report.txt"), []byte("RPC integration report"), 0o600); err != nil {
		t.Fatal(err)
	}
	runner := NewSubprocessRunner(filepath.Join(base, "dieter/runtime/harness"))
	runtimeRoot := filepath.Join(base, "dieter/runtime/sessions/project")
	model := os.Getenv("DIETER_TEST_OMP_MODEL")
	if model == "" {
		model = "tailscale/glm-5.3-flash-exl3"
	}
	if err := os.MkdirAll(filepath.Join(plugin, "agents"), 0o700); err != nil {
		t.Fatal(err)
	}
	agent := fmt.Sprintf("---\nname: rpc-worker\ndescription: Native RPC integration proof worker\nmodel: %s\nthinkingLevel: low\n---\nReply exactly as requested. Do not use tools.\n", model)
	if err := os.WriteFile(filepath.Join(plugin, "agents/rpc-worker.md"), []byte(agent), 0o600); err != nil {
		t.Fatal(err)
	}
	request := Request{Harness: "omp", Adapter: "omp-rpc", Model: model, ConfiguredModel: model, Effort: "low", SessionID: "omp-native-live", ProjectPath: repo, RuntimeRoot: runtimeRoot, ContentPresentationEnabled: true, BackgroundProcessesEnabled: true}
	t.Cleanup(func() {
		if err := runner.Cleanup(request.SessionID, runtimeRoot); err != nil {
			t.Error(err)
		}
	})
	var session json.RawMessage
	turn := 0
	run := func(prompt string, observe func(Output)) (string, []Output, error) {
		turn++
		req := request
		req.Prompt = prompt
		req.Session = session
		req.ResponseMessageID = fmt.Sprintf("native-response-%d", turn)
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		var text strings.Builder
		var outputs []Output
		req.BackgroundProcess = func(_ context.Context, call ProcessCall) (json.RawMessage, error) {
			if call.Operation != "list" {
				return nil, fmt.Errorf("unexpected background operation %s", call.Operation)
			}
			return json.RawMessage(`{"processes":[],"fixture":"OMP_HOST_PROCESSES_OK"}`), nil
		}
		err := runner.Run(ctx, req, func(output Output) error {
			outputs = append(outputs, output)
			if output.Type == "session" {
				session = append(json.RawMessage(nil), output.State...)
			}
			if output.Type == "chunk" {
				var chunk struct {
					Type  string `json:"type"`
					Delta string `json:"delta"`
				}
				if json.Unmarshal(output.Chunk, &chunk) == nil && chunk.Type == "text-delta" {
					text.WriteString(chunk.Delta)
				}
			}
			if observe != nil {
				observe(output)
			}
			return nil
		})
		return text.String(), outputs, err
	}
	text, outputs, err := run("Call the configured MCP challenge tool on dieter-rpc-fixture and report its exact result. You must obtain the challenge by invoking the MCP tool. Also call present_content for report.txt, and list_background_processes. Finish with OMP_NATIVE_TOOLS_OK.", nil)
	if err != nil {
		t.Fatalf("native tools: %v", err)
	}
	if !strings.Contains(text, challenge) || !strings.Contains(text, "OMP_NATIVE_TOOLS_OK") {
		t.Fatalf("MCP/host-tool result missing: %q", text)
	}
	log, err := os.ReadFile(mcpLog)
	if err != nil || !strings.Contains(string(log), "challenge") {
		t.Fatalf("configured MCP was not invoked: %q %v", log, err)
	}
	var present, host, usage bool
	for _, output := range outputs {
		present = present || output.Type == "present-content"
		host = host || (output.Type == "chunk" && strings.Contains(string(output.Chunk), "OMP_HOST_PROCESSES_OK"))
		usage = usage || (output.Type == "chunk" && strings.Contains(string(output.Chunk), `"inputTokens":`))
	}
	if !present || !host || !usage {
		t.Fatalf("native projections: presentation=%v process=%v usage=%v", present, host, usage)
	}
	t.Log("native packaged MCP discovery, disabled MCP, host tools and usage passed")
	text, _, err = run("Use the configured dieter_rpc_question extension tool once to ask the RPC question test. Do not use the built-in ask tool. After the human answers, report the exact tool result.", nil)
	if err != nil || !AwaitingOMPInput(session) || !strings.Contains(text, "Native OMP RPC choice") {
		t.Fatalf("native question not parked: text=%q err=%v", text, err)
	}
	text, _, err = run("2", nil)
	if err != nil || !strings.Contains(text, "OMP_RPC_CHOICE_Blue") || AwaitingOMPInput(session) {
		t.Fatalf("native question did not resume: text=%q err=%v", text, err)
	}
	t.Log("native extension question and normal-chat answer passed")
	text, _, err = run("What exact MCP challenge did you obtain earlier in this conversation? Reply with that value only and do not invoke tools.", nil)
	if err != nil || !strings.Contains(text, challenge) {
		t.Fatalf("native session history lost: text=%q err=%v", text, err)
	}
	t.Log("native session resume passed")
	text, outputs, err = run(`Use todo to init phase "RPC verification" with item "Child result". Then use task with one task for agent rpc-worker: "Reply OMP_RPC_CHILD_OK and nothing else; do not use tools." Use solutionSpace "one fixed response". Mark the todo item done. Finish OMP_RPC_PROGRESS_OK.`, nil)
	if err != nil || !strings.Contains(text, "OMP_RPC_PROGRESS_OK") {
		t.Fatalf("native task/todo turn: text=%q err=%v", text, err)
	}
	var subagent, plan bool
	for _, output := range outputs {
		if output.Type != "capability" {
			continue
		}
		var capability struct {
			ID       string `json:"id"`
			Subagent struct {
				Status string `json:"status"`
			} `json:"subagent"`
		}
		if json.Unmarshal(output.Capability, &capability) != nil {
			continue
		}
		subagent = subagent || (capability.ID == "subagents" && capability.Subagent.Status == "completed")
		plan = plan || capability.ID == "task-plan"
	}
	if !subagent || !plan {
		t.Fatalf("native progress missing: subagent=%v phases=%v", subagent, plan)
	}
	t.Log("native GLM subagent progress and todo phases passed")
	text, _, err = run(`Use the built-in ask tool once, with exactly one question "Native built-in color?" and options Red and Blue. After the answer report OMP_BUILTIN_ASK_OK followed by the selected color.`, nil)
	if err != nil || !AwaitingOMPInput(session) || !strings.Contains(text, "Native built-in color") {
		t.Fatalf("built-in ask not parked: text=%q err=%v", text, err)
	}
	text, _, err = run("2", nil)
	if err != nil || !strings.Contains(text, "OMP_BUILTIN_ASK_OK") || !strings.Contains(text, "Blue") {
		t.Fatalf("built-in ask failed to resume: text=%q err=%v", text, err)
	}
	t.Log("native built-in ask passed")
	text, _, err = run("/compact Keep the exact MCP challenge and the completed color choices.", nil)
	if err != nil {
		t.Fatalf("native compact: %v", err)
	}
	if !strings.Contains(strings.ToLower(text), "compact") {
		t.Fatalf("native compact command output missing: %q", text)
	}
	t.Log("native local slash-command completion passed")
	var suspended bool
	text, _, err = run("Call dieter_rpc_wait exactly once. After its result, reply OMP_RPC_WAIT_COMPLETED. Do not use other tools.", func(output Output) {
		if suspended || output.Type != "chunk" {
			return
		}
		var chunk struct {
			Type     string `json:"type"`
			ToolName string `json:"toolName"`
		}
		if json.Unmarshal(output.Chunk, &chunk) == nil && chunk.Type == "tool-input-available" && chunk.ToolName == "dieter_rpc_wait" {
			suspended = true
			if err := runner.Suspend(request.SessionID, runtimeRoot); err != nil {
				t.Errorf("suspend native turn: %v", err)
			}
		}
	})
	if err != nil || !suspended || !strings.Contains(string(session), `"continueFrom"`) {
		t.Fatalf("native turn not suspended: %v", err)
	}
	request.Continue = true
	text, _, err = run("", nil)
	request.Continue = false
	if err != nil || !strings.Contains(text, "OMP_RPC_WAIT_COMPLETED") {
		t.Fatalf("native restart lost its turn: text=%q err=%v", text, err)
	}
	t.Log("native Go worker suspension and reattachment passed")
	var canceled bool
	_, _, err = run("Call dieter_rpc_wait exactly once for the cancellation test. Do not use other tools.", func(output Output) {
		if canceled || output.Type != "chunk" {
			return
		}
		var chunk struct {
			Type     string `json:"type"`
			ToolName string `json:"toolName"`
		}
		if json.Unmarshal(output.Chunk, &chunk) == nil && chunk.Type == "tool-input-available" && chunk.ToolName == "dieter_rpc_wait" {
			canceled = true
			if err := runner.Cancel(request.SessionID, runtimeRoot); err != nil {
				t.Errorf("cancel native turn: %v", err)
			}
		}
	})
	if !canceled || err == nil {
		t.Fatalf("native cancellation did not interrupt the worker: canceled=%v err=%v", canceled, err)
	}
	t.Log("native cancellation passed")
}
