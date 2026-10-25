package model

import (
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// Agent mail: one-way Markdown reports for the account's user. Messages stay
// on the daemon that received them, with their read, flag and folder state;
// nothing is replicated. Mail never reaches a prompt or starts a turn.

// Mail folders. Flagged and Unread are views over them.
const (
	MailFolderInbox   = "inbox"
	MailFolderArchive = "archive"
	MailFolderTrash   = "trash"
)

// Mail importance.
const (
	MailImportanceNormal = "normal"
	MailImportanceHigh   = "high"
)

// Mail sender kinds.
const (
	MailSenderAgent    = "agent"
	MailSenderOperator = "operator"
)

// Mail bounds. The body limits keep every client renderer out of its
// source-only fallback.
const (
	MailMaxSubjectRunes = 200
	MailMaxBodyBytes    = 128 << 10
	MailMaxBodyLines    = 4000
	MailMaxLineBytes    = 8 << 10
	MailMaxPreviewRunes = 200
	MailMaxOperationID  = 128
	MailMaxFromRunes    = 64
	// Rate bounds, counted from the stored messages so they survive restarts.
	MailMaxPerTurn         = 10
	MailMaxPerConversation = 50
	MailConversationWindow = 24 * time.Hour
	// Store bounds of one daemon; see store/mail for the pruning order.
	MailMaxMessages     = 2000
	MailMaxStoredBodies = 128 << 20
	MailTrashRetention  = 30 * 24 * time.Hour
	MailMaxIDsPerCall   = 500
	MailDefaultPageSize = 50
	MailMaxPageSize     = 500
)

// MailSender is who sent a message, as it was when sent: it stays readable
// after its conversation is renamed, archived or deleted.
type MailSender struct {
	Kind         string `json:"kind"`
	CardID       string `json:"cardId,omitempty"`
	TurnID       string `json:"turnId,omitempty"`
	Scope        string `json:"scope,omitempty"`
	Title        string `json:"title,omitempty"`
	ProjectID    string `json:"projectId,omitempty"`
	ProjectName  string `json:"projectName,omitempty"`
	CheckoutID   string `json:"checkoutId,omitempty"`
	ScheduleID   string `json:"scheduleId,omitempty"`
	ScheduleName string `json:"scheduleName,omitempty"`
	Harness      string `json:"harness,omitempty"`
	Model        string `json:"model,omitempty"`
	DeviceID     string `json:"deviceId,omitempty"`
	Label        string `json:"label,omitempty"`
}

// MailHeader is a message without its body: what lists and change streams
// carry.
type MailHeader struct {
	ID             string     `json:"id"`
	Sender         MailSender `json:"sender"`
	Subject        string     `json:"subject"`
	Preview        string     `json:"preview"`
	Importance     string     `json:"importance"`
	SentAt         string     `json:"sentAt"`
	BodyBytes      int        `json:"bodyBytes"`
	BodyDigest     string     `json:"bodyDigest"`
	Read           bool       `json:"read,omitempty"`
	Flagged        bool       `json:"flagged,omitempty"`
	Folder         string     `json:"folder"`
	StateChangedAt string     `json:"stateChangedAt,omitempty"`
}

// ValidMailFolder reports whether folder is Inbox, Archive or Trash.
func ValidMailFolder(folder string) bool {
	return folder == MailFolderInbox || folder == MailFolderArchive || folder == MailFolderTrash
}

// NormalizeMailSubject returns subject on one line (mailLine) with 1 to
// MailMaxSubjectRunes characters.
func NormalizeMailSubject(subject string) (string, error) {
	if !utf8.ValidString(subject) {
		return "", fault.New(fault.Invalid, "the subject is not valid UTF-8")
	}
	if subject = mailLine(subject); subject == "" {
		return "", fault.New(fault.Invalid, "a subject is required")
	}
	if utf8.RuneCountInString(subject) > MailMaxSubjectRunes {
		return "", fault.Invalidf("the subject is longer than %d characters", MailMaxSubjectRunes)
	}
	return subject, nil
}

// mailLine puts text on one line: line breaks, tabs and runs of spaces
// collapse to one space, other control and bidirectional formatting
// characters are removed, and the ends are trimmed.
func mailLine(text string) string {
	return strings.Join(strings.Fields(strings.Map(func(r rune) rune {
		switch {
		case unicode.IsSpace(r):
			return ' '
		case unicode.IsControl(r), bidiControl(r):
			return -1
		}
		return r
	}, text)), " ")
}

func bidiControl(r rune) bool {
	return r >= 0x202A && r <= 0x202E || r >= 0x2066 && r <= 0x2069 || r == 0x200E || r == 0x200F
}

// NormalizeMailBody returns body with CRLF line ends as LF after checking the
// limits: valid UTF-8, not blank, at most MailMaxBodyBytes,
// MailMaxBodyLines lines and MailMaxLineBytes per line.
func NormalizeMailBody(body string) (string, error) {
	if !utf8.ValidString(body) {
		return "", fault.New(fault.Invalid, "the body is not valid UTF-8")
	}
	body = strings.ReplaceAll(body, "\r\n", "\n")
	if strings.TrimSpace(body) == "" {
		return "", fault.New(fault.Invalid, "a body is required")
	}
	if len(body) > MailMaxBodyBytes {
		return "", fault.Invalidf("the body is larger than %d KiB", MailMaxBodyBytes>>10)
	}
	lines := strings.Split(strings.TrimSuffix(body, "\n"), "\n")
	if len(lines) > MailMaxBodyLines {
		return "", fault.Invalidf("the body has more than %d lines", MailMaxBodyLines)
	}
	for index, line := range lines {
		if len(line) > MailMaxLineBytes {
			return "", fault.Invalidf("line %d of the body is longer than %d KiB", index+1, MailMaxLineBytes>>10)
		}
	}
	return body, nil
}

// NormalizeMailFrom returns an operator's --from label on one line
// (mailLine), at most MailMaxFromRunes characters; it may be empty.
func NormalizeMailFrom(from string) (string, error) {
	if !utf8.ValidString(from) {
		return "", fault.New(fault.Invalid, "the from label is not valid UTF-8")
	}
	if from = mailLine(from); utf8.RuneCountInString(from) > MailMaxFromRunes {
		return "", fault.Invalidf("the from label is longer than %d characters", MailMaxFromRunes)
	}
	return from, nil
}

// ValidateMailOperationID checks a send's retry key.
func ValidateMailOperationID(id string) error {
	if len(id) > MailMaxOperationID || !utf8.ValidString(id) || strings.ContainsFunc(id, unicode.IsControl) {
		return fault.Invalidf("the operation ID must be at most %d characters of text", MailMaxOperationID)
	}
	return nil
}

var (
	mailFence       = regexp.MustCompile("^ {0,3}(```|~~~)")
	mailHeading     = regexp.MustCompile(`^ {0,3}#{1,6}(\s|$)`)
	mailRule        = regexp.MustCompile(`^ {0,3}([-*_])(\s*([-*_])){2,}\s*$`)
	mailSetext      = regexp.MustCompile(`^ {0,3}(=+|-+)\s*$`)
	mailListItem    = regexp.MustCompile(`^\s*([-*+]|\d{1,9}[.)])\s+(\[[ xX]\]\s+)?`)
	mailQuote       = regexp.MustCompile(`^\s*(>\s?)+`)
	mailTableDelim  = regexp.MustCompile(`^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$`)
	mailLink        = regexp.MustCompile(`!?\[([^\]]*)\]\([^)]*\)`)
	mailRefLink     = regexp.MustCompile(`!?\[([^\]]*)\]\[[^\]]*\]`)
	mailAutolink    = regexp.MustCompile(`<((?:https?|mailto):[^>\s]+)>`)
	mailHTMLTag     = regexp.MustCompile(`</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>`)
	mailStrongEmph  = regexp.MustCompile(`(\*\*|__|~~)`)
	mailSingleEmph  = regexp.MustCompile(`(^|[^\w*])[*_]([^*_\s][^*_]*?)[*_]($|[^\w*])`)
	mailBackslashed = regexp.MustCompile(`\\([!-/:-@\[-` + "`" + `{-~])`)
)

// MailPreview is the plain text a list row shows for body: the first
// paragraph, list item or table header with Markdown syntax removed, on one
// line and at most MailMaxPreviewRunes characters. Headings, rules and code
// blocks are skipped.
func MailPreview(body string) string {
	lines := strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n")
	var paragraph []string
	fence := ""
	for index, line := range lines {
		if match := mailFence.FindStringSubmatch(line); match != nil {
			if len(paragraph) > 0 {
				break
			}
			switch fence {
			case "":
				fence = match[1]
			case match[1]:
				fence = ""
			}
			continue
		}
		if fence != "" {
			continue
		}
		line = mailQuote.ReplaceAllString(line, "")
		trimmed := strings.TrimSpace(line)
		switch {
		case len(paragraph) > 0 && mailSetext.MatchString(line):
			// The paragraph was a setext heading.
			paragraph = nil
			continue
		case trimmed == "" || mailHeading.MatchString(line) || mailRule.MatchString(line):
			if len(paragraph) > 0 {
				return mailPreviewText(strings.Join(paragraph, " "))
			}
			continue
		case strings.Contains(trimmed, "|") && index+1 < len(lines) && mailTableDelim.MatchString(lines[index+1]) && strings.Contains(lines[index+1], "|"):
			if len(paragraph) > 0 {
				return mailPreviewText(strings.Join(paragraph, " "))
			}
			var cells []string
			for _, cell := range splitMailTableRow(trimmed) {
				if cell = strings.TrimSpace(cell); cell != "" {
					cells = append(cells, cell)
				}
			}
			return mailPreviewText(strings.Join(cells, " · "))
		case mailListItem.MatchString(line):
			if len(paragraph) > 0 {
				return mailPreviewText(strings.Join(paragraph, " "))
			}
			return mailPreviewText(mailListItem.ReplaceAllString(line, ""))
		}
		paragraph = append(paragraph, trimmed)
	}
	return mailPreviewText(strings.Join(paragraph, " "))
}

// splitMailTableRow splits a table row at unescaped pipes outside code spans.
func splitMailTableRow(row string) []string {
	row = strings.TrimSuffix(strings.TrimPrefix(row, "|"), "|")
	var cells []string
	var cell strings.Builder
	code := false
	for index := 0; index < len(row); index++ {
		switch character := row[index]; {
		case character == '\\' && index+1 < len(row) && row[index+1] == '|':
			cell.WriteByte('|')
			index++
		case character == '`':
			code = !code
			cell.WriteByte(character)
		case character == '|' && !code:
			cells = append(cells, cell.String())
			cell.Reset()
		default:
			cell.WriteByte(character)
		}
	}
	return append(cells, cell.String())
}

// mailPreviewText strips inline Markdown outside code spans and bounds the
// result.
func mailPreviewText(text string) string {
	var result strings.Builder
	for text != "" {
		start := strings.IndexByte(text, '`')
		if start < 0 {
			result.WriteString(stripMailInline(text))
			break
		}
		run := len(text[start:]) - len(strings.TrimLeft(text[start:], "`"))
		closing := strings.Index(text[start+run:], strings.Repeat("`", run))
		if closing < 0 {
			result.WriteString(stripMailInline(text))
			break
		}
		result.WriteString(stripMailInline(text[:start]))
		result.WriteString(strings.TrimSpace(text[start+run : start+run+closing]))
		text = text[start+run+closing+run:]
	}
	preview := strings.Join(strings.Fields(result.String()), " ")
	if utf8.RuneCountInString(preview) <= MailMaxPreviewRunes {
		return preview
	}
	runes := []rune(preview)
	return strings.TrimRightFunc(string(runes[:MailMaxPreviewRunes-1]), unicode.IsSpace) + "…"
}

// stripMailInline removes inline syntax. Escaped punctuation is hidden in the
// private use area meanwhile, so it is never taken for syntax.
func stripMailInline(text string) string {
	text = mailBackslashed.ReplaceAllStringFunc(text, func(escape string) string { return string(rune(0xE000 + int(escape[1]))) })
	text = mailLink.ReplaceAllString(text, "$1")
	text = mailRefLink.ReplaceAllString(text, "$1")
	text = mailAutolink.ReplaceAllString(text, "$1")
	text = mailHTMLTag.ReplaceAllString(text, "")
	text = mailStrongEmph.ReplaceAllString(text, "")
	for {
		next := mailSingleEmph.ReplaceAllString(text, "$1$2$3")
		if next == text {
			break
		}
		text = next
	}
	return strings.Map(func(r rune) rune {
		if r >= 0xE000 && r < 0xE080 {
			return r - 0xE000
		}
		return r
	}, text)
}
