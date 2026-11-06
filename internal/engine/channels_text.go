package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
)

// Token budget of what a model sees (docs/proposals/agent-messaging.md §4.6):
// inline bodies up to 1 KiB, at most 8 messages and 4 KiB per steer frame, a
// digest of at most 8 headers and 2 KiB.
const (
	channelNoticeMessages = 8
	channelNoticeBytes    = 4096
	channelInlineBytes    = 1024
	channelDigestHeaders  = 8
	channelDigestBytes    = 2048
	channelDigestPreview  = 240
)

var attributeUnsafe = strings.NewReplacer(`"`, "", "'", "", "<", "", ">", "", "\n", " ", "\r", " ")

func channelAttribute(value string) string {
	value = strings.TrimSpace(attributeUnsafe.Replace(value))
	if len(value) > 120 {
		value = value[:120]
	}
	return value
}

func channelSender(author model.ChannelAuthor) string {
	switch author.Kind {
	case model.ChannelAuthorAgent:
		return fmt.Sprintf("agent %s '%s'", author.CardID, channelAttribute(author.Title))
	case model.ChannelAuthorDieter:
		return "dieter"
	}
	return "human"
}

// renderChannelNotice is the steer text of a batch: each message inline up to
// channelInlineBytes, the batch bounded by channelNoticeBytes.
func renderChannelNotice(projectName string, messages []model.ChannelMessage) string {
	var builder strings.Builder
	for _, message := range messages {
		body := message.Body
		if len(body) > channelInlineBytes {
			body = truncateUTF8(body, channelInlineBytes) + " … (truncated; read it with dieter channel inbox)"
		}
		attributes := fmt.Sprintf(`id="%s" channel="#%s" from="%s" kind="%s"`, message.ID, channelAttribute(projectName), channelSender(message.Author), message.Kind)
		if message.ThreadID != "" {
			attributes += fmt.Sprintf(` thread="%s"`, message.ThreadID)
		}
		if len(message.To) > 0 {
			attributes += ` to="you"`
		}
		if len(message.Files) > 0 {
			attributes += fmt.Sprintf(` files="%s"`, channelAttribute(strings.Join(message.Files, ",")))
		}
		block := fmt.Sprintf("<dieter-channel-message %s>\n%s\n</dieter-channel-message>\n", attributes, body)
		if builder.Len() > 0 && builder.Len()+len(block) > channelNoticeBytes {
			break
		}
		builder.WriteString(block)
	}
	return strings.TrimSpace(builder.String())
}

// renderChannelDigest summarises undelivered messages for the next prompt.
func renderChannelDigest(projectName string, messages []model.ChannelMessage) string {
	var builder strings.Builder
	fmt.Fprintf(&builder, "<dieter-channel-digest channel=\"#%s\" unread=\"%d\">\n", channelAttribute(projectName), len(messages))
	shown := 0
	for _, message := range messages {
		if shown == channelDigestHeaders {
			break
		}
		body := strings.Join(strings.Fields(message.Body), " ")
		if len(body) > channelDigestPreview {
			body = truncateUTF8(body, channelDigestPreview) + "…"
		}
		line := fmt.Sprintf("%s from %s (%s): %s\n", message.ID, channelSender(message.Author), message.Kind, body)
		if shown > 0 && builder.Len()+len(line) > channelDigestBytes {
			break
		}
		builder.WriteString(line)
		shown++
	}
	if rest := len(messages) - shown; rest > 0 {
		fmt.Fprintf(&builder, "… %d more. Read them with: dieter channel inbox\n", rest)
	}
	builder.WriteString("</dieter-channel-digest>")
	return builder.String()
}

func truncateUTF8(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	for limit > 0 && limit < len(value) && value[limit]&0xC0 == 0x80 {
		limit--
	}
	return value[:limit]
}

// peerNoticePart is the transcript part of a message steered into a turn.
func peerNoticePart(projectName string, message model.ChannelMessage) model.UIMessagePart {
	data, _ := json.Marshal(struct {
		MessageID string              `json:"messageId"`
		ProjectID string              `json:"projectId"`
		Channel   string              `json:"channel"`
		Kind      string              `json:"kind"`
		ThreadID  string              `json:"threadId,omitempty"`
		Author    model.ChannelAuthor `json:"author"`
		Direct    bool                `json:"direct,omitempty"`
		Files     []string            `json:"files,omitempty"`
		CreatedAt string              `json:"createdAt"`
	}{message.ID, message.ProjectID, projectName, message.Kind, message.ThreadID, message.Author, len(message.To) > 0, message.Files, message.CreatedAt})
	return model.UIMessagePart{Text: message.Body, Data: data}
}

