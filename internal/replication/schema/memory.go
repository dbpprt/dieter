package schema

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// Agent memory replicates two kinds of KV records, both written only by
// daemons (MemoryService; the public KV API refuses them) and validated on
// write and on ingest:
//
//   - "memory": one record per saved memory, keyed PROJECT.MEMORY. Retiring
//     or superseding changes its status so the history survives; only a
//     person's forget deletes it. Reinforcements count per daemon, so
//     concurrent reinforcements from several daemons add up.
//   - "memory-settings": the account's memory and dreaming setting.
//
// The full-text index of conversations is derived and machine-local; it
// never replicates.
const (
	MemoryNamespace         = "memory"
	MemorySettingsNamespace = "memory-settings"
	MemorySettingsKey       = "default"
)

// Saved memory bounds.
const (
	MemoryValueBytes       = 16 << 10
	MemoryContentBytes     = 4 << 10
	MemoryReasonBytes      = 1 << 10
	MemoryMaxFiles         = 20
	MemoryMaxSources       = 8
	MemoryMaxPerProject    = 2000
	MemoryMaxTTLDays       = 3650
	memoryFileBytes        = 512
	memoryIDBytes          = 64
	memoryReinforceDaemons = 64
)

// Saved memory kinds and statuses.
const (
	MemoryKindLesson   = "lesson"
	MemoryKindDecision = "decision"
	MemoryKindFact     = "fact"
	MemoryKindPattern  = "pattern"

	MemoryActive     = "active"
	MemorySuperseded = "superseded"
	MemoryRetired    = "retired"
)

// MemoryKinds lists the saved memory kinds in display order.
var MemoryKinds = []string{MemoryKindLesson, MemoryKindDecision, MemoryKindFact, MemoryKindPattern}

// MemoryOrigin is where a saved memory was written.
type MemoryOrigin struct {
	Daemon  string `json:"daemon"`
	Card    string `json:"card,omitempty"`
	Harness string `json:"harness,omitempty"`
}

