package harness

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// ompUpstreamRequest is one model request the fake upstream received.
type ompUpstreamRequest struct {
	Upstream      string // "anthropic" or "codex"
	Path          string
	Authorization string
	APIKey        string
	AccountID     string
	Model         string
	Effort        string
	Body          string
}

// credential is the token the request carried, however it was sent.
func (r ompUpstreamRequest) credential() string {
	if token, ok := strings.CutPrefix(r.Authorization, "Bearer "); ok {
		return token
	}
	return r.APIKey
}

func (r ompUpstreamRequest) String() string {
	return fmt.Sprintf("%s %s model=%s effort=%s credential=%.14s… account=%s", r.Upstream, r.Path, r.Model, r.Effort, r.credential(), r.AccountID)
}

// ompUpstream stands in for the Anthropic Messages API and the ChatGPT
// Codex Responses backend (SSE, as with PI_CODEX_WEBSOCKET=0). Every model
// request is answered with "<UPSTREAM>-OK", so a reply names the provider
// that produced it.
type ompUpstream struct {
	mu       sync.Mutex
	requests []ompUpstreamRequest
}

func (u *ompUpstream) snapshot() []ompUpstreamRequest {
	u.mu.Lock()
	defer u.mu.Unlock()
	return append([]ompUpstreamRequest(nil), u.requests...)
}

func (u *ompUpstream) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	raw, _ := io.ReadAll(request.Body)
	if request.Header.Get("Content-Encoding") == "gzip" {
		if reader, err := gzip.NewReader(bytes.NewReader(raw)); err == nil {
			raw, _ = io.ReadAll(reader)
		}
	}
	var body struct {
		Model     string `json:"model"`
		Reasoning struct {
			Effort string `json:"effort"`
		} `json:"reasoning"`
		OutputConfig struct {
			Effort string `json:"effort"`
		} `json:"output_config"`
	}
	_ = json.Unmarshal(raw, &body)
	upstream := ""
	switch {
	case request.Method == http.MethodPost && strings.HasSuffix(request.URL.Path, "/v1/messages"):
		upstream = "anthropic"
	case request.Method == http.MethodPost && strings.HasSuffix(request.URL.Path, "/codex/responses"):
		upstream = "codex"
	default:
		// Model discovery and anything else: nothing here.
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusNotFound)
		_, _ = response.Write([]byte(`{"error":{"type":"not_found","message":"fake upstream"}}`))
		return
	}
	record := ompUpstreamRequest{
		Upstream: upstream, Path: request.URL.Path, Authorization: request.Header.Get("Authorization"), APIKey: request.Header.Get("X-Api-Key"),
		AccountID: request.Header.Get("Chatgpt-Account-Id"), Model: body.Model, Effort: body.Reasoning.Effort + body.OutputConfig.Effort, Body: string(raw),
	}
	u.mu.Lock()
	u.requests = append(u.requests, record)
	u.mu.Unlock()
	response.Header().Set("Content-Type", "text/event-stream")
	response.Header().Set("Cache-Control", "no-cache")
	var events []any
	if upstream == "anthropic" {
		events = anthropicSSE(body.Model, "ANTHROPIC-OK")
	} else {
		events = codexSSE(body.Model, "CODEX-OK")
	}
	for _, event := range events {
		data, _ := json.Marshal(event)
		var kind struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(data, &kind)
		_, _ = fmt.Fprintf(response, "event: %s\ndata: %s\n\n", kind.Type, data)
	}
	if flusher, ok := response.(http.Flusher); ok {
		flusher.Flush()
	}
}

func anthropicSSE(model, text string) []any {
	return []any{
		map[string]any{"type": "message_start", "message": map[string]any{
			"id": "msg_fake", "type": "message", "role": "assistant", "model": model, "content": []any{},
			"stop_reason": nil, "stop_sequence": nil, "usage": map[string]any{"input_tokens": 12, "output_tokens": 1},
		}},
		map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}},
		map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": text}},
		map[string]any{"type": "content_block_stop", "index": 0},
		map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": "end_turn", "stop_sequence": nil}, "usage": map[string]any{"output_tokens": 4}},
		map[string]any{"type": "message_stop"},
	}
}

