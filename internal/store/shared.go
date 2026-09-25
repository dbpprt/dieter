package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
)

var ErrRemoteConversation = errors.New("conversation belongs to another machine; target its owner")

// sharedIdentity is called under the central writer lock on first creation.
// Unenrolled installations are local replicas. First enrollment adopts these
// records into the authenticated account; later account changes never copy them.
func (s *Store) sharedIdentity() (PeerIdentity, error) {
	identity, err := s.PeerIdentity()
	if err == nil {
		return identity, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return identity, err
	}
	identity = PeerIdentity{Account: "local", DaemonID: newID("local_"), Actor: newID("actor_")}
	return identity, writeJSON(filepath.Join(s.Root, "peers", "identity.json"), identity)
}
func (s *Store) sharedData() (PeerIdentity, PeerData, error) {
	if err := s.checkStorageSchema(); err != nil {
		return PeerIdentity{}, PeerData{}, err
	}
	identity, err := s.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		return identity, PeerData{State: peerstore.State{Records: map[string]peerstore.Record{}}}, nil
	}
	if err != nil {
		return identity, PeerData{}, err
	}
	data, err := s.PeerData(identity.Account)
	return identity, data, err
}
func rawValue(value any) json.RawMessage { raw, _ := json.Marshal(value); return raw }
func objectFields(value any) map[string]json.RawMessage {
	fields := map[string]json.RawMessage{}
	_ = json.Unmarshal(rawValue(value), &fields)
	return fields
}
func sharedFields(data PeerData, kind, id string) (map[string]json.RawMessage, []string) {
	fields := map[string]json.RawMessage{}
	var conflicts []string
	for field := range peerstore.DomainFields[kind] {
		record := data.Records[peerstore.Key(kind, id+"."+field)]
		if len(record.Versions) > 1 && field != "updatedAt" {
			conflicts = append(conflicts, peerstore.Key(kind, record.ID))
		}
		if raw, ok := peerstore.Selected(record); ok {
			fields[field] = raw
		}
		if field == "archived" || field == "deleted" {
			for _, v := range record.Versions {
				if bytes.Equal(v.Value, []byte("true")) {
					fields[field] = v.Value
				}
			}
		}
	}
	sort.Strings(conflicts)
	return fields, conflicts
}
func decodeFields(fields map[string]json.RawMessage, value any) error {
	flattened := map[string]json.RawMessage{}
	for key, raw := range fields {
		if key == "identity" || key == "placement" || key == "summary" && len(raw) > 0 && raw[0] == '{' {
			var child map[string]json.RawMessage
			if err := json.Unmarshal(raw, &child); err != nil {
				return err
			}
			for k, v := range child {
				flattened[k] = v
			}
		} else {
			flattened[key] = raw
		}
	}
	return json.Unmarshal(rawValue(flattened), value)
}
func entityIDs(data PeerData, kind, field string) []string {
	if data.EntityIDs == nil {
		indexPeerData(&data)
	}
	return data.EntityIDs[kind+"/"+field]
}

