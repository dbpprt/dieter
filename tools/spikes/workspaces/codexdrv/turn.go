package codexdrv

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"dieter.spike/workspaces/core"
)

// turnState collects what Codex reports during one turn.
type turnState struct {
	mu       sync.Mutex
	threadID string
	turnID   string
	done     chan struct{}
	finished bool

	status, turnErr   string
	changes           []rawChange // completed fileChange entries, in order
	fileChanges       []string
	fileChangeItems   int
	commandExecutions int
	commands          []string
	failedItems       []string
	diffUpdates       int
	lastDiff          string
	tokenUsage        map[string]any
	errors            []string
	warnings          []string
	serverRequests    []string
	agentMessage      string
	otherThread       int
	rawToolCalls      []string
	rawToolFailures   []string
}

type rawChange struct {
	path string
	kind core.ChangeKind
}

func newTurnState(threadID string) *turnState {
	return &turnState{threadID: threadID, done: make(chan struct{})}
}

func (t *turnState) setTurnID(id string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.turnID == "" {
		t.turnID = id
	}
}

func (t *turnState) getTurnID() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.turnID
}

// handle consumes one server notification.
func (t *turnState) handle(method string, params json.RawMessage, redact func(string) string) {
	var head struct {
		ThreadID string `json:"threadId"`
	}
	_ = json.Unmarshal(params, &head)
	t.mu.Lock()
	defer t.mu.Unlock()
	if head.ThreadID != "" && head.ThreadID != t.threadID {
		t.otherThread++
		return
	}
	switch method {
	case "turn/started":
		var p struct {
			Turn struct {
				ID string `json:"id"`
			} `json:"turn"`
		}
		if json.Unmarshal(params, &p) == nil && t.turnID == "" {
			t.turnID = p.Turn.ID
		}
	case "item/completed":
		var p struct {
			Item json.RawMessage `json:"item"`
		}
		if json.Unmarshal(params, &p) == nil {
			t.itemCompleted(p.Item)
		}
	case "turn/diff/updated":
		var p struct {
			Diff string `json:"diff"`
		}
		if json.Unmarshal(params, &p) == nil {
			t.diffUpdates++
			t.lastDiff = p.Diff
		}
	case "thread/tokenUsage/updated":
		var p struct {
			TokenUsage map[string]any `json:"tokenUsage"`
		}
		if json.Unmarshal(params, &p) == nil && p.TokenUsage != nil {
			t.tokenUsage = p.TokenUsage
		}
	case "error":
		var p struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
			WillRetry bool `json:"willRetry"`
		}
		if json.Unmarshal(params, &p) == nil {
			msg := redact(p.Error.Message)
			if p.WillRetry {
				msg = "(will retry) " + msg
			}
			t.errors = append(t.errors, msg)
		}
	case "warning", "configWarning", "deprecationNotice", "guardianWarning":
		var p struct {
			Message string `json:"message"`
		}
		if json.Unmarshal(params, &p) == nil && p.Message != "" {
			t.warnings = append(t.warnings, method+": "+redact(p.Message))
		}
	case "modelProvider/authRecoveryStarted", "modelProvider/authRecoveryCompleted":
		t.warnings = append(t.warnings, method)
	case "rawResponseItem/completed":
		var p struct {
			Item json.RawMessage `json:"item"`
		}
		if json.Unmarshal(params, &p) == nil {
			t.rawItem(p.Item, redact)
		}
	case "turn/completed":
		var p struct {
			Turn struct {
				ID     string `json:"id"`
				Status string `json:"status"`
				Error  *struct {
					Message string `json:"message"`
				} `json:"error"`
			} `json:"turn"`
		}
		if json.Unmarshal(params, &p) != nil || t.finished {
			return
		}
		if t.turnID != "" && p.Turn.ID != t.turnID {
			return
		}
		t.turnID = p.Turn.ID
		t.status = p.Turn.Status
		if p.Turn.Error != nil {
			t.turnErr = redact(p.Turn.Error.Message)
		}
		t.finished = true
		close(t.done)
	}
}

