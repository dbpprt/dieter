package store

import (
	"encoding/json"
	"fmt"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
)

// A consolidation is a durable redirect. Boards, labels, conversation identities
// and owner-local files retain their IDs; projections resolve their project
// reference. A stale peer cannot recreate a second project by editing its name.
func canonicalProjectID(data PeerData, id string) string {
	original := id
	seen := map[string]int{}
	var path []string
	for len(path) < crdt.MaxRecords {
		if at, ok := seen[id]; ok {
			root := id
			for _, candidate := range path[at:] {
				if candidate < root {
					root = candidate
				}
			}
			return root
		}
		seen[id] = len(path)
		path = append(path, id)
		record := data.record(crdt.Key("project", id+".consolidatedInto"))
		if len(record.Versions) != 1 {
			return id
		}
		raw, ok := crdt.Selected(record)
		if !ok {
			return id
		}
		var next string
		if json.Unmarshal(raw, &next) != nil || next == "" {
			return id
		}
		if _, ok = crdt.Selected(data.record(crdt.Key("project", next+".identity"))); !ok {
			return original
		}
		id = next
	}
	return original
}
func (s *Store) canonicalProjectRef(ref string) string {
	_, data, err := s.sharedData()
	defer data.Close()
	if err != nil {
		return ref
	}
	return canonicalProjectID(data, ref)
}

func (s *Store) ConsolidateProject(sourceRef, destinationRef string) (model.Project, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	destination, err := s.ResolveProject(destinationRef)
	if err != nil {
		return model.Project{}, err
	}
	source, err := s.ResolveProjectIncludingArchived(sourceRef)
	if err != nil {
		return model.Project{}, err
	}
	if source.ID == destination.ID {
		return destination, nil
	}
	if len(source.ConflictKeys) > 0 || len(destination.ConflictKeys) > 0 {
		return model.Project{}, fmt.Errorf("%w: resolve project settings before consolidation", crdt.ErrConflict)
	}
	identity, data, err := s.sharedData()
	defer data.Close()
	if err != nil {
		return model.Project{}, err
	}
	data.State = clonePeerState(data.State)
	key := crdt.Key("project", source.ID+".consolidatedInto")
	if len(data.record(key).Versions) > 0 {
		return model.Project{}, fault.New(fault.Invalid, "source already has a consolidation destination")
	}
	if err = applyFields(&data, identity, "project", source.ID, nil, map[string]json.RawMessage{"consolidatedInto": rawValue(destination.ID)}); err != nil {
		return model.Project{}, err
	}
	if err = s.savePeerData(identity.Account, data); err != nil {
		return model.Project{}, err
	}
	return s.ResolveProject(destination.ID)
}
