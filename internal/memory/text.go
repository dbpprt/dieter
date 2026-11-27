package memory

import (
	"regexp"
	"strings"
	"unicode"
)

// privateBlock is text the user marked private; it is never indexed.
var privateBlock = regexp.MustCompile(`(?is)<private>.*?(</private>|$)`)

// secretPatterns are credentials that must not reach the index: indexed text
// travels into other agents' prompts, possibly on other providers. Stored
// transcripts already have vault secrets redacted; these catch credentials
// that appeared in tool output.
var secretPatterns = []*regexp.Regexp{
	regexp.MustCompile(`-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|$)`),
	regexp.MustCompile(`\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@]+:[^\s/@]+@`),
	regexp.MustCompile(`\bsk-ant-[A-Za-z0-9_-]{16,}`),
	regexp.MustCompile(`\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}`),
	regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{20,}`),
	regexp.MustCompile(`\bgithub_pat_[A-Za-z0-9_]{20,}`),
	regexp.MustCompile(`\bglpat-[A-Za-z0-9_-]{20,}`),
	regexp.MustCompile(`\b(?:AKIA|ASIA)[A-Z0-9]{16}\b`),
	regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{30,}`),
	regexp.MustCompile(`\bxox[abprs]-[A-Za-z0-9-]{10,}`),
	regexp.MustCompile(`\bnpm_[A-Za-z0-9]{30,}`),
	regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}`),
	regexp.MustCompile(`(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{20,}`),
	regexp.MustCompile(`(?i)\b(api[_-]?key|secret|token|password|passwd|access[_-]?key)(["']?\s*[:=]\s*["']?)[^\s"',;]{8,}`),
}

// Scrub removes private blocks and credentials from text before it is
// indexed or saved.
func Scrub(text string) string {
	if text == "" {
		return text
	}
	text = privateBlock.ReplaceAllString(text, "[private]")
	for index, pattern := range secretPatterns {
		if index == len(secretPatterns)-1 {
			text = pattern.ReplaceAllString(text, "${1}${2}[redacted]")
			continue
		}
		text = pattern.ReplaceAllString(text, "[redacted]")
	}
	return text
}

var stopwords = map[string]bool{
	"a": true, "an": true, "and": true, "are": true, "as": true, "at": true, "be": true, "but": true, "by": true,
	"can": true, "did": true, "do": true, "does": true, "for": true, "from": true, "had": true, "has": true,
	"have": true, "how": true, "i": true, "if": true, "in": true, "into": true, "is": true, "it": true, "its": true,
	"me": true, "my": true, "no": true, "not": true, "of": true, "on": true, "or": true, "our": true, "so": true,
	"that": true, "the": true, "their": true, "them": true, "then": true, "there": true, "these": true,
	"this": true, "to": true, "was": true, "we": true, "were": true, "what": true, "when": true, "where": true,
	"which": true, "who": true, "why": true, "will": true, "with": true, "you": true, "your": true,
	"again": true, "after": true, "every": true, "instead": true, "one": true, "about": true, "any": true,
	"before": true, "been": true, "being": true, "just": true, "only": true, "should": true, "would": true,
	"could": true, "also": true, "some": true, "than": true, "too": true, "very": true,
}

// synonyms widen a recall query with a few common equivalents.
var synonyms = map[string][]string{
	"crash":    {"panic", "crashed"},
	"crashes":  {"panic", "crashed"},
	"slow":     {"latency", "performance"},
	"login":    {"auth", "signin"},
	"auth":     {"login", "authentication"},
	"delete":   {"remove"},
	"remove":   {"delete"},
	"bug":      {"fix", "error"},
	"error":    {"failure", "failed"},
	"fails":    {"failure", "error"},
	"test":     {"tests"},
	"tests":    {"test"},
	"settings": {"config", "configuration"},
	"config":   {"settings", "configuration"},
}

const maxQueryTerms = 24

// QueryTerms are the distinct lowercase words of a recall query, without
// stopwords.
func QueryTerms(text string) []string {
	seen := map[string]bool{}
	var out []string
	for _, word := range strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !(unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_')
	}) {
		if len(word) < 2 || stopwords[word] || seen[word] {
			continue
		}
		seen[word] = true
		out = append(out, word)
		if len(out) == maxQueryTerms {
			break
		}
	}
	return out
}

// FTSQuery turns a recall query into an SQLite FTS5 query: an OR of the
// quoted terms, their prefixes (words of four letters or more) and a few
// synonyms. FTS5's default AND would drop every paraphrase that misses one
// word. It returns "" when the query has no searchable term.
func FTSQuery(text string) string {
	terms := QueryTerms(text)
	if len(terms) == 0 {
		return ""
	}
	seen := map[string]bool{}
	var parts []string
	add := func(part string) {
		if !seen[part] {
			seen[part] = true
			parts = append(parts, part)
		}
	}
	for _, term := range terms {
		add(`"` + term + `"`)
		if len([]rune(term)) >= 4 {
			add(`"` + term + `"*`)
		}
		for _, synonym := range synonyms[term] {
			add(`"` + synonym + `"`)
		}
	}
	return strings.Join(parts, " OR ")
}

// Words are the comparable words of a memory: lowercase, longer than two
// letters.
func Words(text string) map[string]bool {
	words := map[string]bool{}
	for _, word := range strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !(unicode.IsLetter(r) || unicode.IsDigit(r))
	}) {
		if len([]rune(word)) > 2 {
			words[word] = true
		}
	}
	return words
}

// Similarity is the token Jaccard similarity of two memories, 0-1.
func Similarity(a, b string) float64 {
	left, right := Words(a), Words(b)
	if len(left) == 0 || len(right) == 0 {
		return 0
	}
	shared := 0
	for word := range left {
		if right[word] {
			shared++
		}
	}
	return float64(shared) / float64(len(left)+len(right)-shared)
}

// Normalize is a memory's comparable form: words in order, lowercase,
// single-spaced.
func Normalize(text string) string {
	return strings.Join(strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !(unicode.IsLetter(r) || unicode.IsDigit(r))
	}), " ")
}

var identifierPattern = regexp.MustCompile(`[A-Za-z][A-Za-z0-9]*(?:[_.][A-Za-z0-9]+|[a-z0-9][A-Z][A-Za-z0-9]*)+`)
var identifierBoundary = regexp.MustCompile(`([a-z0-9])([A-Z])|([A-Z])([A-Z][a-z])`)

const maxTermsBytes = 1 << 10

// IdentifierTerms splits the camelCase, snake_case and dotted identifiers of
// text into their words, so a recall of "scroll controller" finds
// TranscriptScrollController. The full-text tokenizer keeps such identifiers
// whole.
func IdentifierTerms(texts ...string) string {
	seen := map[string]bool{}
	var out []string
	size := 0
	for _, text := range texts {
		for _, identifier := range identifierPattern.FindAllString(text, 200) {
			split := identifierBoundary.ReplaceAllString(identifier, "${1}${3} ${2}${4}")
			for _, word := range strings.FieldsFunc(strings.ToLower(split), func(r rune) bool {
				return !(unicode.IsLetter(r) || unicode.IsDigit(r))
			}) {
				if len(word) < 3 || seen[word] || size+len(word)+1 > maxTermsBytes {
					continue
				}
				seen[word] = true
				size += len(word) + 1
				out = append(out, word)
			}
		}
	}
	return strings.Join(out, " ")
}
