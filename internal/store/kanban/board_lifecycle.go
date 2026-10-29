package kanban

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/replica"
)

const absentBoardRetirement = "absent"

// All surviving placement/schedule siblings count, including archived items and
// incomplete dependencies. The index is built once, without projecting cards.
func boardReferenceIndex(data replica.PeerData) map[string][]string {
	refs := map[string][]string{}
	visit := func(record crdt.Record) error {
		id, field := crdt.SplitField(record.ID)
		if !(record.Kind == "item" && field == "placement" || record.Kind == "schedule" && field == "summary") {
			return nil
		}
		for _, version := range record.Versions {
			if version.Deleted {
				continue
			}
			var value struct {
				BoardID string `json:"boardId"`
				Deleted bool   `json:"deleted"`
			}
			if json.Unmarshal(version.Value, &value) != nil || value.BoardID == "" || value.Deleted {
				continue
			}
			if len(refs[value.BoardID]) < 64 && !containsString(refs[value.BoardID], record.Kind+"/"+id) {
				refs[value.BoardID] = append(refs[value.BoardID], record.Kind+"/"+id)
			}
		}
		return nil
	}
	data.Fail(data.EachMatching("item/", ".placement", visit))
	data.Fail(data.EachMatching("schedule/", ".summary", visit))
	for board, values := range refs {
		sort.Strings(values)
		unique := values[:0]
		for _, value := range values {
			if len(unique) == 0 || unique[len(unique)-1] != value {
				unique = append(unique, value)
			}
		}
		if len(unique) > 64 {
			unique = unique[:64]
		}
		refs[board] = unique
	}
	return refs
}

func projectBoardRetirement(board *model.Board, record crdt.Record, references []string) {
	board.RetirementRevision = record.Revision()
	if board.RetirementRevision == "" {
		board.RetirementRevision = absentBoardRetirement
	}
	board.Retired, board.RetirementBlocked = false, false
	board.RetirementVersions, board.RetirementReferences = nil, nil
	requested := false
	for _, v := range record.Versions {
		var retired bool
		_ = json.Unmarshal(v.Value, &retired)
		requested = requested || !v.Deleted && retired
		board.RetirementVersions = append(board.RetirementVersions, model.BoardRetirementVersion{Clock: v.Clock, Rank: crdt.PresentationRank(v), Retired: retired, Deleted: v.Deleted})
	}
	// Any unresolved intent or surviving reference keeps the board accessible.
	board.RetirementBlocked = requested && (len(record.Versions) != 1 || len(references) > 0)
	board.Retired = requested && !board.RetirementBlocked
	if requested {
		board.RetirementReferences = append([]string(nil), references...)
	}
}

// GetBoard uses an exact identity and includes retired boards and archived
// projects. Mutations requiring an active board must still use ResolveBoard.
func (s *Store) GetBoard(id string) (model.Board, error) {
	boards, err := s.sharedBoards()
	if err != nil {
		return model.Board{}, err
	}
	for _, board := range boards {
		if board.ID == id {
			return board, nil
		}
	}
	return model.Board{}, fmt.Errorf("board %q: %w", id, home.ErrNotFound)
}

type RetiredBoardPage struct {
	Boards           []model.Board
	NextID, Revision string
}

func (s *Store) ListRetiredBoards(projectID, after, revision string, limit int) (RetiredBoardPage, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 100 {
		return RetiredBoardPage{}, fault.New(fault.Invalid, "page size must not exceed 100")
	}
	boards, err := s.sharedBoards()
	if err != nil {
		return RetiredBoardPage{}, err
	}
	values := []model.Board{}
	for _, board := range boards {
		if board.Retired && (projectID == "" || projectID == board.ProjectID) {
			values = append(values, board)
		}
	}
	sort.Slice(values, func(i, j int) bool { return values[i].ID < values[j].ID })
	page := RetiredBoardPage{Revision: crdt.Revision(values)}
	if revision != "" && revision != page.Revision {
		return page, crdt.ErrConflict
	}
	if after != "" && revision == "" {
		return page, fault.New(fault.Invalid, "continuation requires snapshot revision")
	}
	for _, board := range values {
		if board.ID <= after {
			continue
		}
		if len(page.Boards) == limit {
			page.NextID = page.Boards[len(page.Boards)-1].ID
			break
		}
		page.Boards = append(page.Boards, board)
	}
	return page, nil
}