func applyFields(data *PeerData, identity PeerIdentity, kind, id string, before, next map[string]json.RawMessage) error {
	for field, value := range next {
		if bytes.Equal(before[field], value) {
			continue
		}
		key := peerstore.Key(kind, id+"."+field)
		old := data.Records[key]
		// A normal form save cannot discard concurrent siblings. The explicit peer
		// resolution endpoint requires the current revision and covers all siblings.
		if len(old.Versions) > 1 && field != "updatedAt" && !(kind == "item" && (field == "placement" || field == "pinned") || kind == "assignment" && field == "membership") {
			return fmt.Errorf("%w: %s", peerstore.ErrConflict, key)
		}
		if current, ok := peerstore.Selected(old); ok && bytes.Equal(current, value) {
			continue
		}
		if observed, ok := before[field]; ok && len(old.Versions) > 0 {
			current, _ := peerstore.Selected(old)
			if !bytes.Equal(current, observed) {
				return fmt.Errorf("%w: %s changed since read", peerstore.ErrConflict, key)
			}
		}
		if field == "identity" && len(old.Versions) > 0 {
			current, _ := peerstore.Selected(old)
			if !bytes.Equal(current, value) {
				return errors.New("shared identity is immutable")
			}
			continue
		}
		record, err := peerstore.Put(old, kind, id+"."+field, identity.Actor, old.Revision(), value, false)
		if err != nil {
			return err
		}
		if err = peerstore.ValidateSettings(record); err != nil {
			return err
		}
		data.Records[key] = record
		if data.Dirty == nil {
			data.Dirty = map[string]bool{}
		}
		data.Dirty[key] = true
	}
	return nil
}
func pickFields(value any, kind string) map[string]json.RawMessage {
	all := objectFields(value)
	out := map[string]json.RawMessage{}
	for field, shape := range peerstore.DomainFields[kind] {
		if field == "deleted" || field == "consolidatedInto" {
			continue
		}
		if raw, ok := all[field]; ok {
			out[field] = raw
		} else {
			switch shape {
			case "string":
				out[field] = rawValue("")
			case "bool":
				out[field] = rawValue(false)
			case "strings":
				out[field] = rawValue([]string{})
			}
		}
	}
	return out
}
func (s *Store) writeProject(project model.Project, effects ...localEffect) error {
	identity, err := s.sharedIdentity()
	if err != nil {
		return err
	}
	data, err := s.PeerData(identity.Account)
	data.State = clonePeerState(data.State)
	if err != nil {
		return err
	}
	next := pickFields(project, "project")
	next["identity"] = rawValue(map[string]any{"id": project.ID, "createdAt": project.CreatedAt})
	if err = applyFields(&data, identity, "project", project.ID, project.SharedBase, next); err != nil {
		return err
	}
	return s.writePeerState(identity.Account, data, effects...)
}
func (s *Store) sharedProjects() ([]model.Project, error) {
	_, data, err := s.sharedData()
	if err != nil {
		return nil, err
	}
	checkouts, err := s.checkoutsFrom(data)
	if err != nil {
		return nil, err
	}
	projects := []model.Project{}
	for _, id := range entityIDs(data, "project", "identity") {
		if canonicalProjectID(data, id) != id {
			continue
		}
		fields, conflicts := sharedFields(data, "project", id)
		if len(fields["name"]) == 0 || len(fields["archived"]) == 0 {
			continue
		}
		var project model.Project
		if err = decodeFields(fields, &project); err != nil {
			return nil, err
		}
		project.SharedBase, project.ConflictKeys = fields, conflicts
		for _, checkout := range checkouts {
			if checkout.ProjectID == id {
				project.Checkouts = append(project.Checkouts, checkout)
			}
		}
		var local []model.Checkout
		for _, checkout := range project.Checkouts {
			if checkout.Path != "" && !checkout.Detached {
				local = append(local, checkout)
			}
		}
		if len(local) == 1 {
			project.Path = local[0].Path
			project.ValidationCommands = local[0].ValidationCommands
		}
		if project.UpdatedAt == "" {
			project.UpdatedAt = project.CreatedAt
		}
		projects = append(projects, project)
	}
	sort.Slice(projects, func(i, j int) bool {
		if projects[i].Name == projects[j].Name {
			return projects[i].ID < projects[j].ID
		}
		return strings.ToLower(projects[i].Name) < strings.ToLower(projects[j].Name)
	})
	return projects, nil
}
func (s *Store) writeBoard(board model.Board) error {
	identity, err := s.sharedIdentity()
	if err != nil {
		return err
	}
	data, err := s.PeerData(identity.Account)
	data.State = clonePeerState(data.State)
	if err != nil {
		return err
	}
	next := pickFields(board, "board")
	next["identity"] = rawValue(map[string]any{"id": board.ID, "projectId": board.ProjectID, "createdAt": board.CreatedAt})
	if original := board.SharedBase["identity"]; len(original) > 0 {
		next["identity"] = original
	}
	if err = applyFields(&data, identity, "board", board.ID, board.SharedBase, next); err != nil {
		return err
	}
	var previous []model.Label
	_ = json.Unmarshal(board.SharedBase["labels"], &previous)
	previousByID := map[string]model.Label{}
	for _, label := range previous {
		previousByID[label.ID] = label
	}
	for _, label := range board.Labels {
		fields := pickFields(label, "label")
		fields["identity"] = rawValue(map[string]string{"id": label.ID, "boardId": board.ID})
		before := map[string]json.RawMessage{}
		if old, ok := previousByID[label.ID]; ok {
			before = pickFields(old, "label")
			before["identity"] = fields["identity"]
		}
		if err = applyFields(&data, identity, "label", label.ID, before, fields); err != nil {
			return err
		}
		delete(previousByID, label.ID)
	}
	for id := range previousByID {
		if err = applyFields(&data, identity, "label", id, nil, map[string]json.RawMessage{"deleted": rawValue(true)}); err != nil {
			return err
		}
	}
	return s.savePeerData(identity.Account, data)
}
func (s *Store) sharedBoards() ([]model.Board, error) {
	_, data, err := s.sharedData()
	if err != nil {
		return nil, err
	}
	result := []model.Board{}
	for _, id := range entityIDs(data, "board", "identity") {
		fields, conflicts := sharedFields(data, "board", id)
		var board model.Board
		if err = decodeFields(fields, &board); err != nil {
			return nil, err
		}
		board.ProjectID = canonicalProjectID(data, board.ProjectID)
		if !sharedEntityReady(data, "project", board.ProjectID) || len(fields["name"]) == 0 || len(fields["workflow"]) == 0 {
			continue
		}
		for _, labelID := range entityIDs(data, "label", "identity") {
			labelFields, lc := sharedFields(data, "label", labelID)
			var label struct {
				model.Label
				BoardID string `json:"boardId"`
				Deleted bool   `json:"deleted"`
			}
			if err = decodeFields(labelFields, &label); err != nil {
				return nil, err
			}
			if label.BoardID == id && !label.Deleted {
				board.Labels = append(board.Labels, label.Label)
				conflicts = append(conflicts, lc...)
			}
		}
		fields["labels"] = rawValue(board.Labels)
		board.SharedBase, board.ConflictKeys = fields, conflicts
		if board.UpdatedAt == "" {
			board.UpdatedAt = board.CreatedAt
		}
		result = append(result, hydrateBoard(board))
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Name == result[j].Name {
			return result[i].ID < result[j].ID
		}
		return result[i].Name < result[j].Name
	})
	return result, nil
}

