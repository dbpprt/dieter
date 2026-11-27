package reviewer

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/model"
)

// Finding text bounds.
const (
	maxTitleRunes      = 120
	maxBodyBytes       = 4 << 10
	maxSuggestionBytes = 4 << 10
	maxSummaryBytes    = 1 << 10
	maxSecurityBytes   = 2 << 10
)

// Answer is a parsed reviewer answer.
type Answer struct {
	Summary  string
	Security string
	Findings []model.CodeReviewFinding
	// Dropped counts findings left out: unknown files, low confidence or over
	// the limit.
	Dropped int
}

type answerJSON struct {
	Summary          string        `json:"summary"`
	Findings         []findingJSON `json:"findings"`
	SecurityConcerns any           `json:"security_concerns"`
}

type findingJSON struct {
	File       string `json:"file"`
	StartLine  any    `json:"start_line"`
	EndLine    any    `json:"end_line"`
	Severity   string `json:"severity"`
	Confidence any    `json:"confidence"`
	Title      string `json:"title"`
	Body       string `json:"body"`
	Suggestion string `json:"suggestion"`
}

var jsonFence = regexp.MustCompile("(?s)```(?:json)?[ \t]*\n(.*?)\n?```")

// ErrNoAnswer reports a reviewer reply without a readable JSON answer.
var ErrNoAnswer = errors.New("the reviewer's answer has no readable JSON review")

// Parse reads the reviewer's reply and validates its findings against the
// change: findings must name a changed file, lines are clamped to the file in
// the snapshot, and the confidence floor and finding limit apply.
func Parse(reply string, change Change, snapshotDir string, options Options) (Answer, error) {
	raw, err := extractJSON(reply)
	if err != nil {
		return Answer{}, err
	}
	var decoded answerJSON
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return Answer{}, fmt.Errorf("%w: %w", ErrNoAnswer, err)
	}
	answer := Answer{Summary: bound(decoded.Summary, maxSummaryBytes), Security: securityText(decoded.SecurityConcerns)}
	var findings []model.CodeReviewFinding
	for _, item := range decoded.Findings {
		file := cleanPath(item.File)
		if file == "" || !change.HasFile(file) {
			answer.Dropped++
			continue
		}
		finding := model.CodeReviewFinding{
			File: file, Severity: severity(item.Severity), Confidence: clampInt(number(item.Confidence), 0, 10),
			Title: boundRunes(oneLine(item.Title), maxTitleRunes), Body: bound(item.Body, maxBodyBytes),
			Suggestion: bound(item.Suggestion, maxSuggestionBytes),
		}
		if finding.Title == "" || strings.TrimSpace(finding.Body) == "" {
			answer.Dropped++
			continue
		}
		if numberGiven(item.Confidence) && finding.Confidence < options.MinConfidence {
			answer.Dropped++
			continue
		}
		finding.StartLine, finding.EndLine = lines(number(item.StartLine), number(item.EndLine), fileLines(snapshotDir, file))
		findings = append(findings, finding)
	}
	sort.SliceStable(findings, func(i, j int) bool {
		if rank(findings[i].Severity) != rank(findings[j].Severity) {
			return rank(findings[i].Severity) < rank(findings[j].Severity)
		}
		return findings[i].Confidence > findings[j].Confidence
	})
	limit := max(1, options.MaxFindings)
	if len(findings) > limit {
		answer.Dropped += len(findings) - limit
		findings = findings[:limit]
	}
	for index := range findings {
		findings[index].ID = fmt.Sprintf("f%d", index+1)
		findings[index].Status = model.FindingStatusNew
	}
	answer.Findings = findings
	return answer, nil
}

// extractJSON returns the last fenced JSON block, or the outermost object.
func extractJSON(reply string) (string, error) {
	if matches := jsonFence.FindAllStringSubmatch(reply, -1); len(matches) > 0 {
		for index := len(matches) - 1; index >= 0; index-- {
			candidate := strings.TrimSpace(matches[index][1])
			if strings.HasPrefix(candidate, "{") {
				return candidate, nil
			}
		}
	}
	start, end := strings.Index(reply, "{"), strings.LastIndex(reply, "}")
	if start < 0 || end <= start {
		return "", ErrNoAnswer
	}
	return reply[start : end+1], nil
}

// CompareRounds marks the current findings as new or still open relative to
// the previous review, and returns the previous findings that are gone.
// Findings match by file and either title or overlapping lines.
func CompareRounds(previous, current []model.CodeReviewFinding) ([]model.CodeReviewFinding, []model.CodeReviewFinding) {
	matched := make([]bool, len(previous))
	for index := range current {
		current[index].Status = model.FindingStatusNew
		for prior := range previous {
			if matched[prior] || previous[prior].File != current[index].File {
				continue
			}
			if sameTitle(previous[prior].Title, current[index].Title) || near(previous[prior], current[index]) {
				matched[prior] = true
				current[index].Status = model.FindingStatusOpen
				break
			}
		}
	}
	var resolved []model.CodeReviewFinding
	for prior, finding := range previous {
		if !matched[prior] {
			finding.Status = model.FindingStatusResolved
			resolved = append(resolved, finding)
		}
	}
	return current, resolved
}

func sameTitle(a, b string) bool {
	return strings.EqualFold(strings.TrimSpace(a), strings.TrimSpace(b))
}

