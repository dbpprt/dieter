package folders

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	core "github.com/dbpprt/dieter/internal/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// Definition is a folder's shared definition.
type Definition struct {
	ID             string
	Name           string
	Rules          []string
	TrashDays      int
	DeleteGuard    core.Guard
	ProjectID      string
	Archived       bool
	CreatedAt      string
	ConflictFields []string

	parsed []core.Rule
}

// Included reports whether path syncs under the folder's rules.
func (d Definition) Included(path string) bool { return core.Included(path, d.parsed) }

func trashDaysValue(days int) string {
	switch {
	case days <= 0:
		return "off"
	case days <= 7:
		return "7"
	case days <= 30:
		return "30"
	}
	return "90"
}

func decodeDefinition(id string, fields map[string]json.RawMessage, conflicts []string) (Definition, bool) {
	var raw struct {
		ID          string   `json:"id"`
		CreatedAt   string   `json:"createdAt"`
		Name        string   `json:"name"`
		Rules       []string `json:"rules"`
		TrashDays   string   `json:"trashDays"`
		DeleteGuard string   `json:"deleteGuard"`
		ProjectID   string   `json:"projectId"`
		Archived    bool     `json:"archived"`
	}
	if replica.DecodeFields(fields, &raw) != nil || raw.ID != id || raw.Name == "" {
		return Definition{}, false
	}
	definition := Definition{ID: id, Name: raw.Name, Rules: raw.Rules, DeleteGuard: core.Guard(raw.DeleteGuard), ProjectID: raw.ProjectID, Archived: raw.Archived, CreatedAt: raw.CreatedAt, ConflictFields: conflicts}
	switch raw.TrashDays {
	case "off":
		definition.TrashDays = 0
	case "":
		definition.TrashDays = 30
	default:
		definition.TrashDays, _ = strconv.Atoi(raw.TrashDays)
	}
	if definition.DeleteGuard == "" {
		definition.DeleteGuard = core.GuardDefault
	}
	parsed, err := core.ParseRules(raw.Rules)
	if err != nil {
		parsed = nil
	}
	definition.parsed = parsed
	return definition, true
}

// Definitions lists the account's folder definitions by name.
func (e *Engine) Definitions(includeArchived bool) ([]Definition, error) {
	_, data, err := e.store().Replica.Snapshot()
	if err != nil {
		return nil, err
	}
	defer data.Close()
	var out []Definition
	for _, id := range replica.EntityIDs(data, "folder", "identity") {
		fields, conflicts := replica.EntityFields(data, "folder", id)
		definition, ok := decodeDefinition(id, fields, conflicts)
		if !ok || definition.Archived && !includeArchived {
			continue
		}
		out = append(out, definition)
	}
	slices.SortFunc(out, func(a, b Definition) int {
		if c := strings.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name)); c != 0 {
			return c
		}
		return strings.Compare(a.ID, b.ID)
	})
	return out, data.Err()
}

// Definition is one folder's definition.
func (e *Engine) Definition(id string) (Definition, error) {
	_, data, err := e.store().Replica.Snapshot()
	if err != nil {
		return Definition{}, err
	}
	defer data.Close()
	fields, conflicts := replica.EntityFields(data, "folder", id)
	definition, ok := decodeDefinition(id, fields, conflicts)
	if !ok {
		return Definition{}, fault.NotFoundf("folder not found")
	}
	return definition, data.Err()
}

// Resolve finds a folder by ID or exact name.
func (e *Engine) Resolve(ref string) (Definition, error) {
	if definition, err := e.Definition(ref); err == nil {
		return definition, nil
	}
	definitions, err := e.Definitions(true)
	if err != nil {
		return Definition{}, err
	}
	var found []Definition
	for _, definition := range definitions {
		if definition.Name == ref {
			found = append(found, definition)
		}
	}
	switch len(found) {
	case 0:
		return Definition{}, fault.NotFoundf("folder %q not found", ref)
	case 1:
		return found[0], nil
	}
	return Definition{}, fault.Invalidf("several folders are named %q; use the folder ID", ref)
}

// DefinitionChange is a create or update of a definition; nil fields stay.
type DefinitionChange struct {
	Name        *string
	Rules       *[]string
	TrashDays   *int
	DeleteGuard *core.Guard
	ProjectID   *string
	Archived    *bool
}

func validName(name string) bool {
	name = strings.TrimSpace(name)
	return name != "" && len(name) <= 128 && utf8.ValidString(name) && !strings.ContainsAny(name, "/\\\x00")
}

