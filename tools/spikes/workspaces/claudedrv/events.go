package claudedrv

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"dieter.spike/workspaces/core"
)

// fileTools are Claude Code's native file-writing tools and the input field
// naming the file.
var fileTools = map[string]string{
	"Write":        "file_path",
	"Edit":         "file_path",
	"MultiEdit":    "file_path",
	"NotebookEdit": "notebook_path",
}

// sdkLine is the union of the JSONL lines the driver script prints: SDK
// messages and the driver's own dieter_* records.
type sdkLine struct {
	Type            string          `json:"type"`
	Subtype         string          `json:"subtype"`
	SessionID       string          `json:"session_id"`
	ParentToolUseID *string         `json:"parent_tool_use_id"`
	IsReplay        bool            `json:"isReplay"`
	Message         *sdkMessage     `json:"message"`
	ToolUseResult   json.RawMessage `json:"tool_use_result"`
	Error           json.RawMessage `json:"error"`

	// system/init
	Model             string   `json:"model"`
	PermissionMode    string   `json:"permissionMode"`
	ClaudeCodeVersion string   `json:"claude_code_version"`
	APIKeySource      string   `json:"apiKeySource"`
	Tools             []string `json:"tools"`

	// result
	IsError           bool            `json:"is_error"`
	Result            string          `json:"result"`
	NumTurns          int             `json:"num_turns"`
	TotalCostUSD      float64         `json:"total_cost_usd"`
	Usage             json.RawMessage `json:"usage"`
	DurationMS        float64         `json:"duration_ms"`
	DurationAPIMS     float64         `json:"duration_api_ms"`
	StopReason        *string         `json:"stop_reason"`
	TerminalReason    string          `json:"terminal_reason"`
	Errors            []string        `json:"errors"`
	PermissionDenials []any           `json:"permission_denials"`

	// dieter_hook
	Hook  string     `json:"hook"`
	Input *hookInput `json:"input"`
}

type sdkMessage struct {
	Content json.RawMessage `json:"content"`
}