func (s *Store) checkoutsFrom(data PeerData) ([]model.Checkout, error) {
	result := []model.Checkout{}
	for _, id := range entityIDs(data, "checkout", "registration") {
		fields, _ := sharedFields(data, "checkout", id)
		var checkout model.Checkout
		if err := json.Unmarshal(fields["registration"], &checkout); err != nil {
			return nil, err
		}
		var local model.Checkout
		if err := readJSON(filepath.Join(s.Root, "checkouts", id+".json"), &local); err == nil && local.DaemonID == checkout.DaemonID {
			checkout.Path = local.Path
			checkout.ValidationCommands = local.ValidationCommands
		}
		checkout.ProjectID = canonicalProjectID(data, checkout.ProjectID)
		result = append(result, checkout)
	}
	return result, nil
}
func (s *Store) ListCheckouts(projectID string) ([]model.Checkout, error) {
	_, data, err := s.sharedData()
	if err != nil {
		return nil, err
	}
	all, err := s.checkoutsFrom(data)
	if err != nil {
		return nil, err
	}
	result := []model.Checkout{}
	for _, c := range all {
		if (projectID == "" || c.ProjectID == projectID) && !c.Detached {
			result = append(result, c)
		}
	}
	return result, nil
}
func (s *Store) localCheckout(projectID, checkoutID string) (model.Checkout, error) {
	values, err := s.ListCheckouts(projectID)
	if err != nil {
		return model.Checkout{}, err
	}
	var matches []model.Checkout
	for _, c := range values {
		if c.Path != "" && (checkoutID == "" || c.ID == checkoutID) {
			matches = append(matches, c)
		}
	}
	if len(matches) != 1 {
		return model.Checkout{}, errors.New("select one registered checkout on this machine")
	}
	return matches[0], nil
}
func (s *Store) ProjectForCheckout(projectID, checkoutID string) (model.Project, error) {
	project, err := s.ResolveProject(projectID)
	if err != nil {
		return project, err
	}
	checkout, err := s.localCheckout(project.ID, checkoutID)
	if err != nil {
		return project, err
	}
	project.Path, project.ValidationCommands = checkout.Path, checkout.ValidationCommands
	return project, nil
}
func (s *Store) AttachCheckout(projectID, path, name string) (model.Checkout, error) {
	path, err := normalizePath(path)
	if err != nil {
		return model.Checkout{}, err
	}
	if _, err = os.Stat(filepath.Join(path, ".git")); err != nil {
		return model.Checkout{}, errors.New("checkout must be an existing Git working tree")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Checkout{}, err
	}
	defer release()
	if _, err = s.ResolveProject(projectID); err != nil {
		return model.Checkout{}, err
	}
	return s.attachCheckout(projectID, path, name, nil)
}
func (s *Store) attachCheckout(projectID, path, name string, validation []model.ValidationCommand) (model.Checkout, error) {
	identity, err := s.sharedIdentity()
	if err != nil {
		return model.Checkout{}, err
	}
	values, err := s.ListCheckouts("")
	if err != nil {
		return model.Checkout{}, err
	}
	for _, c := range values {
		if c.Path == path {
			if c.ProjectID == projectID {
				return c, nil
			}
			return model.Checkout{}, fmt.Errorf("path is already attached to project %s", c.ProjectID)
		}
	}
	if name == "" {
		name = filepath.Base(path)
	}
	checkout := model.Checkout{ID: newID("co_"), ProjectID: projectID, DaemonID: identity.DaemonID, Name: name, Path: path, ValidationCommands: validation}
	return checkout, s.publishCheckout(checkout)
}
func (s *Store) publishCheckout(checkout model.Checkout) error {
	identity, err := s.sharedIdentity()
	if err != nil {
		return err
	}
	data, err := s.PeerData(identity.Account)
	data.State = clonePeerState(data.State)
	if err != nil {
		return err
	}
	if raw, ok := peerstore.Selected(data.Records[peerstore.Key("checkout", checkout.ID+".registration")]); ok {
		var original model.Checkout
		if err = json.Unmarshal(raw, &original); err != nil {
			return err
		}
		if original.DaemonID != identity.DaemonID {
			return errors.New("checkout belongs to another machine")
		}
		checkout.ProjectID, checkout.DaemonID = original.ProjectID, original.DaemonID
	}
	if err = applyFields(&data, identity, "checkout", checkout.ID, nil, checkoutFields(checkout)); err != nil {
		return err
	}
	return s.writePeerState(identity.Account, data, localEffect{Path: "checkouts/" + checkout.ID + ".json", Value: rawValue(checkout)})
}
func (s *Store) DetachCheckout(id string) error {
	release, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer release()
	var checkout model.Checkout
	if err = readJSON(filepath.Join(s.Root, "checkouts", id+".json"), &checkout); err != nil {
		return err
	}
	leases, err := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
	if err != nil {
		return err
	}
	for _, lease := range leases {
		card, e := s.ResolveCard(lease.CardID)
		if e == nil && card.CheckoutID == id {
			return ErrCardActive
		}
	}
	checkout.Detached = true
	return s.publishCheckout(checkout)
}
func (s *Store) RequireLocalCard(card model.Card) error {
	identity, err := s.PeerIdentity()
	if err != nil {
		return err
	}
	if card.OwnerDaemonID != identity.DaemonID {
		return fmt.Errorf("%w: %s", ErrRemoteConversation, card.OwnerDaemonID)
	}
	return nil
}

