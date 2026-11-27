package schema

import (
	"bytes"
	"encoding/json"
	"path"
	"strings"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// The code reviewer setting replicates as one KV record that every daemon of
// the account reads when it runs a review. Only daemons write it (through
// ReviewService); the public KV API refuses, and values are validated on write
// and on ingest.
const (
	ReviewerSettingsNamespace = "reviewer-settings"
	ReviewerSettingsKey       = "default"
)

// Reviewer setting bounds and defaults.
const (
	ReviewerValueBytes        = 16 << 10
	ReviewerInstructionsBytes = 4 << 10
	ReviewerMaxGlobs          = 32
	reviewerGlobBytes         = 256
	reviewerNameBytes         = 128

	ReviewerDefaultHarness     = "claude-code"
	ReviewerDefaultModel       = "opus"
	ReviewerDefaultDepth       = "quick"
	ReviewerDefaultMaxFindings = 6
	ReviewerDefaultMaxRounds   = 3
	ReviewerMaxFindingsLimit   = 20
	ReviewerMaxRoundsLimit     = 10
)

// ReviewerSettingsRecord is the account's code reviewer setting.
type ReviewerSettingsRecord struct {
	Harness       string   `json:"harness"`
	Model         string   `json:"model,omitempty"`
	Effort        string   `json:"effort,omitempty"`
	AccountID     string   `json:"accountId,omitempty"`
	Depth         string   `json:"depth"`
	MaxFindings   int      `json:"maxFindings"`
	MinConfidence int      `json:"minConfidence,omitempty"`
	Instructions  string   `json:"instructions,omitempty"`
	IgnoreGlobs   []string `json:"ignoreGlobs,omitempty"`
	MaxRounds     int      `json:"maxRounds"`
	UpdatedAt     string   `json:"updatedAt,omitempty"`
}

// DefaultReviewerSettings is the setting a daemon uses until someone saves one.
func DefaultReviewerSettings() ReviewerSettingsRecord {
	return ReviewerSettingsRecord{
		Harness: ReviewerDefaultHarness, Model: ReviewerDefaultModel, Depth: ReviewerDefaultDepth,
		MaxFindings: ReviewerDefaultMaxFindings, MaxRounds: ReviewerDefaultMaxRounds,
	}
}

// ReviewerNamespaceKind reports whether ns is the reviewer setting namespace.
func ReviewerNamespaceKind(ns string) bool { return ns == ReviewerSettingsNamespace }

// DecodeReviewerSettings strictly decodes and validates a reviewer setting.
func DecodeReviewerSettings(key string, raw []byte) (ReviewerSettingsRecord, error) {
	var record ReviewerSettingsRecord
	if key != ReviewerSettingsKey {
		return record, fault.New(fault.Invalid, "invalid reviewer setting key")
	}
	if len(raw) > ReviewerValueBytes {
		return record, fault.New(fault.Invalid, "reviewer setting exceeds 16 KiB")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return record, fault.Invalidf("invalid reviewer setting: %v", err)
	}
	return record, ValidateReviewerSettings(record)
}

// ValidateReviewerSettings checks a reviewer setting's bounds. It does not
// check that the harness exists: the catalog belongs to each daemon, and a
// review on a daemon without the harness fails with that reason.
func ValidateReviewerSettings(record ReviewerSettingsRecord) error {
	for name, value := range map[string]string{"harness": record.Harness, "model": record.Model, "effort": record.Effort, "account": record.AccountID} {
		if !reviewerName(value) {
			return fault.Invalidf("invalid reviewer %s", name)
		}
	}
	if record.Harness == "" {
		return fault.New(fault.Invalid, "reviewer harness is required")
	}
	if record.Depth != "quick" && record.Depth != "thorough" {
		return fault.New(fault.Invalid, `reviewer depth must be "quick" or "thorough"`)
	}
	if record.MaxFindings < 1 || record.MaxFindings > ReviewerMaxFindingsLimit {
		return fault.Invalidf("reviewer max findings must be 1-%d", ReviewerMaxFindingsLimit)
	}
	if record.MinConfidence < 0 || record.MinConfidence > 10 {
		return fault.New(fault.Invalid, "reviewer min confidence must be 0-10")
	}
	if record.MaxRounds < 1 || record.MaxRounds > ReviewerMaxRoundsLimit {
		return fault.Invalidf("reviewer max rounds must be 1-%d", ReviewerMaxRoundsLimit)
	}
	if len(record.Instructions) > ReviewerInstructionsBytes || !utf8.ValidString(record.Instructions) || strings.ContainsRune(record.Instructions, 0) {
		return fault.New(fault.Invalid, "reviewer instructions must be UTF-8 text of at most 4 KiB")
	}
	if len(record.IgnoreGlobs) > ReviewerMaxGlobs {
		return fault.Invalidf("at most %d reviewer ignore globs", ReviewerMaxGlobs)
	}
	for _, glob := range record.IgnoreGlobs {
		if err := ValidReviewerGlob(glob); err != nil {
			return err
		}
	}
	if !reviewerName(record.UpdatedAt) {
		return fault.New(fault.Invalid, "invalid reviewer setting timestamp")
	}
	return nil
}

// ValidReviewerGlob checks one ignore glob: a non-empty, relative path.Match
// pattern of at most 256 bytes.
func ValidReviewerGlob(glob string) error {
	if strings.TrimSpace(glob) == "" || len(glob) > reviewerGlobBytes || !utf8.ValidString(glob) || strings.HasPrefix(glob, "/") || strings.ContainsAny(glob, "\x00\n\r") {
		return fault.Invalidf("invalid reviewer ignore glob %q", glob)
	}
	if _, err := path.Match(glob, ""); err != nil {
		return fault.Invalidf("invalid reviewer ignore glob %q: %v", glob, err)
	}
	return nil
}

func reviewerName(value string) bool {
	if len(value) > reviewerNameBytes || !utf8.ValidString(value) {
		return false
	}
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

func validateReviewer(key string, raw []byte) error {
	_, err := DecodeReviewerSettings(key, raw)
	return err
}
