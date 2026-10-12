package kanban

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/leases"
	"github.com/dbpprt/dieter/internal/store/replica"
)

var ErrRemoteConversation = fault.New(fault.FailedPrecondition, "conversation belongs to another machine; target its owner")

func (s *Store) writeProject(project model.Project, effects ...replica.Effect) error {
	identity, err := s.replica.WriterIdentity()
	if err != nil {
		return err
	}
	data, err := s.replica.OpenPeerView(identity.Account)
	data.State = replica.ClonePeerState(data.State)
	if err != nil {
		return err
	}
	next := replica.PickFields(project, "project")
	next["identity"] = replica.RawValue(map[string]any{"id": project.ID, "createdAt": project.CreatedAt})
	if err = replica.ApplyFields(&data, identity, "project", project.ID, project.SharedBase, next); err != nil {
		return err
	}
	return s.replica.WritePeerState(identity.Account, data, effects...)
}
func (s *Store) sharedProjects() ([]model.Project, error) {
	_, data, err := s.replica.Snapshot()
	defer data.Close()
	if err != nil {
		return nil, err
	}
	checkouts, err := s.checkoutsFrom(data)
	if err != nil {
		return nil, err
	}
	projects := []model.Project{}
	for _, id := range replica.EntityIDs(data, "project", "identity") {
		if CanonicalProjectID(data, id) != id {
			continue
		}
		fields, conflicts := replica.EntityFields(data, "project", id)
		if len(fields["name"]) == 0 || len(fields["archived"]) == 0 {
			continue
		}
		var project model.Project
		if err = replica.DecodeFields(fields, &project); err != nil {
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
	return projects, data.Err()
}
func (s *Store) writeBoard(board model.Board) error {
	identity, err := s.replica.WriterIdentity()
	if err != nil {
		return err
	}
	data, err := s.replica.OpenPeerView(identity.Account)
	data.State = replica.ClonePeerState(data.State)
	if err != nil {
		return err
	}
	next := replica.PickFields(board, "board")
	next["identity"] = replica.RawValue(map[string]any{"id": board.ID, "projectId": board.ProjectID, "createdAt": board.CreatedAt})
	if original := board.SharedBase["identity"]; len(original) > 0 {
		next["identity"] = original
	}
	if err = replica.ApplyFields(&data, identity, "board", board.ID, board.SharedBase, next); err != nil {
		return err
	}
	var previous []model.Label
	_ = json.Unmarshal(board.SharedBase["labels"], &previous)
	previousByID := map[string]model.Label{}
	for _, label := range previous {
		previousByID[label.ID] = label
	}
	for _, label := range board.Labels {
		fields := replica.PickFields(label, "label")
		fields["identity"] = replica.RawValue(map[string]string{"id": label.ID, "boardId": board.ID})
		before := map[string]json.RawMessage{}
		if old, ok := previousByID[label.ID]; ok {
			before = replica.PickFields(old, "label")
			before["identity"] = fields["identity"]
		}
		if err = replica.ApplyFields(&data, identity, "label", label.ID, before, fields); err != nil {
			return err
		}
		delete(previousByID, label.ID)
	}
	for id := range previousByID {
		if err = replica.ApplyFields(&data, identity, "label", id, nil, map[string]json.RawMessage{"deleted": replica.RawValue(true)}); err != nil {
			return err
		}
	}
	return s.replica.SavePeerData(identity.Account, data)
}
func (s *Store) sharedBoards() ([]model.Board, error) {
	_, data, err := s.replica.Snapshot()
	defer data.Close()
	if err != nil {
		return nil, err
	}
	result := []model.Board{}
	references := boardReferenceIndex(data)
	labelIDs := replica.EntityIDs(data, "label", "identity")
	for _, id := range replica.EntityIDs(data, "board", "identity") {
		fields, conflicts := replica.EntityFields(data, "board", id)
		var board model.Board
		if err = replica.DecodeFields(fields, &board); err != nil {
			return nil, err
		}
		board.ProjectID = CanonicalProjectID(data, board.ProjectID)
		if !sharedEntityReady(data, "project", board.ProjectID) || len(fields["name"]) == 0 || len(fields["workflow"]) == 0 {
			continue
		}
		projectBoardRetirement(&board, data.Record(crdt.Key("board", id+".retired")), references[id])
		for _, labelID := range labelIDs {
			labelFields, lc := replica.EntityFields(data, "label", labelID)
			var label struct {
				model.Label
				BoardID string `json:"boardId"`
				Deleted bool   `json:"deleted"`
			}
			if err = replica.DecodeFields(labelFields, &label); err != nil {
				return nil, err
			}
			if label.BoardID == id && !label.Deleted {
				board.Labels = append(board.Labels, label.Label)
				conflicts = append(conflicts, lc...)
			}
		}
		fields["labels"] = replica.RawValue(board.Labels)
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
	return result, data.Err()
}

func (s *Store) checkoutsFrom(data replica.PeerData) ([]model.Checkout, error) {
	result := []model.Checkout{}
	for _, id := range replica.EntityIDs(data, "checkout", "registration") {
		fields, _ := replica.EntityFields(data, "checkout", id)
		var checkout model.Checkout
		if err := json.Unmarshal(fields["registration"], &checkout); err != nil {
			return nil, err
		}
		var local model.Checkout
		if err := home.ReadJSON(filepath.Join(s.home.Root, "checkouts", id+".json"), &local); err == nil && local.DaemonID == checkout.DaemonID {
			checkout.Path = local.Path
			checkout.ValidationCommands = local.ValidationCommands
		}
		checkout.ProjectID = CanonicalProjectID(data, checkout.ProjectID)
		result = append(result, checkout)
	}
	return result, data.Err()
}
func (s *Store) ListCheckouts(projectID string) ([]model.Checkout, error) {
	_, data, err := s.replica.Snapshot()
	defer data.Close()
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
	return result, data.Err()
}

// OwnedCheckouts are this machine's attached checkouts with what only it
// knows: their paths and validation commands.
func (s *Store) OwnedCheckouts() ([]model.Checkout, error) {
	values, err := s.ListCheckouts("")
	if err != nil {
		return nil, err
	}
	result := []model.Checkout{}
	for _, checkout := range values {
		if checkout.Path != "" {
			result = append(result, checkout)
		}
	}
	return result, nil
}

func (s *Store) LocalCheckout(projectID, checkoutID string) (model.Checkout, error) {
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
		return model.Checkout{}, fault.New(fault.Invalid, "select one registered checkout on this machine")
	}
	return matches[0], nil
}
func (s *Store) ProjectForCheckout(projectID, checkoutID string) (model.Project, error) {
	project, err := s.ResolveProject(projectID)
	if err != nil {
		return project, err
	}
	checkout, err := s.LocalCheckout(project.ID, checkoutID)
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
		return model.Checkout{}, fault.New(fault.Invalid, "checkout must be an existing Git working tree")
	}
	release, err := s.home.BeginWrite()
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
	identity, err := s.replica.WriterIdentity()
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
			return model.Checkout{}, fault.Invalidf("path is already attached to project %s", c.ProjectID)
		}
	}
	if name == "" {
		name = filepath.Base(path)
	}
	checkout := model.Checkout{ID: home.NewID("co_"), ProjectID: projectID, DaemonID: identity.DaemonID, Name: name, Path: path, ValidationCommands: validation}
	return checkout, s.publishCheckout(checkout)
}
func (s *Store) publishCheckout(checkout model.Checkout) error {
	identity, err := s.replica.WriterIdentity()
	if err != nil {
		return err
	}
	data, err := s.replica.OpenPeerView(identity.Account)
	data.State = replica.ClonePeerState(data.State)
	if err != nil {
		return err
	}
	if raw, ok := crdt.Selected(data.Record(crdt.Key("checkout", checkout.ID+".registration"))); ok {
		var original model.Checkout
		if err = json.Unmarshal(raw, &original); err != nil {
			return err
		}
		if original.DaemonID != identity.DaemonID {
			return fault.New(fault.Invalid, "checkout belongs to another machine")
		}
		checkout.ProjectID, checkout.DaemonID = original.ProjectID, original.DaemonID
	}
	if err = replica.ApplyFields(&data, identity, "checkout", checkout.ID, nil, checkoutFields(checkout)); err != nil {
		return err
	}
	return s.replica.WritePeerState(identity.Account, data, replica.Effect{Path: "checkouts/" + checkout.ID + ".json", Value: replica.RawValue(checkout)})
}
func (s *Store) DetachCheckout(id string) error {
	release, err := s.home.BeginWrite()
	if err != nil {
		return err
	}
	defer release()
	var checkout model.Checkout
	if err = home.ReadJSON(filepath.Join(s.home.Root, "checkouts", id+".json"), &checkout); err != nil {
		return err
	}
	activeLeases, err := s.leases.Active()
	if err != nil {
		return err
	}
	for _, lease := range activeLeases {
		card, e := s.ResolveCard(lease.CardID)
		if e == nil && card.CheckoutID == id {
			return leases.ErrCardActive
		}
	}
	checkout.Detached = true
	return s.publishCheckout(checkout)
}
func (s *Store) RequireLocalCard(card model.Card) error {
	identity, err := s.replica.PeerIdentity()
	if err != nil {
		return err
	}
	if card.OwnerDaemonID != identity.DaemonID {
		return fmt.Errorf("%w: %s", ErrRemoteConversation, card.OwnerDaemonID)
	}
	return nil
}