func itemFields(card model.Card) map[string]json.RawMessage {
	fields := pickFields(card, "item")
	fields["identity"] = rawValue(map[string]string{"id": card.ID, "projectId": card.ProjectID, "ownerDaemonId": card.OwnerDaemonID, "checkoutId": card.CheckoutID, "scope": card.Scope, "createdAt": card.CreatedAt})
	if original := card.SharedBase["identity"]; len(original) > 0 {
		fields["identity"] = original
	}
	fields["placement"] = rawValue(map[string]any{"boardId": card.BoardID, "lane": card.Lane, "orderKey": card.OrderKey, "phaseChangedAt": card.PhaseChangedAt})
	fields["summary"] = rawValue(map[string]any{"runtime": card.Runtime, "runtimeUpdatedAt": card.RuntimeUpdatedAt, "lastActivityAt": card.LastActivityAt, "provider": card.Provider, "model": card.Model, "effort": card.Effort, "initialPromptSentAt": card.InitialPromptSentAt, "responseSeq": card.ResponseSeq, "responseMessageId": card.ResponseMessageID, "seenResponseSeq": card.SeenResponseSeq, "mergedIntoCardId": card.MergedIntoCardID})
	return fields
}
func (s *Store) publishCard(card model.Card, effects ...localEffect) error {
	identity, err := s.sharedIdentity()
	if err != nil {
		return err
	}
	data, err := s.PeerData(identity.Account)
	data.State = clonePeerState(data.State)
	if err != nil {
		return err
	}
	fields := itemFields(card)
	if card.OwnerDaemonID != identity.DaemonID {
		delete(fields, "summary")
		delete(fields, "identity")
	}
	if err = applyFields(&data, identity, "item", card.ID, card.SharedBase, fields); err != nil {
		return err
	}
	oldLabels := []string{}
	_ = json.Unmarshal(card.SharedBase["labelIds"], &oldLabels)
	membership := map[string]bool{}
	for _, id := range oldLabels {
		membership[id] = false
	}
	for _, id := range card.LabelIDs {
		membership[id] = true
	}
	for id, member := range membership {
		if containsString(oldLabels, id) == member {
			continue
		}
		if err = applyFields(&data, identity, "assignment", card.ID+"."+id, nil, map[string]json.RawMessage{"membership": rawValue(member)}); err != nil {
			return err
		}
	}
	return s.writePeerState(identity.Account, data, effects...)
}
func sharedCard(data PeerData, id string, local model.Card) (model.Card, bool, error) {
	fields, conflicts := sharedFields(data, "item", id)
	if len(fields["identity"]) == 0 {
		return local, false, nil
	}
	if err := decodeFields(fields, &local); err != nil {
		return local, false, err
	}
	local.ProjectID = canonicalProjectID(data, local.ProjectID)
	if !sharedEntityReady(data, "project", local.ProjectID) || !sharedEntityReady(data, "checkout", local.CheckoutID) || len(fields["title"]) == 0 || len(fields["placement"]) == 0 || len(fields["archived"]) == 0 {
		return local, false, nil
	}
	if local.Scope == model.ConversationScopeBoard && !sharedEntityReady(data, "board", local.BoardID) {
		return local, false, nil
	}
	local.LabelIDs = nil
	for _, assignment := range data.Membership[id] {
		cardID, labelID, ok := strings.Cut(assignment, ".")
		if !ok || cardID != id {
			continue
		}
		record := data.Records[peerstore.Key("assignment", assignment+".membership")]
		// An observed removal wins a simultaneous add; new later assignments remain possible.
		member := false
		removed := false
		for _, v := range record.Versions {
			if bytes.Equal(v.Value, []byte("true")) {
				member = true
			} else {
				removed = true
			}
		}
		label, _ := sharedFields(data, "label", labelID)
		if member && !removed && len(label["identity"]) > 0 && !bytes.Equal(label["deleted"], []byte("true")) {
			local.LabelIDs = append(local.LabelIDs, labelID)
		}
	}
	sort.Strings(local.LabelIDs)
	fields["labelIds"] = rawValue(local.LabelIDs)
	local.SharedBase, local.ConflictKeys = fields, conflicts
	local.PlacementRevision = data.Records[peerstore.Key("item", id+".placement")].Revision()
	return local, true, nil
}
func (s *Store) overlayCard(local model.Card) (model.Card, error) {
	_, data, err := s.sharedData()
	if err != nil {
		return local, err
	}
	card, ok, err := sharedCard(data, local.ID, local)
	if err == nil && !ok {
		return model.Card{}, ErrNotFound
	}
	return card, err
}