var (
	// Shell writes: in-place editors, redirections, file moves, git commands
	// that touch the worktree or stage files, and scripted writes (python,
	// node, ruby heredocs and one-liners).
	mutatingCommand = regexp.MustCompile(`(^|[;&|(\s])(sed\s+-i|perl\s+-[a-z]*i|tee\b|mv\s|cp\s|rm\s|truncate\b|touch\s|git\s+(add|rm|mv|checkout|restore|apply))|>>?\s*[^\s&|>]|write_text\(|write_bytes\(|writeFile(Sync)?\(|\.write\(|open\([^)]*['"][wax]\+?['"]|File\.write|IO\.write`)
	gitCommit       = regexp.MustCompile(`(^|[;&|(\s])git\s+(-C\s+\S+\s+)?commit\b`)
	gitCommitAll    = regexp.MustCompile(`(^|\s)(-a|--all|-[a-zA-Z]*a[a-zA-Z]*)(\s|$)`)
	// Index-only git commands change no worktree file.
	indexOnlyGit = regexp.MustCompile(`git\s+(restore|rm)\b[^;&|]*--(staged|cached)[^;&|]*|git\s+reset\b(\s+(--soft|--mixed|-q|--quiet|HEAD\S*|--))*\s*($|[;&|])`)
	pathToken    = regexp.MustCompile(`[A-Za-z0-9_./@+-]*[A-Za-z0-9_@+-]\.[A-Za-z0-9_+-]+|[A-Za-z0-9_./@+-]+/[A-Za-z0-9_.@+-]+`)
	patchFile    = regexp.MustCompile(`(?m)^\*\*\* (?:Add|Update|Delete) File: (.+)$|^\*\*\* Move to: (.+)$`)
)

// channelWritePaths returns the workspace-relative paths a tool call is
// about to change (hook input) or changed (observed stream). Edit-style tools
// name their file; apply_patch names files in its headers; shell commands are
// a heuristic: a mutating command and path-like tokens that exist (or whose
// directory exists) in the workspace.
func channelWritePaths(toolName string, input json.RawMessage, workspace string) []string {
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(input, &fields)
	text := func(name string) string {
		var value string
		_ = json.Unmarshal(fields[name], &value)
		return value
	}
	var candidates []string
	switch strings.ToLower(toolName) {
	case "edit", "write", "multiedit", "notebookedit", "str_replace_based_edit_tool":
		candidates = append(candidates, text("file_path"), text("notebook_path"), text("path"))
	case "filechange":
		candidates = append(candidates, text("path"))
	case "apply_patch", "applypatch":
		patch := text("command")
		if patch == "" {
			patch = text("input")
		}
		if patch == "" {
			patch = string(input)
		}
		for _, match := range patchFile.FindAllStringSubmatch(patch, -1) {
			candidates = append(candidates, match[1], match[2])
		}
	case "bash", "shell", "exec_command", "local_shell", "exec":
		command := text("command")
		if command == "" {
			command = text("cmd")
		}
		if command == "" {
			command = string(input)
		}
		if strings.Contains(command, "*** Begin Patch") {
			for _, match := range patchFile.FindAllStringSubmatch(command, -1) {
				candidates = append(candidates, match[1], match[2])
			}
			break
		}
		command = indexOnlyGit.ReplaceAllString(command, " ")
		if !mutatingCommand.MatchString(command) {
			return nil
		}
		for _, token := range pathToken.FindAllString(command, -1) {
			if path, ok := workspacePath(workspace, token); ok && pathOrParentExists(workspace, path) {
				candidates = append(candidates, token)
			}
		}
	default:
		return nil
	}
	seen := map[string]bool{}
	var paths []string
	for _, candidate := range candidates {
		path, ok := workspacePath(workspace, candidate)
		if !ok || seen[path] {
			continue
		}
		seen[path] = true
		paths = append(paths, path)
		if len(paths) == 64 {
			break
		}
	}
	return paths
}

// workspacePath maps an absolute or relative path to a clean path relative to
// workspace; paths outside it are rejected.
func workspacePath(workspace, candidate string) (string, bool) {
	candidate = strings.TrimSpace(strings.Trim(candidate, `"'`))
	if candidate == "" || workspace == "" {
		return "", false
	}
	if filepath.IsAbs(candidate) {
		for _, root := range workspaceRoots(workspace) {
			if rel, err := filepath.Rel(root, candidate); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
				return filepath.ToSlash(rel), true
			}
		}
		return "", false
	}
	clean := filepath.Clean(candidate)
	if clean == "." || strings.HasPrefix(clean, "..") || filepath.IsAbs(clean) {
		return "", false
	}
	return filepath.ToSlash(clean), true
}

// workspaceRoots are the spellings of a workspace path: as given and with
// symlinks resolved (macOS reports /var as /private/var).
func workspaceRoots(workspace string) []string {
	roots := []string{filepath.Clean(workspace)}
	if resolved, err := filepath.EvalSymlinks(workspace); err == nil && resolved != roots[0] {
		roots = append(roots, resolved)
	}
	return roots
}

func pathOrParentExists(workspace, rel string) bool {
	if _, err := os.Stat(filepath.Join(workspace, rel)); err == nil {
		return true
	}
	parent := filepath.Dir(rel)
	if parent == "." {
		return false
	}
	info, err := os.Stat(filepath.Join(workspace, parent))
	return err == nil && info.IsDir()
}