func itemFields(card model.Card) map[string]json.RawMessage {
	fields := replica.PickFields(card, "item")
	fields["identity"] = replica.RawValue(map[string]string{"id": card.ID, "projectId": card.ProjectID, "ownerDaemonId": card.OwnerDaemonID, "checkoutId": card.CheckoutID, "scope": card.Scope, "createdAt": card.CreatedAt})
	if original := card.SharedBase["identity"]; len(original) > 0 {
		fields["identity"] = original
	}
	fields["placement"] = replica.RawValue(map[string]any{"boardId": card.BoardID, "lane": card.Lane, "orderKey": card.OrderKey, "phaseChangedAt": card.PhaseChangedAt})
	fields["summary"] = replica.RawValue(map[string]any{"runtime": card.Runtime, "runtimeUpdatedAt": card.RuntimeUpdatedAt, "lastActivityAt": card.LastActivityAt, "provider": card.Provider, "model": card.Model, "effort": card.Effort, "initialPromptSentAt": card.InitialPromptSentAt, "responseSeq": card.ResponseSeq, "responseMessageId": card.ResponseMessageID, "seenResponseSeq": card.SeenResponseSeq, "mergedIntoCardId": card.MergedIntoCardID})
	return fields
}
func (s *Store) publishCard(card model.Card, effects ...replica.Effect) error {
	identity, err := s.replica.WriterIdentity()
	if err != nil {
		return err
	}
	data, err := s.replica.OpenPeerView(identity.Account)
	data.State = replica.ClonePeerState(data.State)
	if err != nil {
		return err
	}
	fields := itemFields(card)
	if card.OwnerDaemonID != identity.DaemonID {
		delete(fields, "summary")
		delete(fields, "identity")
	}
	if err = replica.ApplyFields(&data, identity, "item", card.ID, card.SharedBase, fields); err != nil {
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
		if err = replica.ApplyFields(&data, identity, "assignment", card.ID+"."+id, nil, map[string]json.RawMessage{"membership": replica.RawValue(member)}); err != nil {
			return err
		}
	}
	return s.replica.WritePeerState(identity.Account, data, effects...)
}
func SharedCard(data replica.PeerData, id string, local model.Card) (model.Card, bool, error) {
	fields, conflicts := replica.EntityFields(data, "item", id)
	if err := data.Err(); err != nil {
		return local, false, err
	}
	if len(fields["identity"]) == 0 {
		return local, false, data.Err()
	}
	if err := replica.DecodeFields(fields, &local); err != nil {
		return local, false, err
	}
	local.ProjectID = CanonicalProjectID(data, local.ProjectID)
	if !sharedEntityReady(data, "project", local.ProjectID) || !sharedEntityReady(data, "checkout", local.CheckoutID) || len(fields["title"]) == 0 || len(fields["placement"]) == 0 || len(fields["archived"]) == 0 {
		return local, false, data.Err()
	}
	if local.Scope == model.ConversationScopeBoard && !sharedEntityReady(data, "board", local.BoardID) {
		return local, false, data.Err()
	}
	local.LabelIDs = nil
	for _, assignment := range data.AssignmentIDs(id) {
		cardID, labelID, ok := strings.Cut(assignment, ".")
		if !ok || cardID != id {
			continue
		}
		record := data.Record(crdt.Key("assignment", assignment+".membership"))
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
		label, _ := replica.EntityFields(data, "label", labelID)
		if member && !removed && len(label["identity"]) > 0 && !bytes.Equal(label["deleted"], []byte("true")) {
			local.LabelIDs = append(local.LabelIDs, labelID)
		}
	}
	sort.Strings(local.LabelIDs)
	fields["labelIds"] = replica.RawValue(local.LabelIDs)
	local.SharedBase, local.ConflictKeys = fields, conflicts
	local.PlacementRevision = data.Record(crdt.Key("item", id+".placement")).ValueRevision()
	local.StateFields = nil
	// These independent registers must never be compared using card timestamps
	// or the arrival order of snapshots from different replicas.
	for _, name := range []string{"placement", "summary"} {
		record := data.Record(crdt.Key("item", id+"."+name))
		field := model.CardStateField{Name: name, Revision: record.ValueRevision()}
		for _, version := range record.Versions {
			value := model.Card{}
			if !version.Deleted {
				if err := json.Unmarshal(version.Value, &value); err != nil {
					return local, false, err
				}
			}
			field.Versions = append(field.Versions, model.CardStateVersion{
				Clock: version.Clock, Rank: crdt.PresentationRank(version), Value: &value, Deleted: version.Deleted,
			})
		}
		// Clients compare the normalized frontier to recognize a daemon CAS
		// receipt. Raw peer ordering can change when authentication is renewed.
		sort.Slice(field.Versions, func(i, j int) bool { return field.Versions[i].Rank < field.Versions[j].Rank })
		local.StateFields = append(local.StateFields, field)
	}
	return local, true, data.Err()
}
func (s *Store) overlayCard(local model.Card) (model.Card, error) {
	_, data, err := s.replica.Snapshot()
	defer data.Close()
	if err != nil {
		return local, err
	}
	card, ok, err := SharedCard(data, local.ID, local)
	if err == nil && !ok {
		return model.Card{}, home.ErrNotFound
	}
	return card, err
}

