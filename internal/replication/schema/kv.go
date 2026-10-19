package schema

import (
	"encoding/json"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
)

const KVKindPrefix = "kv."

func KVKind(namespace string) (string, error) {
	if !crdt.ValidID(namespace) || len(namespace) > 120 {
		return "", fault.New(fault.Invalid, "invalid KV namespace")
	}
	return KVKindPrefix + namespace, nil
}

// SelectedKV is a deterministic projection of the causal siblings. Deletion
// wins concurrent edits. Consumers can inspect every sibling before resolving.
func SelectedKV(r crdt.Record) crdt.Version {
	var selected crdt.Version
	var rank string
	for _, v := range r.Versions {
		if v.Deleted {
			return v
		}
		if next := crdt.Revision(v); next > rank {
			rank, selected = next, v
		}
	}
	return selected
}

type KVPosition struct {
	Parent string `json:"parent"`
	Rank   string `json:"rank"`
}

func ValidateKV(r crdt.Record) error {
	ns := strings.TrimPrefix(r.Kind, KVKindPrefix)
	if _, err := KVKind(ns); err != nil {
		return err
	}
	if !crdt.ValidID(r.ID) {
		return fault.New(fault.Invalid, "invalid KV key")
	}
	for _, v := range r.Versions {
		if v.Deleted {
			continue
		}
		if len(v.Value) > crdt.MaxValueBytes || !json.Valid(v.Value) {
			return fault.New(fault.Invalid, "invalid KV JSON value")
		}
		// Navigation is a registered portable consumer of the general JSON store.
		if ns != "navigation" {
			continue
		}
		parts := strings.Split(r.ID, ".")
		if len(parts) < 3 {
			return fault.New(fault.Invalid, "invalid navigation key")
		}
		field := parts[len(parts)-1]
		switch field {
		case "name":
			var value string
			if json.Unmarshal(v.Value, &value) != nil || strings.TrimSpace(value) == "" || len(value) > 256 {
				return fault.New(fault.Invalid, "invalid folder name")
			}
		case "expanded", "pinned":
			var value bool
			if string(v.Value) == "null" || json.Unmarshal(v.Value, &value) != nil {
				return fault.New(fault.Invalid, "invalid navigation boolean")
			}
		case "sort":
			var value string
			if json.Unmarshal(v.Value, &value) != nil || (value != "ascending" && value != "descending") {
				return fault.New(fault.Invalid, "invalid sort direction")
			}
		case "position":
			var value KVPosition
			if json.Unmarshal(v.Value, &value) != nil || !ValidPosition(value) {
				return fault.New(fault.Invalid, "invalid navigation position")
			}
		default:
			return fault.New(fault.Invalid, "unsupported navigation field")
		}
	}
	return nil
}

func ValidPosition(p KVPosition) bool {
	if len(p.Parent) > 128 || (p.Parent != "" && !crdt.ValidID(p.Parent)) || len(p.Rank) == 0 || len(p.Rank) > 512 {
		return false
	}
	for _, c := range p.Rank {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z') {
			return false
		}
	}
	return true
}