func (s *Store) adoptLocalReplica(old, next PeerIdentity) error {
	source, err := s.PeerData(old.Account)
	if err != nil {
		return err
	}
	target, err := s.PeerData(next.Account)
	target.State = clonePeerState(target.State)
	if err != nil {
		return err
	}
	for key, record := range source.Records {
		entity, field := peerstore.SplitField(record.ID)
		if (record.Kind == "item" && field == "identity") || (record.Kind == "checkout" && field == "registration") || record.Kind == "schedule" {
			raw, ok := peerstore.Selected(record)
			if !ok {
				continue
			}
			var value map[string]any
			if err = json.Unmarshal(raw, &value); err != nil {
				return err
			}
			ownerKey := "ownerDaemonId"
			if record.Kind == "checkout" {
				ownerKey = "daemonId"
			}
			if value[ownerKey] == old.DaemonID {
				value[ownerKey] = next.DaemonID
				record, err = peerstore.Put(record, record.Kind, record.ID, next.Actor, record.Revision(), rawValue(value), false)
				if err != nil {
					return err
				}
				if record.Kind == "checkout" {
					var checkout model.Checkout
					path := filepath.Join(s.Root, "checkouts", entity+".json")
					if err = readJSON(path, &checkout); err != nil {
						return err
					}
					checkout.DaemonID = next.DaemonID
					if err = writeJSON(path, checkout); err != nil {
						return err
					}
				}
			}
		}
		merged, e := peerstore.Merge(target.Records[key], record)
		if e != nil {
			return e
		}
		target.Records[key] = merged
		target.Dirty[key] = true
	}
	if _, err := os.Stat(s.scheduleDatabasePath()); err == nil {
		db, err := s.scheduleDatabase()
		if err != nil {
			return err
		}
		schedules, err := s.listSchedules()
		if err != nil {
			return err
		}
		for _, item := range schedules {
			if item.OwnerDaemonID == old.DaemonID {
				item.OwnerDaemonID = next.DaemonID
				if err = upsertScheduleDocument(db, item); err != nil {
					return err
				}
			}
		}
	}
	return s.savePeerData(next.Account, target)
}