type BoardRetirementInput struct {
	BoardID, ExpectedRevision, OperationID string
	Retired                                bool
}

// SetBoardRetired commits the intent and durable replay receipt atomically.
// Emptiness is a local admission check, never a claim of global linearizability.
func (s *Store) SetBoardRetired(input BoardRetirementInput) (model.Board, error) {
	var zero model.Board
	if !crdt.ValidID(input.BoardID) || !crdt.ValidID(input.OperationID) || strings.TrimSpace(input.ExpectedRevision) == "" {
		return zero, fault.New(fault.Invalid, "exact board ID, observed lifecycle revision and operation ID required")
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return zero, err
	}
	defer release()
	identity, err := s.replica.WriterIdentity()
	if err != nil {
		return zero, err
	}
	receiptID, fingerprint := "board-retirement/"+input.OperationID, crdt.Revision(input)
	oldFingerprint, raw, found, err := s.replica.LookupReceipt(identity.Account, receiptID)
	if err != nil {
		return zero, err
	}
	if found {
		if oldFingerprint != fingerprint {
			return zero, fault.New(fault.Invalid, "operation ID reused with different input")
		}
		err = json.Unmarshal(raw, &zero)
		return zero, err
	}
	board, err := s.GetBoard(input.BoardID)
	if err != nil {
		return zero, err
	}
	if board.RetirementRevision != input.ExpectedRevision {
		return zero, crdt.ErrConflict
	}
	data, err := s.replica.OpenPeerView(identity.Account)
	if err != nil {
		return zero, err
	}
	refs := boardReferenceIndex(data)[board.ID]
	if err := data.Err(); err != nil {
		return zero, err
	}
	if input.Retired {
		// Check raw owner files too: unresolved projection dependencies must not
		// hide a surviving local card or a schedule awaiting outbox publication.
		for _, directory := range []string{s.home.CardDir(), s.home.ArchivedCardDir()} {
			paths, err := home.ListMarkdown(directory)
			if err != nil {
				return zero, err
			}
			for _, path := range paths {
				var card model.Card
				if _, err := home.ReadMarkdown(path, &card); err != nil {
					return zero, err
				}
				if card.BoardID == board.ID {
					return zero, fault.Invalidf("board has surviving card %s", card.ID)
				}
			}
		}
		if scheduleOnBoard := s.hooks.ScheduleOnBoard; scheduleOnBoard != nil {
			id, err := scheduleOnBoard(board.ID)
			if err != nil {
				return zero, err
			}
			if id != "" {
				return zero, fault.Invalidf("board has surviving schedule %s", id)
			}
		}
		if len(refs) > 0 {
			return zero, fault.Invalidf("board has surviving references: %s", strings.Join(refs, ", "))
		}
	}
	data.State = replica.ClonePeerState(data.State)
	key := crdt.Key("board", board.ID+".retired")
	old := data.Record(key)
	next, err := crdt.Put(old, "board", board.ID+".retired", identity.Actor, old.Revision(), replica.RawValue(input.Retired), false)
	if err != nil {
		return zero, err
	}
	data.Records[key], data.Dirty[key] = next, true
	projectBoardRetirement(&board, next, refs)
	// This operation explicitly covers all observed lifecycle siblings.
	conflicts := board.ConflictKeys[:0]
	for _, conflict := range board.ConflictKeys {
		if conflict != key {
			conflicts = append(conflicts, conflict)
		}
	}
	board.ConflictKeys = conflicts
	raw, err = json.Marshal(board)
	if err != nil {
		return zero, err
	}
	err = s.replica.WritePeerStateReceipt(identity.Account, data, &replica.Receipt{ID: receiptID, Fingerprint: fingerprint, Value: raw})
	return board, err
}