type contentBlock struct {
	Type      string          `json:"type"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	IsError   bool            `json:"is_error"`
}

type hookInput struct {
	SessionID    string          `json:"session_id"`
	ToolName     string          `json:"tool_name"`
	ToolUseID    string          `json:"tool_use_id"`
	ToolInput    json.RawMessage `json:"tool_input"`
	ToolResponse json.RawMessage `json:"tool_response"`
	AgentID      string          `json:"agent_id"`
	Error        any             `json:"error"`
}

// fileToolOutput covers FileWriteOutput, FileEditOutput and
// NotebookEditOutput.
type fileToolOutput struct {
	Type         string          `json:"type"` // Write: "create" | "update"
	FilePath     string          `json:"filePath"`
	NotebookPath string          `json:"notebook_path"`
	OldString    *string         `json:"oldString"`
	OriginalFile json.RawMessage `json:"originalFile"`
	Staged       bool            `json:"staged"`
	GitDiff      *struct {
		Status string `json:"status"`
	} `json:"gitDiff"`
}

type bashEditDiff struct {
	Files []struct {
		FilePath string            `json:"filePath"`
		Hunks    []json.RawMessage `json:"hunks"`
		Created  bool              `json:"created"`
		Deleted  bool              `json:"deleted"`
	} `json:"files"`
	MoreFiles    int      `json:"moreFiles"`
	ChangedFiles []string `json:"changedFiles"`
	Unavailable  bool     `json:"unavailable"`
	Skipped      bool     `json:"skipped"`
	Shared       bool     `json:"shared"`
}

type toolUse struct {
	name, path, parent, command string
}

type observation struct {
	path string
	kind core.ChangeKind
}

// accumulator folds one turn's JSONL into reported changes and details.
type accumulator struct {
	roots []string

	sessionID     string
	sawResult     bool
	resultIsError bool
	resultSubtype string
	resultText    string
	driverError   string

	toolCalls     map[string]int
	bashCalls     int
	replayed      int
	unparsed      int
	uses          map[string]*toolUse
	fileDone      map[string]string // tool_use_id → sources that reported it
	fileTyped     map[string]bool   // tool_use_id → settled from a structured result
	bashDone      map[string]map[string]any
	bashOrder     []string
	obs           []observation
	subagentEdits []map[string]any
	failedEdits   []map[string]any
	stagedEdits   []string
	outside       map[string]bool
	assistantErrs []string
	info          map[string]any
}

func newAccumulator(roots []string) *accumulator {
	return &accumulator{
		roots:     roots,
		toolCalls: map[string]int{},
		uses:      map[string]*toolUse{},
		fileDone:  map[string]string{},
		fileTyped: map[string]bool{},
		bashDone:  map[string]map[string]any{},
		outside:   map[string]bool{},
		info:      map[string]any{},
	}
}

func (a *accumulator) handle(raw []byte) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return
	}
	var l sdkLine
	if err := json.Unmarshal(raw, &l); err != nil {
		a.unparsed++
		return
	}
	if l.IsReplay {
		a.replayed++
		return
	}
	if l.SessionID != "" {
		a.sessionID = l.SessionID
	}
	switch l.Type {
	case "system":
		if l.Subtype == "init" {
			a.info["model"] = l.Model
			a.info["permissionMode"] = l.PermissionMode
			a.info["claudeCodeVersion"] = l.ClaudeCodeVersion
			a.info["apiKeySource"] = l.APIKeySource
			a.info["toolCount"] = len(l.Tools)
			var ft []string
			for _, t := range l.Tools {
				if _, ok := fileTools[t]; ok || t == "Bash" {
					ft = append(ft, t)
				}
			}
			a.info["fileAndShellTools"] = ft
		}
	case "assistant":
		if s := jsonString(l.Error); s != "" {
			a.assistantErrs = append(a.assistantErrs, s)
		}
		for _, b := range blocks(l.Message) {
			if b.Type != "tool_use" || b.ID == "" || a.uses[b.ID] != nil {
				continue
			}
			u := &toolUse{name: b.Name}
			if l.ParentToolUseID != nil {
				u.parent = *l.ParentToolUseID
			}
			var in map[string]any
			_ = json.Unmarshal(b.Input, &in)
			if field, ok := fileTools[b.Name]; ok {
				u.path, _ = in[field].(string)
			}
			if b.Name == "Bash" {
				a.bashCalls++
				u.command, _ = in["command"].(string)
			}
			a.uses[b.ID] = u
			a.toolCalls[b.Name]++
		}
	case "user":
		var results []contentBlock
		for _, b := range blocks(l.Message) {
			if b.Type == "tool_result" {
				results = append(results, b)
			}
		}
		for _, b := range results {
			u := a.uses[b.ToolUseID]
			if u == nil {
				continue
			}
			var structured json.RawMessage
			if len(results) == 1 {
				structured = l.ToolUseResult
			}
			if _, ok := fileTools[u.name]; ok {
				a.fileResult(b.ToolUseID, u, structured, b.IsError, "", "toolResult")
			} else if u.name == "Bash" && !b.IsError {
				a.bashResult(b.ToolUseID, structured, "toolResult")
			}
		}
	case "result":
		a.sawResult = true
		a.resultIsError = l.IsError
		a.resultSubtype = l.Subtype
		a.resultText = l.Result
		if len(l.Errors) > 0 {
			a.resultText = strings.Join(append([]string{l.Result}, l.Errors...), "; ")
		}
		a.info["resultSubtype"] = l.Subtype
		a.info["isError"] = l.IsError
		a.info["costUSD"] = l.TotalCostUSD
		a.info["numTurns"] = l.NumTurns
		a.info["durationMs"] = l.DurationMS
		a.info["durationApiMs"] = l.DurationAPIMS
		a.info["terminalReason"] = l.TerminalReason
		a.info["permissionDenials"] = len(l.PermissionDenials)
		if l.StopReason != nil {
			a.info["stopReason"] = *l.StopReason
		}
		var usage map[string]any
		if json.Unmarshal(l.Usage, &usage) == nil {
			a.info["usage"] = usage
		}
	case "dieter_hook":
		a.hook(l.Hook, l.Input)
	case "dieter_error":
		a.driverError = jsonString(l.Error)
	}
}

func (a *accumulator) hook(name string, in *hookInput) {
	if in == nil || in.ToolUseID == "" {
		return
	}
	u := a.uses[in.ToolUseID]
	if u == nil {
		// Hooks can precede the stream's tool_use frame; record from the
		// hook's own input.
		u = &toolUse{name: in.ToolName}
		var ti map[string]any
		_ = json.Unmarshal(in.ToolInput, &ti)
		if field, ok := fileTools[in.ToolName]; ok {
			u.path, _ = ti[field].(string)
		}
		if in.ToolName == "Bash" {
			u.command, _ = ti["command"].(string)
		}
		a.uses[in.ToolUseID] = u
	}
	_, isFile := fileTools[in.ToolName]
	switch {
	case name == "PostToolUseFailure" && isFile:
		a.fileResult(in.ToolUseID, u, nil, true, in.AgentID, "hook")
	case name == "PostToolUse" && isFile:
		a.fileResult(in.ToolUseID, u, in.ToolResponse, false, in.AgentID, "hook")
	case name == "PostToolUse" && in.ToolName == "Bash":
		a.bashResult(in.ToolUseID, in.ToolResponse, "hook")
	}
}

// fileResult settles one native file tool call from the first source that
// reports it (hook or tool result).
func (a *accumulator) fileResult(id string, u *toolUse, structured json.RawMessage, isError bool, agentID, source string) {
	var out fileToolOutput
	hasOut := len(structured) > 0 && structured[0] == '{' && json.Unmarshal(structured, &out) == nil
	if prev, ok := a.fileDone[id]; ok {
		if !strings.Contains(prev, source) {
			a.fileDone[id] = prev + "+" + source
		}
		// A later structured result refines an earlier unstructured one.
		if !hasOut || isError || a.fileTyped[id] {
			return
		}
	}
	if _, ok := a.fileDone[id]; !ok {
		a.fileDone[id] = source
	}
	a.fileTyped[id] = hasOut
	path := u.path
	if hasOut && out.FilePath != "" {
		path = out.FilePath
	} else if hasOut && out.NotebookPath != "" {
		path = out.NotebookPath
	}
	rel, inside := a.rel(path)
	if isError {
		a.failedEdits = append(a.failedEdits, map[string]any{"tool": u.name, "path": rel})
		return
	}
	if hasOut && out.Staged {
		a.stagedEdits = append(a.stagedEdits, rel)
		return
	}
	kind := core.Changed
	switch {
	case !hasOut:
	case out.Type == "create":
		kind = core.Added
	case out.Type == "update":
		kind = core.Modified
	case u.name == "Edit" || u.name == "MultiEdit":
		kind = core.Modified
		if (out.OldString != nil && *out.OldString == "" && string(out.OriginalFile) == "null") || (out.GitDiff != nil && out.GitDiff.Status == "added") {
			kind = core.Added
		}
	case u.name == "NotebookEdit":
		kind = core.Modified
	}
	if u.parent != "" || agentID != "" {
		a.subagentEdits = append(a.subagentEdits, map[string]any{"tool": u.name, "path": rel, "kind": kind, "parentToolUseId": u.parent, "agentId": agentID})
	}
	if inside {
		a.obs = append(a.obs, observation{rel, kind})
	}
}

// bashResult records one Bash call's bashEditDiff (paths and flags only).
func (a *accumulator) bashResult(id string, resp json.RawMessage, source string) {
	if d, ok := a.bashDone[id]; ok {
		if src, _ := d["source"].(string); !strings.Contains(src, source) {
			d["source"] = src + "+" + source
		}
		if d["present"] == true {
			return
		}
	}
	var r struct {
		BashEditDiff *bashEditDiff `json:"bashEditDiff"`
	}
	if len(resp) > 0 && resp[0] == '{' {
		_ = json.Unmarshal(resp, &r)
	}
	d, seen := a.bashDone[id]
	if !seen {
		d = map[string]any{"toolUseId": id, "source": source, "present": false}
		if u := a.uses[id]; u != nil {
			d["command"] = clip(u.command, 160)
		}
		a.bashDone[id] = d
		a.bashOrder = append(a.bashOrder, id)
	}
	diff := r.BashEditDiff
	if diff == nil {
		return
	}
	d["present"] = true
	files := []map[string]any{}
	for _, f := range diff.Files {
		rel, inside := a.rel(f.FilePath)
		files = append(files, map[string]any{"path": rel, "created": f.Created, "deleted": f.Deleted, "hunks": len(f.Hunks)})
		kind := core.Changed
		switch {
		case f.Created:
			kind = core.Added
		case f.Deleted:
			kind = core.Deleted
		case len(f.Hunks) > 0:
			kind = core.Modified
		}
		if inside {
			a.obs = append(a.obs, observation{rel, kind})
		}
	}
	changed := []string{}
	for _, p := range diff.ChangedFiles {
		rel, inside := a.rel(p)
		changed = append(changed, rel)
		if inside {
			a.obs = append(a.obs, observation{rel, core.Changed})
		}
	}
	d["files"] = files
	d["changedFiles"] = changed
	d["moreFiles"] = diff.MoreFiles
	d["unavailable"] = diff.Unavailable
	d["skipped"] = diff.Skipped
	d["shared"] = diff.Shared
}

func (a *accumulator) rel(p string) (string, bool) {
	rel, ok := relPath(a.roots, p)
	if !ok && p != "" {
		a.outside[p] = true
	}
	return rel, ok
}

// finish folds the observations in stream order into res.
func (a *accumulator) finish(res *core.TurnResult) {
	var netZero []string
	for _, o := range a.obs {
		merge(res.Reported, o.path, o.kind, &netZero)
	}
	for k, v := range a.info {
		res.Detail[k] = v
	}
	res.Detail["sessionId"] = a.sessionID
	res.Detail["toolCalls"] = a.toolCalls
	res.Detail["bashCalls"] = a.bashCalls
	bash := make([]map[string]any, 0, len(a.bashOrder))
	withDiff := 0
	for _, id := range a.bashOrder {
		bash = append(bash, a.bashDone[id])
		if a.bashDone[id]["present"] == true {
			withDiff++
		}
	}
	res.Detail["bashEditDiff"] = bash
	res.Detail["bashEditDiffPresent"] = withDiff
	sources := map[string]int{}
	for _, s := range a.fileDone {
		sources[s]++
	}
	res.Detail["fileToolSources"] = sources
	res.Detail["subagentEdits"] = nonNil(a.subagentEdits)
	if len(a.failedEdits) > 0 {
		res.Detail["failedEdits"] = a.failedEdits
	}
	if len(a.stagedEdits) > 0 {
		res.Detail["stagedEdits"] = a.stagedEdits
	}
	if len(netZero) > 0 {
		res.Detail["netZero"] = netZero
	}
	if len(a.outside) > 0 {
		var out []string
		for p := range a.outside {
			out = append(out, p)
		}
		sort.Strings(out)
		res.Detail["outsidePaths"] = out
	}
	if len(a.assistantErrs) > 0 {
		res.Detail["assistantErrors"] = a.assistantErrs
	}
	if a.replayed > 0 {
		res.Detail["replayedMessages"] = a.replayed
	}
	if a.unparsed > 0 {
		res.Detail["unparsedLines"] = a.unparsed
	}
}

// merge folds one observation into the turn's change set: specific kinds beat
// Changed, a file created in the turn stays Added, and created-then-deleted
// cancels out.
func merge(cs core.ChangeSet, path string, kind core.ChangeKind, netZero *[]string) {
	path = core.NormPath(path)
	if path == "" {
		return
	}
	old, ok := cs[path]
	switch {
	case !ok:
		cs.Add(path, kind, false)
	case kind == core.Changed:
	case old.Kind == core.Added && kind == core.Deleted:
		delete(cs, path)
		*netZero = append(*netZero, path)
	case old.Kind == core.Added:
	case old.Kind == core.Deleted && kind == core.Added:
		cs.Add(path, core.Modified, false)
	default:
		cs.Add(path, kind, false)
	}
}

// rootsOf returns the spellings of dir that Claude may report paths under:
// the absolute path and its symlink-resolved form.
func rootsOf(dir string) []string {
	abs, err := filepath.Abs(dir)
	if err != nil {
		abs = dir
	}
	roots := []string{filepath.Clean(abs)}
	if real, err := filepath.EvalSymlinks(abs); err == nil && real != roots[0] {
		roots = append(roots, real)
	}
	return roots
}

// relPath maps a reported path to a root-relative key. Relative paths are
// taken as relative to the working directory. Only the parent directory is
// resolved, so a symlink inside the tree keeps its own path.
func relPath(roots []string, p string) (string, bool) {
	if p == "" {
		return "", false
	}
	if !filepath.IsAbs(p) {
		c := filepath.Clean(p)
		if c == "." || c == ".." || strings.HasPrefix(c, "../") {
			return core.NormPath(p), false
		}
		return core.NormPath(c), true
	}
	cands := []string{filepath.Clean(p)}
	if rp := realParent(p); rp != cands[0] {
		cands = append(cands, rp)
	}
	for _, c := range cands {
		for _, r := range roots {
			rel, err := filepath.Rel(r, c)
			if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, "../") {
				continue
			}
			return core.NormPath(rel), true
		}
	}
	return core.NormPath(p), false
}

func realParent(p string) string {
	dir, base := filepath.Split(filepath.Clean(p))
	dir = filepath.Clean(dir)
	var rest []string
	for {
		if real, err := filepath.EvalSymlinks(dir); err == nil {
			return filepath.Join(append(append([]string{real}, rest...), base)...)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return filepath.Clean(p)
		}
		rest = append([]string{filepath.Base(dir)}, rest...)
		dir = parent
	}
}

func blocks(m *sdkMessage) []contentBlock {
	if m == nil || len(m.Content) == 0 || m.Content[0] != '[' {
		return nil
	}
	var bs []contentBlock
	_ = json.Unmarshal(m.Content, &bs)
	return bs
}

func jsonString(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return string(raw)
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func nonNil(v []map[string]any) []map[string]any {
	if v == nil {
		return []map[string]any{}
	}
	return v
}

// lineWriter calls fn for each complete line written to it.
type lineWriter struct {
	buf []byte
	fn  func([]byte)
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		w.fn(w.buf[:i])
		w.buf = w.buf[i+1:]
	}
	if len(w.buf) == 0 {
		w.buf = nil
	}
	return len(p), nil
}

// Flush delivers a trailing line without a newline.
func (w *lineWriter) Flush() {
	if len(bytes.TrimSpace(w.buf)) > 0 {
		w.fn(w.buf)
	}
	w.buf = nil
}

// tailBuffer keeps the last max bytes written.
type tailBuffer struct {
	mu  sync.Mutex
	b   []byte
	max int
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.b = append(t.b, p...)
	if len(t.b) > t.max {
		t.b = append([]byte(nil), t.b[len(t.b)-t.max:]...)
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return string(t.b)
}

// eventLog appends JSONL to a file, scrubbing the access token from every
// line as a last line of defence.
type eventLog struct {
	f     *os.File
	token []byte
}

func newEventLog(path, token string) *eventLog {
	l := &eventLog{token: []byte(token)}
	if path == "" {
		return l
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err == nil {
		l.f, _ = os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	}
	return l
}

func (l *eventLog) WriteRaw(line []byte) {
	if l.f == nil {
		return
	}
	line = bytes.TrimRight(line, "\r\n")
	if len(l.token) > 0 && bytes.Contains(line, l.token) {
		line = bytes.ReplaceAll(line, l.token, []byte("[REDACTED]"))
	}
	out := make([]byte, 0, len(line)+1)
	l.f.Write(append(append(out, line...), '\n'))
}

func (l *eventLog) Write(v any) {
	b, err := json.Marshal(v)
	if err == nil {
		l.WriteRaw(b)
	}
}

func (l *eventLog) Close() {
	if l.f != nil {
		l.f.Close()
	}
}

func redact(s, token string) string {
	if token == "" {
		return s
	}
	return strings.ReplaceAll(s, token, "[REDACTED]")
}
