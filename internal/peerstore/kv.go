package peerstore

import (
	"encoding/json"
	"errors"
	"strings"
)

const KVKindPrefix = "kv."

func KVKind(namespace string) (string, error) {
	if !ValidID(namespace) || len(namespace) > 120 {
		return "", errors.New("invalid KV namespace")
	}
	return KVKindPrefix + namespace, nil
}

// SelectedKV is a deterministic projection of the causal siblings. Deletion
// wins concurrent edits. Consumers can inspect every sibling before resolving.
func SelectedKV(r Record) Version {
	var selected Version
	var rank string
	for _, v := range r.Versions {
		if v.Deleted {
			return v
		}
		if next := Revision(v); next > rank {
			rank, selected = next, v
		}
	}
	return selected
}

type KVPosition struct {
	Parent string `json:"parent"`
	Rank   string `json:"rank"`
}

func ValidateKV(r Record) error {
	ns := strings.TrimPrefix(r.Kind, KVKindPrefix)
	if _, err := KVKind(ns); err != nil {
		return err
	}
	if !ValidID(r.ID) {
		return errors.New("invalid KV key")
	}
	for _, v := range r.Versions {
		if v.Deleted {
			continue
		}
		if len(v.Value) > MaxValueBytes || !json.Valid(v.Value) {
			return errors.New("invalid KV JSON value")
		}
		// Navigation is a registered portable consumer of the general JSON store.
		if ns != "navigation" {
			continue
		}
		parts := strings.Split(r.ID, ".")
		if len(parts) < 3 {
			return errors.New("invalid navigation key")
		}
		field := parts[len(parts)-1]
		switch field {
		case "name":
			var value string
			if json.Unmarshal(v.Value, &value) != nil || strings.TrimSpace(value) == "" || len(value) > 256 {
				return errors.New("invalid folder name")
			}
		case "expanded":
			var value bool
			if string(v.Value) == "null" || json.Unmarshal(v.Value, &value) != nil {
				return errors.New("invalid expansion state")
			}
		case "sort":
			var value string
			if json.Unmarshal(v.Value, &value) != nil || (value != "ascending" && value != "descending") {
				return errors.New("invalid sort direction")
			}
		case "position":
			var value KVPosition
			if json.Unmarshal(v.Value, &value) != nil || !ValidPosition(value) {
				return errors.New("invalid navigation position")
			}
		default:
			return errors.New("unsupported navigation field")
		}
	}
	return nil
}

func ValidPosition(p KVPosition) bool {
	if len(p.Parent) > 128 || (p.Parent != "" && !ValidID(p.Parent)) || len(p.Rank) == 0 || len(p.Rank) > 512 {
		return false
	}
	for _, c := range p.Rank {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z') {
			return false
		}
	}
	return true
}