func codexSSE(model, text string) []any {
	part := map[string]any{"type": "output_text", "text": text, "annotations": []any{}}
	item := map[string]any{"id": "msg_fake", "type": "message", "role": "assistant", "status": "completed", "content": []any{part}}
	usage := map[string]any{
		"input_tokens": 12, "output_tokens": 4, "total_tokens": 16,
		"input_tokens_details": map[string]any{"cached_tokens": 0}, "output_tokens_details": map[string]any{"reasoning_tokens": 0},
	}
	text0 := map[string]any{"item_id": "msg_fake", "output_index": 0, "content_index": 0}
	with := func(base map[string]any, extra map[string]any) map[string]any {
		merged := map[string]any{}
		for key, value := range base {
			merged[key] = value
		}
		for key, value := range extra {
			merged[key] = value
		}
		return merged
	}
	return []any{
		map[string]any{"type": "response.created", "response": map[string]any{"id": "resp_fake", "object": "response", "status": "in_progress", "model": model, "output": []any{}}},
		map[string]any{"type": "response.output_item.added", "output_index": 0, "item": with(item, map[string]any{"status": "in_progress", "content": []any{}})},
		with(text0, map[string]any{"type": "response.content_part.added", "part": map[string]any{"type": "output_text", "text": "", "annotations": []any{}}}),
		with(text0, map[string]any{"type": "response.output_text.delta", "delta": text}),
		with(text0, map[string]any{"type": "response.output_text.done", "text": text}),
		with(text0, map[string]any{"type": "response.content_part.done", "part": part}),
		map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item},
		map[string]any{"type": "response.completed", "response": map[string]any{"id": "resp_fake", "object": "response", "status": "completed", "model": model, "output": []any{item}, "usage": usage}},
	}
}

// fakeChatGPTToken is an unsigned ChatGPT access token whose claims name the
// account, as OMP derives the chatgpt-account-id header from the token.
func fakeChatGPTToken(accountID string) string {
	encode := func(value any) string {
		raw, _ := json.Marshal(value)
		return base64.RawURLEncoding.EncodeToString(raw)
	}
	return encode(map[string]any{"alg": "none", "typ": "JWT"}) + "." +
		encode(map[string]any{"exp": time.Now().Add(240 * time.Hour).Unix(), "https://api.openai.com/auth": map[string]any{"chatgpt_account_id": accountID}}) + ".e2e"
}

type ompTurnResult struct {
	text    string
	session json.RawMessage
	err     error
}

func (r ompTurnResult) sessionID() string {
	var state struct {
		Data struct {
			ACPSessionID string `json:"acpSessionId"`
		} `json:"data"`
	}
	_ = json.Unmarshal(r.session, &state)
	return state.Data.ACPSessionID
}

