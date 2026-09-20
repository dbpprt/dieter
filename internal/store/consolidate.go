package store

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
)

// A consolidation is a durable redirect. Boards, labels, conversation identities
// and owner-local files retain their IDs; projections resolve their project
// reference. A stale peer cannot recreate a second project by editing its name.
func canonicalProjectID(data PeerData, id string) string {
	original := id
	seen := map[string]int{}
	var path []string
	for len(path) < peerstore.MaxRecords {
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
		record := data.Records[peerstore.Key("project", id+".consolidatedInto")]
		if len(record.Versions) != 1 {
			return id
		}
		raw, ok := peerstore.Selected(record)
		if !ok {
			return id
		}
		var next string
		if json.Unmarshal(raw, &next) != nil || next == "" {
			return id
		}
		if _, ok = peerstore.Selected(data.Records[peerstore.Key("project", next+".identity")]); !ok {
			return original
		}
		id = next
	}
	return original
}
func (s *Store) canonicalProjectRef(ref string) string {
	_, data, err := s.sharedData()
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
		return model.Project{}, fmt.Errorf("%w: resolve project settings before consolidation", peerstore.ErrConflict)
	}
	identity, data, err := s.sharedData()
	if err != nil {
		return model.Project{}, err
	}
	data.State = clonePeerState(data.State)
	key := peerstore.Key("project", source.ID+".consolidatedInto")
	if len(data.Records[key].Versions) > 0 {
		return model.Project{}, errors.New("source already has a consolidation destination")
	}
	if err = applyFields(&data, identity, "project", source.ID, nil, map[string]json.RawMessage{"consolidatedInto": rawValue(destination.ID)}); err != nil {
		return model.Project{}, err
	}
	if err = s.savePeerData(identity.Account, data); err != nil {
		return model.Project{}, err
	}
	return s.ResolveProject(destination.ID)
}