// Returned models carry the newly committed causal baseline, allowing another
// edit on that value without mistaking our own preceding save for a remote edit.
func (s *Store) saveCard(card model.Card) (model.Card, error) {
	if err := s.writeCard(card); err != nil {
		return model.Card{}, err
	}
	return s.overlayCard(card)
}
func (s *Store) saveBoard(board model.Board) (model.Board, error) {
	if err := s.writeBoard(board); err != nil {
		return model.Board{}, err
	}
	return s.ResolveBoard(board.ProjectID, board.ID)
}
func (s *Store) saveProject(project model.Project, effects ...localEffect) (model.Project, error) {
	if err := s.writeProject(project, effects...); err != nil {
		return model.Project{}, err
	}
	return s.ResolveProjectIncludingArchived(project.ID)
}

type projectReceipt struct{ ProjectID, Fingerprint string }

func initialBoardID(projectID string) string { return "b_" + peerstore.Revision(projectID)[:24] }
func (s *Store) InitialBoard(projectID string) (model.Board, error) {
	return s.ResolveBoard(projectID, initialBoardID(projectID))
}
func checkoutFields(checkout model.Checkout) map[string]json.RawMessage {
	return map[string]json.RawMessage{"registration": rawValue(map[string]any{"id": checkout.ID, "projectId": checkout.ProjectID, "daemonId": checkout.DaemonID, "name": checkout.Name, "detached": checkout.Detached})}
}

// Generic conflict resolution observes the same immutable identity and local
// owner rules as typed operations. It cannot reassign a durable conversation.
func (s *Store) validateDomainWrite(identity PeerIdentity, data PeerData, kind, id string, value []byte, deleted bool) error {
	if !peerstore.DomainKind(kind) {
		return nil
	}
	entity, field := peerstore.SplitField(id)
	old := data.Records[peerstore.Key(kind, id)]
	if kind == "project" && field == "consolidatedInto" {
		var destination string
		if deleted || json.Unmarshal(value, &destination) != nil || !peerstore.ValidID(destination) || destination == entity {
			return errors.New("invalid project consolidation destination")
		}
	}
	if field == "identity" && len(old.Versions) > 0 {
		for _, version := range old.Versions {
			if deleted || !bytes.Equal(rawValue(json.RawMessage(value)), version.Value) {
				return errors.New("shared identity is immutable")
			}
		}
	}
	if kind == "item" && (field == "identity" || field == "summary") {
		card, ok, err := sharedCard(data, entity, model.Card{})
		if err != nil {
			return err
		}
		if !ok && field == "identity" {
			_ = json.Unmarshal(value, &card)
		}
		if card.OwnerDaemonID != identity.DaemonID {
			return ErrRemoteConversation
		}
	}
	if kind == "checkout" {
		var checkout model.Checkout
		if err := json.Unmarshal(value, &checkout); err != nil {
			return err
		}
		if deleted || checkout.DaemonID != identity.DaemonID {
			return errors.New("checkout changes require its machine")
		}
		for _, version := range old.Versions {
			var previous model.Checkout
			_ = json.Unmarshal(version.Value, &previous)
			if previous.ProjectID != checkout.ProjectID || previous.DaemonID != checkout.DaemonID {
				return errors.New("checkout identity is immutable")
			}
		}
	}
	return nil
}

func sharedEntityReady(data PeerData, kind, id string) bool {
	fields, _ := sharedFields(data, kind, id)
	switch kind {
	case "project":
		return len(fields["identity"]) > 0 && len(fields["name"]) > 0 && len(fields["archived"]) > 0
	case "board":
		return len(fields["identity"]) > 0 && len(fields["name"]) > 0 && len(fields["workflow"]) > 0
	case "checkout":
		return len(fields["registration"]) > 0
	}
	return false
}
