// Package memory holds the rules of Dieter's agent memory that do not depend
// on storage: which parts of a conversation become indexed observations, how
// text is scrubbed before indexing, how a recall query becomes a full-text
// query, how close two memories are, and how a dream's changes are checked.
// The machine-local index is internal/store/memory; saved memories replicate
// as KV records (internal/replication/schema/memory.go).
package memory

import (
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/model"
)

// Index field bounds.
const (
	MaxBodyBytes   = 4 << 10
	MaxAnswerBytes = 8 << 10
	MaxTitleBytes  = 200
	maxInputBytes  = 1500
	maxOutputBytes = 2400
	maxFilePath    = 512
	maxDigestFiles = 50
	maxDigestCmds  = 20
)

// Observation kinds. Tool observations are typed from the tool name, the way
// agentmemory's synthetic compression types them.
const (
	KindPrompt    = "prompt"
	KindAnswer    = "answer"
	KindError     = "error"
	KindFileRead  = "file_read"
	KindFileEdit  = "file_edit"
	KindFileWrite = "file_write"
	KindCommand   = "command_run"
	KindSearch    = "search"
	KindWebFetch  = "web_fetch"
	KindSubagent  = "subagent"
	KindTool      = "tool"
)

// Observation is one indexed piece of a conversation.
type Observation struct {
	MessageID string
	Part      int
	Kind      string
	Tool      string
	Files     []string
	Body      string
}

// Digest is the one-row summary of a conversation: its brief, final answer,
// files it touched, commands it ran and how many tool calls failed. It stands
// in for an LLM-written session summary.
type Digest struct {
	Brief       string
	FinalAnswer string
	Files       []string
	Commands    []string
	Failures    int
}

// hostTools are Dieter's own tools: their calls are not indexed. Recalled
// memory in particular must never be indexed again as new knowledge.
var hostTools = map[string]bool{
	"present_content": true, "start_background_process": true, "list_background_processes": true,
	"read_background_process": true, "stop_background_process": true, "request_code_review": true,
	"memory_recall": true, "memory_save": true, "memory_apply": true, "board_task_plan": true,
}

// HostTool reports whether name is one of Dieter's host tools, also under an
// MCP server prefix (Claude Code names them mcp__harness-tools__NAME).
func HostTool(name string) bool {
	name = strings.TrimSpace(name)
	if index := strings.LastIndex(name, "__"); index >= 0 && strings.HasPrefix(name, "mcp__") {
		name = name[index+2:]
	}
	return hostTools[name]
}

// Observations maps a conversation's messages onto observations: user text,
// tool results and failures, and the final text of each assistant reply.
// Reasoning, data parts (such as agent channel notices) and Dieter's host
// tools are never indexed.
func Observations(messages []model.UIMessage) []Observation {
	var out []Observation
	for _, message := range messages {
		switch message.Role {
		case "user":
			var texts []string
			for _, part := range message.Parts {
				if part.Type == "text" && strings.TrimSpace(part.Text) != "" {
					texts = append(texts, part.Text)
				}
			}
			if len(texts) > 0 {
				out = append(out, Observation{MessageID: message.ID, Part: -1, Kind: KindPrompt, Body: Clip(Scrub(strings.Join(texts, "\n")), MaxBodyBytes)})
			}
		case "assistant":
			last, lastIndex := "", -1
			for index, part := range message.Parts {
				if part.Type == "text" && strings.TrimSpace(part.Text) != "" {
					last, lastIndex = part.Text, index
				}
				if !toolPart(part) {
					continue
				}
				name := toolName(part)
				if HostTool(name) {
					continue
				}
				input := payloadText(part.Input)
				var observation Observation
				switch part.State {
				case "output-error":
					observation = Observation{Kind: KindError, Body: name + " " + Clip(input, maxInputBytes) + "\n" + Clip(part.ErrorText, maxOutputBytes)}
				case "output-available":
					observation = Observation{Kind: ToolKind(name), Body: name + " " + Clip(input, maxInputBytes) + "\n" + Clip(payloadText(part.Output), maxOutputBytes)}
				default:
					continue
				}
				observation.MessageID, observation.Part, observation.Tool = message.ID, index, name
				observation.Files = Files(name, part.Input)
				observation.Body = Clip(Scrub(observation.Body), MaxBodyBytes)
				out = append(out, observation)
			}
			if lastIndex >= 0 {
				out = append(out, Observation{MessageID: message.ID, Part: lastIndex, Kind: KindAnswer, Body: Clip(Scrub(last), MaxAnswerBytes)})
			}
		}
	}
	return out
}

