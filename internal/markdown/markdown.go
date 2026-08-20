package markdown

import (
	"bytes"
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

const delimiter = "---"

// Marshal writes conventional YAML frontmatter followed by a human-readable
// Markdown body. The stable shape keeps the files friendly to Git diffs.
func Marshal(meta any, body string) ([]byte, error) {
	front, err := yaml.Marshal(meta)
	if err != nil {
		return nil, fmt.Errorf("marshal frontmatter: %w", err)
	}
	body = strings.TrimSpace(strings.ReplaceAll(body, "\r\n", "\n"))
	var out bytes.Buffer
	out.WriteString(delimiter + "\n")
	out.Write(front)
	out.WriteString(delimiter + "\n")
	if body != "" {
		out.WriteString("\n")
		out.WriteString(body)
		out.WriteByte('\n')
	}
	return out.Bytes(), nil
}

func Unmarshal(data []byte, meta any) (string, error) {
	normalized := strings.ReplaceAll(string(data), "\r\n", "\n")
	if !strings.HasPrefix(normalized, delimiter+"\n") {
		return "", fmt.Errorf("missing YAML frontmatter")
	}
	rest := normalized[len(delimiter)+1:]
	idx := strings.Index(rest, "\n"+delimiter)
	if idx < 0 {
		return "", fmt.Errorf("unterminated YAML frontmatter")
	}
	if err := yaml.Unmarshal([]byte(rest[:idx]), meta); err != nil {
		return "", fmt.Errorf("parse frontmatter: %w", err)
	}
	body := rest[idx+len("\n"+delimiter):]
	body = strings.TrimPrefix(body, "\n")
	return strings.TrimSpace(body), nil
}