// MemoryRecord is one saved memory of a project.
type MemoryRecord struct {
	Project      string   `json:"project"`
	Kind         string   `json:"kind"`
	Content      string   `json:"content"`
	Files        []string `json:"files,omitempty"`
	Sources      []string `json:"sources,omitempty"`
	Status       string   `json:"status"`
	SupersededBy string   `json:"supersededBy,omitempty"`
	Verified     bool     `json:"verified,omitempty"`
	// Reinforcements counts, per daemon, how often the memory was saved
	// again. Readers merge concurrent versions by taking each daemon's
	// highest count.
	Reinforcements map[string]int `json:"reinforcements,omitempty"`
	ExpiresAt      string         `json:"expiresAt,omitempty"`
	CreatedBy      MemoryOrigin   `json:"createdBy"`
	// DreamCard is the dream conversation that last changed the memory.
	DreamCard string `json:"dreamCard,omitempty"`
	Reason    string `json:"reason,omitempty"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

// MemoryKey is the KV key of a saved memory.
func MemoryKey(projectID, memoryID string) string { return projectID + "." + memoryID }

// SplitMemoryKey returns the project and memory IDs of a saved memory key.
func SplitMemoryKey(key string) (projectID, memoryID string, ok bool) {
	projectID, memoryID, ok = strings.Cut(key, ".")
	return projectID, memoryID, ok && memoryIdentifier.MatchString(projectID) && memoryIdentifier.MatchString(memoryID)
}

var memoryIdentifier = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// ValidMemoryID reports whether id can name a saved memory or project.
func ValidMemoryID(id string) bool { return memoryIdentifier.MatchString(id) }

// MemoryNamespaceKind reports whether ns holds agent memory records.
func MemoryNamespaceKind(ns string) bool {
	return ns == MemoryNamespace || ns == MemorySettingsNamespace
}

// DecodeMemory strictly decodes and validates a saved memory.
func DecodeMemory(key string, raw []byte) (MemoryRecord, error) {
	var record MemoryRecord
	projectID, _, ok := SplitMemoryKey(key)
	if !ok {
		return record, fault.New(fault.Invalid, "invalid saved memory key")
	}
	if len(raw) > MemoryValueBytes {
		return record, fault.New(fault.Invalid, "saved memory exceeds 16 KiB")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return record, fault.Invalidf("invalid saved memory: %v", err)
	}
	if record.Project != projectID {
		return record, fault.New(fault.Invalid, "saved memory key and project differ")
	}
	return record, ValidateMemory(record)
}

// ValidateMemory checks a saved memory's bounds.
func ValidateMemory(record MemoryRecord) error {
	if !ValidMemoryID(record.Project) {
		return fault.New(fault.Invalid, "invalid saved memory project")
	}
	if !memoryKind(record.Kind) {
		return fault.New(fault.Invalid, `saved memory kind must be "lesson", "decision", "fact" or "pattern"`)
	}
	if strings.TrimSpace(record.Content) == "" || !memoryText(record.Content, MemoryContentBytes) {
		return fault.New(fault.Invalid, "saved memory content must be UTF-8 text of 1 byte to 4 KiB")
	}
	if !memoryText(record.Reason, MemoryReasonBytes) {
		return fault.New(fault.Invalid, "saved memory reason must be UTF-8 text of at most 1 KiB")
	}
	switch record.Status {
	case MemoryActive, MemoryRetired:
		if record.SupersededBy != "" {
			return fault.New(fault.Invalid, "only a superseded memory names its successor")
		}
	case MemorySuperseded:
		if !ValidMemoryID(record.SupersededBy) {
			return fault.New(fault.Invalid, "a superseded memory names its successor")
		}
	default:
		return fault.New(fault.Invalid, `saved memory status must be "active", "superseded" or "retired"`)
	}
	if len(record.Files) > MemoryMaxFiles {
		return fault.Invalidf("at most %d files per saved memory", MemoryMaxFiles)
	}
	for _, file := range record.Files {
		if strings.TrimSpace(file) == "" || !memoryText(file, memoryFileBytes) || strings.ContainsAny(file, "\n\r") {
			return fault.New(fault.Invalid, "invalid saved memory file")
		}
	}
	if len(record.Sources) > MemoryMaxSources {
		return fault.Invalidf("at most %d sources per saved memory", MemoryMaxSources)
	}
	for _, source := range record.Sources {
		if !ValidMemoryID(source) {
			return fault.New(fault.Invalid, "invalid saved memory source")
		}
	}
	if len(record.Reinforcements) > memoryReinforceDaemons {
		return fault.New(fault.Invalid, "too many reinforcing daemons")
	}
	for daemon, count := range record.Reinforcements {
		if !ValidMemoryID(daemon) || count < 0 || count > 1_000_000 {
			return fault.New(fault.Invalid, "invalid saved memory reinforcement")
		}
	}
	if !ValidMemoryID(record.CreatedBy.Daemon) || (record.CreatedBy.Card != "" && !ValidMemoryID(record.CreatedBy.Card)) || !memoryText(record.CreatedBy.Harness, memoryIDBytes) {
		return fault.New(fault.Invalid, "invalid saved memory origin")
	}
	if record.DreamCard != "" && !ValidMemoryID(record.DreamCard) {
		return fault.New(fault.Invalid, "invalid saved memory dream")
	}
	for _, value := range []string{record.ExpiresAt, record.CreatedAt, record.UpdatedAt} {
		if !memoryText(value, memoryIDBytes) {
			return fault.New(fault.Invalid, "invalid saved memory timestamp")
		}
	}
	if record.CreatedAt == "" || record.UpdatedAt == "" {
		return fault.New(fault.Invalid, "saved memory timestamps are required")
	}
	return nil
}

func memoryKind(kind string) bool {
	for _, candidate := range MemoryKinds {
		if kind == candidate {
			return true
		}
	}
	return false
}

func memoryText(value string, limit int) bool {
	return len(value) <= limit && utf8.ValidString(value) && !strings.ContainsRune(value, 0)
}

// Memory setting bounds and defaults.
const (
	MemorySettingsValueBytes   = 16 << 10
	MemoryInstructionsBytes    = 4 << 10
	MemoryDefaultHarness       = "claude-code"
	MemoryDefaultModel         = "opus"
	MemoryDefaultMinHours      = 24
	MemoryDefaultMinNewTasks   = 5
	MemoryDefaultWindow        = "02:00-06:00"
	MemoryDefaultApply         = "auto"
	MemoryDefaultMaxOperations = 40
	MemoryDefaultMaxRetire     = 25
	memoryWindowPattern        = `^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$`
)

var memoryWindow = regexp.MustCompile(memoryWindowPattern)

// MemorySettingsRecord is the account's memory and dreaming setting.
type MemorySettingsRecord struct {
	Dreaming      bool   `json:"dreaming"`
	Harness       string `json:"harness"`
	Model         string `json:"model,omitempty"`
	Effort        string `json:"effort,omitempty"`
	AccountID     string `json:"accountId,omitempty"`
	RunOn         string `json:"runOn,omitempty"`
	MinHours      int    `json:"minHours"`
	MinNewTasks   int    `json:"minNewTasks"`
	Window        string `json:"window,omitempty"`
	Apply         string `json:"apply"`
	MaxOperations int    `json:"maxOperations"`
	MaxRetire     int    `json:"maxRetirePercent"`
	Instructions  string `json:"instructions,omitempty"`
	UpdatedAt     string `json:"updatedAt,omitempty"`
}

// DefaultMemorySettings is the setting a daemon uses until someone saves one.
func DefaultMemorySettings() MemorySettingsRecord {
	return MemorySettingsRecord{
		Harness: MemoryDefaultHarness, Model: MemoryDefaultModel, MinHours: MemoryDefaultMinHours,
		MinNewTasks: MemoryDefaultMinNewTasks, Window: MemoryDefaultWindow, Apply: MemoryDefaultApply,
		MaxOperations: MemoryDefaultMaxOperations, MaxRetire: MemoryDefaultMaxRetire,
	}
}

// DecodeMemorySettings strictly decodes and validates the memory setting.
func DecodeMemorySettings(key string, raw []byte) (MemorySettingsRecord, error) {
	var record MemorySettingsRecord
	if key != MemorySettingsKey {
		return record, fault.New(fault.Invalid, "invalid memory setting key")
	}
	if len(raw) > MemorySettingsValueBytes {
		return record, fault.New(fault.Invalid, "memory setting exceeds 16 KiB")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return record, fault.Invalidf("invalid memory setting: %v", err)
	}
	return record, ValidateMemorySettings(record)
}

// ValidateMemorySettings checks the memory setting's bounds. Like the
// reviewer setting, it does not check that the harness exists on this daemon.
func ValidateMemorySettings(record MemorySettingsRecord) error {
	for name, value := range map[string]string{"harness": record.Harness, "model": record.Model, "effort": record.Effort, "account": record.AccountID, "machine": record.RunOn} {
		if !reviewerName(value) {
			return fault.Invalidf("invalid dreaming %s", name)
		}
	}
	if record.Harness == "" {
		return fault.New(fault.Invalid, "dreaming harness is required")
	}
	if record.MinHours < 1 || record.MinHours > 168 {
		return fault.New(fault.Invalid, "dreaming minimum hours must be 1-168")
	}
	if record.MinNewTasks < 1 || record.MinNewTasks > 100 {
		return fault.New(fault.Invalid, "dreaming minimum new conversations must be 1-100")
	}
	if record.Window != "" && !memoryWindow.MatchString(record.Window) {
		return fault.New(fault.Invalid, `dreaming window must be "HH:MM-HH:MM"`)
	}
	if record.Apply != "auto" && record.Apply != "review" {
		return fault.New(fault.Invalid, `dreaming apply must be "auto" or "review"`)
	}
	if record.MaxOperations < 1 || record.MaxOperations > 100 {
		return fault.New(fault.Invalid, "dreaming maximum changes must be 1-100")
	}
	if record.MaxRetire < 1 || record.MaxRetire > 100 {
		return fault.New(fault.Invalid, "dreaming maximum retired percentage must be 1-100")
	}
	if !memoryText(record.Instructions, MemoryInstructionsBytes) {
		return fault.New(fault.Invalid, "dreaming instructions must be UTF-8 text of at most 4 KiB")
	}
	if !reviewerName(record.UpdatedAt) {
		return fault.New(fault.Invalid, "invalid memory setting timestamp")
	}
	return nil
}

func validateMemoryRecord(ns, key string, raw []byte) error {
	if ns == MemorySettingsNamespace {
		_, err := DecodeMemorySettings(key, raw)
		return err
	}
	_, err := DecodeMemory(key, raw)
	return err
}