// TestSubprocessRunnerOMPManagedAccounts runs the pinned Oh My Pi through
// the real runner against a loopback stand-in for both providers. OMP holds
// no login: its managed models.yml asks Dieter's token helper (here a fake
// dieter executable) for each provider's token. A Claude implementation
// model gets a ChatGPT advisor; the next turn resumes the same session on a
// ChatGPT model with another effort and a Claude advisor.
func TestSubprocessRunnerOMPManagedAccounts(t *testing.T) {
	if os.Getenv("DIETER_TEST_OMP_E2E") != "1" {
		t.Skip("set DIETER_TEST_OMP_E2E=1 to run the pinned Oh My Pi against a fake upstream (installs the managed Bun with npm)")
	}
	cwd, _ := os.Getwd()
	runtimeDir := filepath.Join(cwd, "runtime")
	if _, err := os.Stat(filepath.Join(runtimeDir, "node_modules")); err != nil {
		t.Skip("local harness dependencies are not installed")
	}

	upstream := &ompUpstream{}
	server := httptest.NewServer(upstream)
	defer server.Close()

	base := t.TempDir()
	dieterHome := filepath.Join(base, "dieter-home")
	home := filepath.Join(base, "home")
	repo := filepath.Join(base, "repo")
	for _, dir := range []string{filepath.Join(repo, ".git"), home} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	// The fake dieter executable: it logs who asked and prints the token of
	// the requested provider, like `dieter provider token --turn`.
	const claudeToken, chatGPTAccount, turnToken = "sk-ant-oat01-dieter-e2e-claude-access-token", "acct-dieter-e2e", "dtt1:c_omp_e2e:turn:e2e"
	chatGPTToken := fakeChatGPTToken(chatGPTAccount)
	helperDir := filepath.Join(base, "Dieter App")
	if err := os.MkdirAll(helperDir, 0o700); err != nil {
		t.Fatal(err)
	}
	helper, helperLog := filepath.Join(helperDir, "dieter"), filepath.Join(base, "helper.log")
	script := "#!/bin/sh\nprintf '%s %s\\n' \"$DIETER_TURN_TOKEN\" \"$*\" >> " + shellQuote(helperLog) + "\n" +
		"case \"$*\" in\n" +
		"  'provider token --turn --provider claude') printf '%s\\n' " + shellQuote(claudeToken) + " ;;\n" +
		"  'provider token --turn --provider chatgpt') printf '%s\\n' " + shellQuote(chatGPTToken) + " ;;\n" +
		"  *) echo \"unexpected helper call: $*\" >&2; exit 1 ;;\n" +
		"esac\n"
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}

	variables := []string{"HOME=" + home, "PATH=" + os.Getenv("PATH")}
	for _, name := range []string{"USER", "LOGNAME", "TMPDIR", "SHELL", "LANG"} {
		if value := os.Getenv(name); value != "" {
			variables = append(variables, name+"="+value)
		}
	}
	env := Environment{
		// The checkout's runtime: OMP links its pinned packages from there.
		Variables: variables, RuntimeDir: runtimeDir,
		OMPProviderBaseURLs: map[string]string{"anthropic": server.URL, "openai-codex": server.URL + "/backend-api"},
	}
	runner := NewSubprocessRunner(dieterHome, env)
	runtimeRoot := filepath.Join(dieterHome, "runtime", "sessions", "p_omp_e2e")
	run := func(model, effort, advisor string, session json.RawMessage) ompTurnResult {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
		defer cancel()
		var result ompTurnResult
		var text strings.Builder
		result.err = runner.Run(ctx, Request{
			Harness: "omp", Adapter: "omp-acp", Model: model, ConfiguredModel: model, Effort: effort,
			Options: map[string]string{"advisor_model": advisor, "advisor_effort": "low"},
			Prompt:  "Reply with a short confirmation. Do not use tools.", SessionID: "c_omp_e2e", ResponseMessageID: "assistant_omp_e2e",
			Session: session, ProjectPath: repo, RuntimeRoot: runtimeRoot, DieterExecutable: helper,
			Environment: map[string]string{
				"DIETER_HOME": dieterHome, "DIETER_CARD_ID": "c_omp_e2e", "DIETER_TURN_TOKEN": turnToken,
				// Codex over SSE, which the fake upstream speaks.
				"DIETER_HARNESS_ENV": "PI_CODEX_WEBSOCKET", "PI_CODEX_WEBSOCKET": "0",
			},
		}, func(output Output) error {
			switch output.Type {
			case "chunk":
				var chunk struct {
					Type  string `json:"type"`
					Delta string `json:"delta"`
				}
				if json.Unmarshal(output.Chunk, &chunk) == nil && chunk.Type == "text-delta" {
					text.WriteString(chunk.Delta)
				}
			case "session":
				result.session = append(json.RawMessage(nil), output.State...)
			}
			return nil
		})
		result.text = text.String()
		return result
	}
	describe := func(requests []ompUpstreamRequest) string {
		lines := make([]string, 0, len(requests))
		for _, request := range requests {
			lines = append(lines, request.String())
		}
		return strings.Join(lines, "\n")
	}
	split := func(requests []ompUpstreamRequest) (anthropic, codex []ompUpstreamRequest) {
		for _, request := range requests {
			if request.Upstream == "anthropic" {
				anthropic = append(anthropic, request)
			} else {
				codex = append(codex, request)
			}
		}
		return anthropic, codex
	}
	checkCredentials := func(turn string, anthropic, codex []ompUpstreamRequest) {
		t.Helper()
		for _, request := range anthropic {
			if request.credential() != claudeToken {
				t.Errorf("%s: an Anthropic request carried another credential: %s", turn, request)
			}
		}
		for _, request := range codex {
			if request.credential() != chatGPTToken || request.AccountID != chatGPTAccount {
				t.Errorf("%s: a Codex request carried another credential or account: %s", turn, request)
			}
		}
	}

	// Turn 1: Claude implementation model, ChatGPT advisor.
	first := run("anthropic/claude-sonnet-5-5", "low", "openai-codex/gpt-6-sol", nil)
	firstRequests := upstream.snapshot()
	anthropic, codex := split(firstRequests)
	if first.err != nil || !strings.Contains(first.text, "ANTHROPIC-OK") || first.sessionID() == "" {
		t.Fatalf("first turn text=%q session=%s err=%v\nrequests:\n%s", first.text, first.session, first.err, describe(firstRequests))
	}
	if len(anthropic) == 0 || len(codex) == 0 {
		t.Fatalf("first turn: want the implementation model on Anthropic and the advisor on Codex:\n%s", describe(firstRequests))
	}
	for _, request := range anthropic {
		if request.Model != "claude-sonnet-5-5" {
			t.Errorf("first turn: every Claude role runs the implementation model: %s", request)
		}
	}
	for _, request := range codex {
		if request.Model != "gpt-6-sol" {
			t.Errorf("first turn: the advisor runs another model: %s", request)
		}
	}
	checkCredentials("first turn", anthropic, codex)

	// Turn 2: the same session continues on a ChatGPT model with more
	// effort and a Claude advisor; the launch is unchanged.
	second := run("openai-codex/gpt-6-sol", "high", "anthropic/claude-haiku-5-5", first.session)
	secondRequests := upstream.snapshot()[len(firstRequests):]
	anthropic, codex = split(secondRequests)
	if second.err != nil || !strings.Contains(second.text, "CODEX-OK") {
		t.Fatalf("second turn text=%q err=%v\nrequests:\n%s", second.text, second.err, describe(secondRequests))
	}
	if second.sessionID() != first.sessionID() {
		t.Fatalf("second turn session %q, want the first turn's %q", second.sessionID(), first.sessionID())
	}
	carried, highEffort := false, false
	for _, request := range codex {
		if request.Model != "gpt-6-sol" {
			t.Errorf("second turn: a Codex request runs another model: %s", request)
		}
		carried = carried || strings.Contains(request.Body, "ANTHROPIC-OK")
		highEffort = highEffort || request.Effort == "high"
	}
	if len(codex) == 0 || !carried || !highEffort {
		t.Fatalf("second turn: want gpt-6-sol at high effort with the first turn's reply in its history (carried=%v high=%v):\n%s", carried, highEffort, describe(secondRequests))
	}
	if len(anthropic) == 0 {
		t.Fatalf("second turn: want the Claude advisor:\n%s", describe(secondRequests))
	}
	for _, request := range anthropic {
		if request.Model != "claude-haiku-5-5" {
			t.Errorf("second turn: a Claude request is not the advisor's model: %s", request)
		}
	}
	checkCredentials("second turn", anthropic, codex)

	t.Logf("upstream requests:\n%s", describe(upstream.snapshot()))

	// OMP asked the helper, with the turn's identity, for both providers.
	raw, err := os.ReadFile(helperLog)
	if err != nil {
		t.Fatal(err)
	}
	calls := map[string]int{}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		calls[line]++
	}
	for _, provider := range []string{"claude", "chatgpt"} {
		if calls[turnToken+" provider token --turn --provider "+provider] == 0 {
			t.Errorf("the helper was never asked for %s: %q", provider, raw)
		}
	}
	if len(calls) != 2 {
		t.Errorf("unexpected helper calls: %q", raw)
	}
	models, err := os.ReadFile(filepath.Join(OMPAgentDir(dieterHome), "models.yml"))
	if err != nil || !strings.Contains(string(models), server.URL) {
		t.Fatalf("managed models.yml = %q, %v", models, err)
	}
	// OMP keeps its sessions and settings in the managed home, but never a
	// token it was handed.
	var stored []string
	if err := filepath.WalkDir(OMPAgentDir(dieterHome), func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		stored = append(stored, path)
		for name, token := range map[string]string{"Claude": claudeToken, "ChatGPT": chatGPTToken} {
			if bytes.Contains(content, []byte(token)) {
				t.Errorf("%s stores the %s token", path, name)
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(stored) < 2 {
		t.Fatalf("the managed OMP home holds only %v", stored)
	}
}