func near(a, b model.CodeReviewFinding) bool {
	if a.StartLine == 0 || b.StartLine == 0 {
		return false
	}
	aEnd, bEnd := max(a.EndLine, a.StartLine), max(b.EndLine, b.StartLine)
	return a.StartLine <= bEnd+3 && b.StartLine <= aEnd+3
}

// ToolResult is the compact text the agent gets back from request_code_review.
func ToolResult(review model.CodeReview) string {
	var out strings.Builder
	switch review.Status {
	case model.CodeReviewFailed:
		return "The code review failed: " + review.Error
	case model.CodeReviewCancelled:
		return "The code review was cancelled."
	}
	fmt.Fprintf(&out, "Code review %s (round %d, %s, %s %s)", review.ID, max(1, review.Round), review.Depth, review.Harness, review.Model)
	if review.FilesChanged == 0 {
		out.WriteString(": there are no changes to review.\n")
		return out.String()
	}
	fmt.Fprintf(&out, " of %d files, +%d -%d.\n", review.FilesChanged, review.Additions, review.Deletions)
	if review.Summary != "" {
		out.WriteString("Summary: " + review.Summary + "\n")
	}
	if review.Security != "" && !strings.EqualFold(review.Security, "no") {
		out.WriteString("Security: " + review.Security + "\n")
	}
	if len(review.Resolved) > 0 {
		fmt.Fprintf(&out, "Resolved since the previous review: %d.\n", len(review.Resolved))
	}
	if len(review.Findings) == 0 {
		out.WriteString("No findings.\n")
		return out.String()
	}
	fmt.Fprintf(&out, "%d findings, most severe first:\n", len(review.Findings))
	for _, finding := range review.Findings {
		location := finding.File
		if finding.StartLine > 0 {
			location = fmt.Sprintf("%s:%d", finding.File, finding.StartLine)
			if finding.EndLine > finding.StartLine {
				location += fmt.Sprintf("-%d", finding.EndLine)
			}
		}
		state := ""
		if finding.Status == model.FindingStatusOpen {
			state = ", still open"
		}
		fmt.Fprintf(&out, "\n[%s] %s (%s, confidence %d%s) %s\n%s\n", finding.ID, finding.Title, finding.Severity, finding.Confidence, state, location, strings.TrimSpace(finding.Body))
		if suggestion := strings.TrimSpace(finding.Suggestion); suggestion != "" {
			out.WriteString("Suggestion: " + suggestion + "\n")
		}
	}
	out.WriteString("\nFix the findings you agree with, and say in your reply why you reject the others.\n")
	return out.String()
}

func securityText(value any) string {
	switch typed := value.(type) {
	case string:
		text := strings.TrimSpace(typed)
		if text == "" || strings.EqualFold(strings.TrimRight(text, "."), "no") {
			return "No"
		}
		return bound(text, maxSecurityBytes)
	case bool:
		if typed {
			return "Yes"
		}
	}
	return "No"
}

func cleanPath(file string) string {
	file = strings.TrimSpace(strings.Trim(strings.TrimSpace(file), "`'\""))
	for _, prefix := range []string{"a/", "b/", "./"} {
		file = strings.TrimPrefix(file, prefix)
	}
	if file == "" || strings.HasPrefix(file, "/") || strings.Contains(file, "..") {
		return ""
	}
	return filepath.ToSlash(filepath.Clean(file))
}

func severity(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "high", "critical", "blocker", "major":
		return model.FindingSeverityHigh
	case "low", "minor", "nit", "trivial", "info":
		return model.FindingSeverityLow
	default:
		return model.FindingSeverityMedium
	}
}

func rank(severity string) int {
	switch severity {
	case model.FindingSeverityHigh:
		return 0
	case model.FindingSeverityMedium:
		return 1
	default:
		return 2
	}
}

func number(value any) int {
	switch typed := value.(type) {
	case float64:
		return int(typed)
	case string:
		var parsed int
		if _, err := fmt.Sscanf(strings.TrimSpace(typed), "%d", &parsed); err == nil {
			return parsed
		}
	}
	return 0
}

func numberGiven(value any) bool {
	switch value.(type) {
	case float64, string:
		return true
	}
	return false
}

// lines clamps a finding's range to the file; a file without lines (deleted)
// keeps none.
func lines(start, end, count int) (int, int) {
	if count <= 0 || start <= 0 {
		return 0, 0
	}
	start = min(start, count)
	if end < start {
		end = start
	}
	return start, min(end, count)
}

// fileLines counts the lines of a file in the snapshot; 0 when it is gone.
func fileLines(dir, file string) int {
	if dir == "" {
		return 1 << 30
	}
	data, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(file)))
	if err != nil {
		return 0
	}
	count := strings.Count(string(data), "\n")
	if len(data) > 0 && data[len(data)-1] != '\n' {
		count++
	}
	return count
}

func clampInt(value, low, high int) int { return min(max(value, low), high) }

func oneLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func bound(value string, limit int) string {
	value = strings.TrimSpace(strings.ToValidUTF8(value, "�"))
	if len(value) <= limit {
		return value
	}
	cut := limit
	for cut > 0 && !utf8.RuneStart(value[cut]) {
		cut--
	}
	return value[:cut] + "…"
}

func boundRunes(value string, limit int) string {
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	return string([]rune(value)[:limit-1]) + "…"
}