func (t *turnState) itemCompleted(raw json.RawMessage) {
	var base struct {
		Type   string `json:"type"`
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if json.Unmarshal(raw, &base) != nil {
		return
	}
	switch base.Type {
	case "fileChange":
		var it struct {
			Changes []struct {
				Path string `json:"path"`
				Kind struct {
					Type     string  `json:"type"`
					MovePath *string `json:"move_path"`
				} `json:"kind"`
			} `json:"changes"`
		}
		if json.Unmarshal(raw, &it) != nil {
			return
		}
		t.fileChangeItems++
		for _, c := range it.Changes {
			desc := c.Kind.Type + " " + c.Path
			if c.Kind.MovePath != nil && *c.Kind.MovePath != "" {
				desc += " -> " + *c.Kind.MovePath
			}
			if base.Status != "completed" {
				t.failedItems = append(t.failedItems, fmt.Sprintf("fileChange %s status=%s: %s", base.ID, base.Status, desc))
				continue
			}
			t.fileChanges = append(t.fileChanges, desc)
			switch {
			case c.Kind.Type == "add":
				t.changes = append(t.changes, rawChange{c.Path, core.Added})
			case c.Kind.Type == "delete":
				t.changes = append(t.changes, rawChange{c.Path, core.Deleted})
			case c.Kind.Type == "update" && c.Kind.MovePath != nil && *c.Kind.MovePath != "":
				t.changes = append(t.changes, rawChange{c.Path, core.Deleted}, rawChange{*c.Kind.MovePath, core.Added})
			case c.Kind.Type == "update":
				t.changes = append(t.changes, rawChange{c.Path, core.Modified})
			default:
				t.changes = append(t.changes, rawChange{c.Path, core.Changed})
			}
		}
	case "commandExecution":
		var it struct {
			Command  string `json:"command"`
			ExitCode *int   `json:"exitCode"`
		}
		if json.Unmarshal(raw, &it) != nil {
			return
		}
		t.commandExecutions++
		t.commands = append(t.commands, it.Command)
		if base.Status != "completed" || (it.ExitCode != nil && *it.ExitCode != 0) {
			code := "?"
			if it.ExitCode != nil {
				code = fmt.Sprint(*it.ExitCode)
			}
			t.failedItems = append(t.failedItems, fmt.Sprintf("commandExecution %s status=%s exit=%s: %s", base.ID, base.Status, code, it.Command))
		}
	case "agentMessage":
		var it struct {
			Text string `json:"text"`
		}
		if json.Unmarshal(raw, &it) == nil {
			t.agentMessage = it.Text
		}
	default:
		if base.Status == "failed" || base.Status == "declined" {
			t.failedItems = append(t.failedItems, fmt.Sprintf("%s %s status=%s", base.Type, base.ID, base.Status))
		}
	}
}

// rawItem records model-level tool calls from rawResponseItem/completed.
// With code mode, tools run inside an `exec` script; a failed apply_patch
// there produces no fileChange item, only a failing script output.
func (t *turnState) rawItem(raw json.RawMessage, redact func(string) string) {
	var it struct {
		Type   string          `json:"type"`
		Name   string          `json:"name"`
		Output json.RawMessage `json:"output"`
	}
	if json.Unmarshal(raw, &it) != nil {
		return
	}
	switch it.Type {
	case "custom_tool_call", "function_call", "local_shell_call", "tool_search_call":
		name := it.Name
		if name == "" {
			name = it.Type
		}
		t.rawToolCalls = append(t.rawToolCalls, name)
	case "custom_tool_call_output", "function_call_output":
		text := outputText(it.Output)
		if strings.Contains(text, "Script failed") || strings.Contains(text, "Script error") || strings.Contains(text, "verification failed") {
			text = strings.Join(strings.Fields(redact(text)), " ")
			if len(text) > 300 {
				text = text[:300] + "…"
			}
			t.rawToolFailures = append(t.rawToolFailures, text)
		}
	}
}

// outputText flattens a tool output: a string, or a list of content parts.
func outputText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []struct {
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) == nil {
		var b strings.Builder
		for _, p := range parts {
			b.WriteString(p.Text)
			b.WriteString("\n")
		}
		return b.String()
	}
	return ""
}

// mergeChange folds a later report for the same path into the net change of
// the turn, matching what a before/after tree diff would show.
func mergeChange(cs core.ChangeSet, path string, kind core.ChangeKind) {
	path = core.NormPath(path)
	if path == "" {
		return
	}
	prev, ok := cs[path]
	switch {
	case !ok:
		cs[path] = core.Change{Path: path, Kind: kind}
	case prev.Kind == core.Added && kind == core.Deleted:
		delete(cs, path)
	case prev.Kind == core.Added:
		// still added
	case prev.Kind == core.Deleted && kind == core.Added:
		cs[path] = core.Change{Path: path, Kind: core.Modified}
	case kind == core.Changed:
		// keep the more specific kind
	default:
		cs[path] = core.Change{Path: path, Kind: kind}
	}
}

// fill copies the collected state into a TurnResult.
func (t *turnState) fill(res *core.TurnResult, rel *relativizer) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if rel == nil {
		rel = newRelativizer()
	}
	outside := []string{}
	for _, c := range t.changes {
		p, in := rel.rel(c.path)
		if !in {
			outside = append(outside, p)
		}
		mergeChange(res.Reported, p, c.kind)
	}
	diffPaths := []string{}
	seen := map[string]bool{}
	for _, p := range ParseUnifiedDiffPaths(t.lastDiff) {
		k, _ := rel.rel(p)
		if !seen[k] {
			seen[k] = true
			diffPaths = append(diffPaths, k)
		}
	}
	d := res.Detail
	d["threadId"] = t.threadID
	d["turnId"] = t.turnID
	d["turnStatus"] = t.status
	d["turnDiffPaths"] = diffPaths
	d["turnDiffUpdates"] = t.diffUpdates
	d["fileChangeItems"] = t.fileChangeItems
	d["fileChanges"] = nonNil(t.fileChanges)
	d["commandExecutions"] = t.commandExecutions
	d["commands"] = nonNil(t.commands)
	d["failedItems"] = nonNil(t.failedItems)
	d["rawToolCalls"] = nonNil(t.rawToolCalls)
	if len(t.rawToolFailures) > 0 {
		d["rawToolFailures"] = t.rawToolFailures
	}
	if t.tokenUsage != nil {
		d["tokenUsage"] = t.tokenUsage
	}
	if len(outside) > 0 {
		d["outsidePaths"] = outside
	}
	if len(t.errors) > 0 {
		d["errors"] = t.errors
	}
	if len(t.warnings) > 0 {
		d["warnings"] = t.warnings
	}
	if len(t.serverRequests) > 0 {
		d["serverRequests"] = t.serverRequests
	}
	if t.otherThread > 0 {
		d["otherThreadEvents"] = t.otherThread
	}
	if t.agentMessage != "" {
		msg := t.agentMessage
		if len(msg) > 500 {
			msg = msg[:500] + "…"
		}
		d["agentMessage"] = msg
	}
	if res.Error == "" && t.finished && t.status != "completed" {
		res.Error = "turn " + t.status
		if t.turnErr != "" {
			res.Error += ": " + t.turnErr
		}
	}
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}
