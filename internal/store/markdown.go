package store

import (
	"bytes"
	"errors"
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

const markdownDelimiter = "---"

// Marshal writes conventional YAML frontmatter followed by a human-readable
// Markdown body. The stable shape keeps the files friendly to Git diffs.
func marshalMarkdown(meta any, body string) ([]byte, error) {
	front, err := yaml.Marshal(meta)
	if err != nil {
		return nil, fmt.Errorf("marshal frontmatter: %w", err)
	}
	body = strings.TrimSpace(strings.ReplaceAll(body, "\r\n", "\n"))
	var out bytes.Buffer
	out.WriteString(markdownDelimiter + "\n")
	out.Write(front)
	out.WriteString(markdownDelimiter + "\n")
	if body != "" {
		out.WriteString("\n")
		out.WriteString(body)
		out.WriteByte('\n')
	}
	return out.Bytes(), nil
}

func unmarshalMarkdown(data []byte, meta any) (string, error) {
	normalized := strings.ReplaceAll(string(data), "\r\n", "\n")
	if !strings.HasPrefix(normalized, markdownDelimiter+"\n") {
		return "", errors.New("missing YAML frontmatter")
	}
	rest := normalized[len(markdownDelimiter)+1:]
	idx := strings.Index(rest, "\n"+markdownDelimiter)
	if idx < 0 {
		return "", errors.New("unterminated YAML frontmatter")
	}
	if err := yaml.Unmarshal([]byte(rest[:idx]), meta); err != nil {
		return "", fmt.Errorf("parse frontmatter: %w", err)
	}
	body := rest[idx+len("\n"+markdownDelimiter):]
	body = strings.TrimPrefix(body, "\n")
	return strings.TrimSpace(body), nil
}
