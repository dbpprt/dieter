package model

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestMailPreviewIsPlainTextFromTheFirstBlock(t *testing.T) {
	t.Parallel()
	for name, test := range map[string]struct{ body, want string }{
		"paragraph after a heading": {
			"## Summary\n\nThree packages have **critical** advisories in `go.sum`;\nsee [README.md](README.md).\n\nMore.",
			"Three packages have critical advisories in go.sum; see README.md.",
		},
		"setext heading": {"Report\n======\n\n_Done_ at <https://example.com>.", "Done at https://example.com."},
		"list item":      {"# Steps\n\n- [x] **Upgrade** golang.org/x/net\n- [ ] Rotate keys", "Upgrade golang.org/x/net"},
		"ordered item":   {"1. First step\n2. Second", "First step"},
		"table header": {
			"| Package | Current | Fixed in |\n|:--|--:|--:|\n| x/net | 0.1 | 0.2 |",
			"Package · Current · Fixed in",
		},
		"code fence skipped": {"```sh\ngo test ./...\n```\n\nAll ~~red~~ green.", "All red green."},
		"quote":              {"> Quoted *line*\n> continues", "Quoted line continues"},
		"rule then text":     {"---\n\nAfter the rule.", "After the rule."},
		"snake case kept":    {"Renamed my_var_name and __init__ files.", "Renamed my_var_name and init files."},
		"escapes":            {`A \*literal\* star and a pipe \|.`, "A *literal* star and a pipe |."},
		"image alt":          {"![Chart](chart.png) shows growth.", "Chart shows growth."},
		"only a heading":     {"# Title", ""},
		"code with markers":  {"Run `a **b** c` now.", "Run a **b** c now."},
		"pipe in code cell":  {"| `a|b` | c |\n|---|---|\n| 1 | 2 |", "a|b · c"},
		"html tags dropped":  {"<details>Open</details> me", "Open me"},
	} {
		if got := MailPreview(test.body); got != test.want {
			t.Errorf("%s: MailPreview = %q, want %q", name, got, test.want)
		}
	}
	long := MailPreview(strings.Repeat("word ", 100))
	if utf8.RuneCountInString(long) != MailMaxPreviewRunes || !strings.HasSuffix(long, "…") {
		t.Fatalf("long preview (%d) = %q", utf8.RuneCountInString(long), long)
	}
}

func TestMailSubjectAndFromAreOneLine(t *testing.T) {
	t.Parallel()
	if got, err := NormalizeMailSubject(" Nightly\r\naudit\t\x07done \u202e"); err != nil || got != "Nightly audit done" {
		t.Fatalf("subject = %q, %v", got, err)
	}
	if got, err := NormalizeMailSubject(strings.Repeat("é", MailMaxSubjectRunes)); err != nil || utf8.RuneCountInString(got) != MailMaxSubjectRunes {
		t.Fatalf("subject at the limit = %v", err)
	}
	if got, err := NormalizeMailFrom(""); err != nil || got != "" {
		t.Fatalf("empty from = %q, %v", got, err)
	}
	if got, err := NormalizeMailFrom("backup.sh\n"); err != nil || got != "backup.sh" {
		t.Fatalf("from = %q, %v", got, err)
	}
	if _, err := NormalizeMailFrom(strings.Repeat("x", MailMaxFromRunes+1)); err == nil {
		t.Fatal("a long from label was accepted")
	}
	if err := ValidateMailOperationID("op\n1"); err == nil {
		t.Fatal("an operation ID with a line break was accepted")
	}
}
