package replica

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
)

// RawValue is the JSON encoding of value (nil on failure).
func RawValue(value any) json.RawMessage { raw, _ := json.Marshal(value); return raw }

func objectFields(value any) map[string]json.RawMessage {
	fields := map[string]json.RawMessage{}
	_ = json.Unmarshal(RawValue(value), &fields)
	return fields
}

// EntityFields reads one domain entity from its per-field records: the
// selected value of every schema field and the keys of conflicted fields.
func EntityFields(data PeerData, kind, id string) (map[string]json.RawMessage, []string) {
	data.primeEntity(kind, id)
	fields := map[string]json.RawMessage{}
	var conflicts []string
	for field := range schema.DomainFields[kind] {
		record := data.Record(crdt.Key(kind, id+"."+field))
		if len(record.Versions) > 1 && field != "updatedAt" {
			conflicts = append(conflicts, crdt.Key(kind, record.ID))
		}
		if raw, ok := crdt.Selected(record); ok {
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

// DecodeFields decodes entity fields into value, flattening nested objects.
func DecodeFields(fields map[string]json.RawMessage, value any) error {
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
	return json.Unmarshal(RawValue(flattened), value)
}

// EntityIDs lists the entities of kind that have a selected field.
func EntityIDs(data PeerData, kind, field string) []string {
	if data.view == nil {
		if data.EntityIDs == nil {
			indexPeerData(&data)
		}
		return data.EntityIDs[kind+"/"+field]
	}
	var ids []string
	err := data.EachMatching(kind+"/", "."+field, func(record crdt.Record) error {
		entity, suffix := crdt.SplitField(record.ID)
		if suffix == field {
			if _, ok := crdt.Selected(record); ok {
				ids = append(ids, entity)
			}
		}
		return nil
	})
	data.Fail(err)
	return ids
}

// ApplyFields records the changed fields of an entity as new versions, failing
// on concurrent siblings or values that changed since they were read (before).
func ApplyFields(data *PeerData, identity PeerIdentity, kind, id string, before, next map[string]json.RawMessage) error {
	for field, value := range next {
		if bytes.Equal(before[field], value) {
			continue
		}
		key := crdt.Key(kind, id+"."+field)
		old := data.Record(key)
		// A normal form save cannot discard concurrent siblings. The explicit peer
		// resolution endpoint requires the current revision and covers all siblings.
		if len(old.Versions) > 1 && field != "updatedAt" && !(kind == "item" && (field == "placement" || field == "pinned") || kind == "assignment" && field == "membership") {
			return fmt.Errorf("%w: %s", crdt.ErrConflict, key)
		}
		if current, ok := crdt.Selected(old); ok && bytes.Equal(current, value) {
			continue
		}
		if observed, ok := before[field]; ok && len(old.Versions) > 0 {
			current, _ := crdt.Selected(old)
			if !bytes.Equal(current, observed) {
				return fmt.Errorf("%w: %s changed since read", crdt.ErrConflict, key)
			}
		}
		if field == "identity" && len(old.Versions) > 0 {
			current, _ := crdt.Selected(old)
			if !bytes.Equal(current, value) {
				return fault.New(fault.Invalid, "shared identity is immutable")
			}
			continue
		}
		record, err := crdt.Put(old, kind, id+"."+field, identity.Actor, old.Revision(), value, false)
		if err != nil {
			return err
		}
		if err = schema.Validate(record); err != nil {
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

// PickFields encodes the schema fields of kind from value, defaulting absent ones.
func PickFields(value any, kind string) map[string]json.RawMessage {
	all := objectFields(value)
	out := map[string]json.RawMessage{}
	for field, shape := range schema.DomainFields[kind] {
		if field == "deleted" || field == "consolidatedInto" || field == "retired" {
			continue
		}
		if raw, ok := all[field]; ok {
			out[field] = raw
		} else {
			switch shape {
			case "string":
				out[field] = RawValue("")
			case "bool":
				out[field] = RawValue(false)
			case "strings":
				out[field] = RawValue([]string{})
			}
		}
	}
	return out
}