// Summarize builds a conversation's digest from its brief and observations.
func Summarize(brief string, observations []Observation) Digest {
	digest := Digest{Brief: Clip(Scrub(strings.TrimSpace(brief)), MaxBodyBytes)}
	files := map[string]bool{}
	for _, observation := range observations {
		switch observation.Kind {
		case KindAnswer:
			digest.FinalAnswer = observation.Body
		case KindError:
			digest.Failures++
		case KindCommand:
			if len(digest.Commands) < maxDigestCmds {
				command := strings.TrimSpace(strings.SplitN(observation.Body, "\n", 2)[0])
				digest.Commands = append(digest.Commands, Clip(command, 200))
			}
		}
		if observation.Kind == KindFileEdit || observation.Kind == KindFileWrite {
			for _, file := range observation.Files {
				if !files[file] && len(files) < maxDigestFiles {
					files[file] = true
					digest.Files = append(digest.Files, file)
				}
			}
		}
	}
	if digest.Brief == "" {
		for _, observation := range observations {
			if observation.Kind == KindPrompt {
				digest.Brief = observation.Body
				break
			}
		}
	}
	return digest
}

func toolPart(part model.UIMessagePart) bool {
	return part.Type == "dynamic-tool" || strings.HasPrefix(part.Type, "tool-")
}

func toolName(part model.UIMessagePart) string {
	if part.ToolName != "" {
		return part.ToolName
	}
	return strings.TrimPrefix(part.Type, "tool-")
}

// ToolKind types a tool observation from the tool's name.
func ToolKind(name string) string {
	words := toolWords(name)
	has := func(candidates ...string) bool {
		for _, word := range words {
			for _, candidate := range candidates {
				if word == candidate {
					return true
				}
			}
		}
		return false
	}
	switch {
	case has("fetch", "http", "web", "websearch", "webfetch", "browse"):
		return KindWebFetch
	case has("grep", "search", "glob", "find", "rg", "ls", "list"):
		return KindSearch
	case has("bash", "shell", "exec", "command", "run", "terminal", "sh"):
		return KindCommand
	case has("edit", "patch", "replace", "multiedit", "apply"):
		return KindFileEdit
	case has("write", "create", "save"):
		return KindFileWrite
	case has("read", "view", "cat", "open"):
		return KindFileRead
	case has("task", "agent", "subagent"):
		return KindSubagent
	}
	return KindTool
}

var camelBoundary = regexp.MustCompile(`([a-z0-9])([A-Z])`)

func toolWords(name string) []string {
	if index := strings.LastIndex(name, "__"); index >= 0 {
		name = name[index+2:]
	}
	name = camelBoundary.ReplaceAllString(name, "${1}_${2}")
	return strings.FieldsFunc(strings.ToLower(name), func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9')
	})
}

var patchFile = regexp.MustCompile(`\*\*\* (?:Update|Add|Delete) File: ([^\s"\\]+)`)

// Files extracts the file paths a tool call names: the common path keys of
// its input, and the files of an apply_patch body. Search tools' path is a
// search root, not a file, and is left out.
func Files(tool string, input json.RawMessage) []string {
	var out []string
	add := func(path string) {
		path = strings.TrimSpace(path)
		if path == "" || len(path) > maxFilePath || strings.ContainsAny(path, "\n\r\x00*") {
			return
		}
		for _, existing := range out {
			if existing == path {
				return
			}
		}
		out = append(out, path)
	}
	search := ToolKind(tool) == KindSearch
	var object map[string]any
	if json.Unmarshal(input, &object) == nil {
		for _, key := range []string{"file_path", "filePath", "filepath", "notebook_path", "path", "file"} {
			if search && (key == "path" || key == "file") {
				continue
			}
			if value, ok := object[key].(string); ok {
				add(value)
			}
		}
	}
	for _, match := range patchFile.FindAllStringSubmatch(string(input), 20) {
		add(match[1])
	}
	sort.Strings(out)
	return out
}

// payloadText renders a tool input or output: strings as they are, objects
// with their most telling fields first.
func payloadText(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	var object map[string]any
	if json.Unmarshal(raw, &object) == nil {
		for _, key := range []string{"command", "cmd", "output", "stdout", "content", "text", "result"} {
			if value, ok := object[key].(string); ok && strings.TrimSpace(value) != "" {
				rest := strings.TrimSpace(string(raw))
				if len(rest) > 400 {
					rest = ""
				}
				if rest != "" {
					return value + " " + rest
				}
				return value
			}
		}
	}
	return string(raw)
}

// Clip shortens s to at most limit bytes on a rune boundary, marking the cut.
func Clip(s string, limit int) string {
	if len(s) <= limit {
		return s
	}
	cut := limit - len("…")
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}