// AdoptOwnerRecord moves the local file of an adopted checkout registration
// to the enrolled daemon. Adoption retries until it completes; this is idempotent.
func (s *Store) AdoptOwnerRecord(kind, entity string, old, next replica.PeerIdentity) error {
	if kind != "checkout" {
		return nil
	}
	var checkout model.Checkout
	path := filepath.Join(s.home.Root, "checkouts", entity+".json")
	if err := home.ReadJSON(path, &checkout); err != nil {
		return err
	}
	checkout.DaemonID = next.DaemonID
	return home.WriteJSON(path, checkout)
}

// Returned models carry the newly committed causal baseline, allowing another
// edit on that value without mistaking our own preceding save for a remote edit.
func (s *Store) SaveCard(card model.Card) (model.Card, error) {
	if err := s.WriteCard(card); err != nil {
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
func (s *Store) saveProject(project model.Project, effects ...replica.Effect) (model.Project, error) {
	if err := s.writeProject(project, effects...); err != nil {
		return model.Project{}, err
	}
	return s.ResolveProjectIncludingArchived(project.ID)
}

type projectReceipt struct{ ProjectID, Fingerprint string }

func initialBoardID(projectID string) string { return "b_" + crdt.Revision(projectID)[:24] }
func (s *Store) InitialBoard(projectID string) (model.Board, error) {
	return s.ResolveBoard(projectID, initialBoardID(projectID))
}
func checkoutFields(checkout model.Checkout) map[string]json.RawMessage {
	return map[string]json.RawMessage{"registration": replica.RawValue(map[string]any{"id": checkout.ID, "projectId": checkout.ProjectID, "daemonId": checkout.DaemonID, "name": checkout.Name, "detached": checkout.Detached})}
}

// Generic conflict resolution observes the same immutable identity and local
// owner rules as typed operations. It cannot reassign a durable conversation.
func (s *Store) ValidatePeerWrite(identity replica.PeerIdentity, data replica.PeerData, kind, id string, value []byte, deleted bool) error {
	// Only the vault metadata record may be resolved generically, after two
	// machines initialized a vault concurrently. Members and items are sealed.
	if schema.VaultKind(kind) && kind != "vault" {
		return fault.New(fault.Invalid, "vault members and items change only through `dieter vault`")
	}
	if !schema.DomainKind(kind) {
		return nil
	}
	entity, field := crdt.SplitField(id)
	old := data.Record(crdt.Key(kind, id))
	if kind == "project" && field == "consolidatedInto" {
		var destination string
		if deleted || json.Unmarshal(value, &destination) != nil || !crdt.ValidID(destination) || destination == entity {
			return fault.New(fault.Invalid, "invalid project consolidation destination")
		}
	}
	if field == "identity" && len(old.Versions) > 0 {
		for _, version := range old.Versions {
			if deleted || !bytes.Equal(replica.RawValue(json.RawMessage(value)), version.Value) {
				return fault.New(fault.Invalid, "shared identity is immutable")
			}
		}
	}
	if kind == "item" && (field == "identity" || field == "summary") {
		card, ok, err := SharedCard(data, entity, model.Card{})
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
			return fault.New(fault.Invalid, "checkout changes require its machine")
		}
		for _, version := range old.Versions {
			var previous model.Checkout
			_ = json.Unmarshal(version.Value, &previous)
			if previous.ProjectID != checkout.ProjectID || previous.DaemonID != checkout.DaemonID {
				return fault.New(fault.Invalid, "checkout identity is immutable")
			}
		}
	}
	return nil
}

func sharedEntityReady(data replica.PeerData, kind, id string) bool {
	fields, _ := replica.EntityFields(data, kind, id)
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

// RequireLocalConversation fails with ErrRemoteConversation unless this machine
// owns the conversation of cardID: its card file exists here and its shared
// identity names this daemon.
func (s *Store) RequireLocalConversation(cardID string) error {
	// A replicated directory entry is never a local conversation.
	if !s.cardExists(cardID) {
		return ErrRemoteConversation
	}
	identity, data, identityErr := s.replica.Snapshot()
	defer data.Close()
	if identityErr != nil {
		return identityErr
	}
	fields, _ := replica.EntityFields(data, "item", cardID)
	if err := data.Err(); err != nil {
		return err
	}
	var owner struct {
		OwnerDaemonID string `json:"ownerDaemonId"`
	}
	if json.Unmarshal(fields["identity"], &owner) != nil || owner.OwnerDaemonID != identity.DaemonID {
		return ErrRemoteConversation
	}
	return nil
}

// Hooks connect the directory to the aggregates built on it. The
// composition root sets them once, before the store is used.
type Hooks struct {
	// Ensure prepares the whole store before a project is created.
	Ensure func() error
	// WorkspaceSummary, PullRequestSummary and TokenUsage supply a local
	// card's owner-only details (nil when absent).
	WorkspaceSummary   func(cardID string) *model.WorkspaceSummary
	PullRequestSummary func(cardID string) *model.PullRequestSummary
	TokenUsage         func(cardID string) *model.TokenUsage
	// ScheduleOnBoard returns a local schedule that still targets boardID ("" if none).
	ScheduleOnBoard func(boardID string) (string, error)
}

// SetHooks installs the hooks. Call it before the store is used.
func (s *Store) SetHooks(hooks Hooks) { s.hooks = hooks }