// CreateFolder records a new shared definition.
func (e *Engine) CreateFolder(change DefinitionChange) (Definition, error) {
	if change.Name == nil || !validName(*change.Name) {
		return Definition{}, fault.Invalidf("a folder needs a name (at most 128 bytes, no slashes)")
	}
	existing, err := e.Definitions(false)
	if err != nil {
		return Definition{}, err
	}
	if len(existing) >= schema.MaxFolders {
		return Definition{}, fault.New(fault.ResourceExhausted, "an account has at most 64 folders")
	}
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	id := "fo_" + hex.EncodeToString(b)
	if change.Rules == nil {
		rules := slices.Clone(core.DefaultRules)
		change.Rules = &rules
	}
	if change.TrashDays == nil {
		days := 30
		change.TrashDays = &days
	}
	if change.DeleteGuard == nil {
		guard := core.GuardDefault
		change.DeleteGuard = &guard
	}
	if change.ProjectID == nil {
		empty := ""
		change.ProjectID = &empty
	}
	archived := false
	change.Archived = &archived
	identity := map[string]any{"id": id, "createdAt": e.now().UTC().Format(time.RFC3339Nano)}
	if err := e.writeDefinition(id, identity, change); err != nil {
		return Definition{}, err
	}
	return e.Definition(id)
}

// UpdateFolder changes a definition.
func (e *Engine) UpdateFolder(id string, change DefinitionChange) (Definition, error) {
	if _, err := e.Definition(id); err != nil {
		return Definition{}, err
	}
	if change.Name != nil && !validName(*change.Name) {
		return Definition{}, fault.Invalidf("a folder needs a name (at most 128 bytes, no slashes)")
	}
	if err := e.writeDefinition(id, nil, change); err != nil {
		return Definition{}, err
	}
	for _, r := range e.allRuns() {
		if r.folderID == id {
			e.Wake(id, true)
		}
	}
	return e.Definition(id)
}

func (e *Engine) allRuns() []*run {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]*run, 0, len(e.runs))
	for _, r := range e.runs {
		out = append(out, r)
	}
	return out
}

func (e *Engine) writeDefinition(id string, identity map[string]any, change DefinitionChange) error {
	next := map[string]json.RawMessage{}
	if identity != nil {
		next["identity"] = replica.RawValue(identity)
	}
	if change.Name != nil {
		next["name"] = replica.RawValue(strings.TrimSpace(*change.Name))
	}
	if change.Rules != nil {
		rules := *change.Rules
		if rules == nil {
			rules = []string{}
		}
		if _, err := core.ParseRules(rules); err != nil {
			return err
		}
		next["rules"] = replica.RawValue(rules)
	}
	if change.TrashDays != nil {
		next["trashDays"] = replica.RawValue(trashDaysValue(*change.TrashDays))
	}
	if change.DeleteGuard != nil {
		guard := *change.DeleteGuard
		if guard != core.GuardDefault && guard != core.GuardStrict && guard != core.GuardOff {
			return fault.Invalidf("deletion guard must be default, strict or off")
		}
		next["deleteGuard"] = replica.RawValue(string(guard))
	}
	if change.ProjectID != nil {
		if *change.ProjectID != "" && !crdt.ValidID(*change.ProjectID) {
			return fault.Invalidf("invalid project ID")
		}
		next["projectId"] = replica.RawValue(*change.ProjectID)
	}
	if change.Archived != nil {
		next["archived"] = replica.RawValue(*change.Archived)
	}
	release, err := e.store().BeginWrite()
	if err != nil {
		return err
	}
	defer release()
	writer, err := e.store().Replica.WriterIdentity()
	if err != nil {
		return err
	}
	data, err := e.store().Replica.OpenPeerView(writer.Account)
	if err != nil {
		return err
	}
	data.State = replica.ClonePeerState(data.State)
	if err = replica.ApplyFields(&data, writer, "folder", id, nil, next); err != nil {
		return err
	}
	return e.store().Replica.SavePeerData(writer.Account, data)
}

// LinkedFolder is a folder linked to a project with a member on this daemon.
type LinkedFolder struct {
	Name string
	Path string
	Mode core.Mode
}

// LinkedFolders lists, for turn instructions, the folders linked to project
// that this daemon is a member of: at most 8.
func (e *Engine) LinkedFolders(projectID string) []LinkedFolder {
	if projectID == "" {
		return nil
	}
	members, err := e.folders().Members()
	if err != nil || len(members) == 0 {
		return nil
	}
	var out []LinkedFolder
	for _, member := range members {
		definition, err := e.Definition(member.FolderID)
		if err != nil || definition.Archived || definition.ProjectID != projectID {
			continue
		}
		out = append(out, LinkedFolder{Name: definition.Name, Path: member.Path, Mode: member.Mode})
		if len(out) == 8 {
			break
		}
	}
	return out
}
