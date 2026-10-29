package schema

import (
	"bytes"
	"encoding/json"
	"strings"
	"unicode/utf8"

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
		if ns == ExperimentalNamespace {
			if err := validateExperimental(r.ID, v.Value); err != nil {
				return err
			}
			continue
		}
		if ChannelNamespaceKind(ns) {
			if err := validateChannel(ns, r.ID, v.Value); err != nil {
				return err
			}
			continue
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
		case "rule":
			if err := validateInboxRule(parts[0], v.Value); err != nil {
				return err
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

// validateInboxRule checks an Inbox rule: `inbox-rule.<id>.rule` holds an object that shows or
// hides the cards of some projects and labels.
func validateInboxRule(prefix string, raw json.RawMessage) error {
	if prefix != "inbox-rule" {
		return fault.New(fault.Invalid, "unsupported navigation field")
	}
	var value struct {
		Name     string   `json:"name"`
		Effect   string   `json:"effect"`
		Match    string   `json:"match"`
		Projects []string `json:"projects"`
		Labels   []string `json:"labels"`
		Enabled  *bool    `json:"enabled"`
		Created  *int64   `json:"created"`
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&value) != nil || utf8.RuneCountInString(value.Name) > 120 {
		return fault.New(fault.Invalid, "invalid inbox rule")
	}
	if value.Effect != "show" && value.Effect != "hide" || value.Match != "any" && value.Match != "all" {
		return fault.New(fault.Invalid, "invalid inbox rule effect or match")
	}
	if value.Enabled == nil || value.Created == nil || *value.Created < 0 {
		return fault.New(fault.Invalid, "invalid inbox rule state")
	}
	if len(value.Projects) == 0 && len(value.Labels) == 0 || len(value.Projects) > 64 || len(value.Labels) > 64 {
		return fault.New(fault.Invalid, "an inbox rule names 1 to 64 projects and labels each")
	}
	for _, id := range append(append([]string{}, value.Projects...), value.Labels...) {
		if !crdt.ValidID(id) {
			return fault.New(fault.Invalid, "invalid inbox rule project or label")
		}
	}
	return nil
}

// ExperimentalNamespace holds account-wide switches of preview features. Keys:
//
//	channels                   true or false: agent channels for every project
//	channels.project.<id>      "on" or "off": a project override (absent inherits)
//	channels.board.<id>        "on" or "off": a board override (absent inherits)
const ExperimentalNamespace = "experimental"

// Experimental channel keys.
const (
	ChannelsKey             = "channels"
	ChannelsProjectKeyStart = "channels.project."
	ChannelsBoardKeyStart   = "channels.board."
)

func validateExperimental(key string, raw json.RawMessage) error {
	switch {
	case key == ChannelsKey:
		var value bool
		if string(raw) == "null" || json.Unmarshal(raw, &value) != nil {
			return fault.New(fault.Invalid, "experimental channels must be a boolean")
		}
		return nil
	case strings.HasPrefix(key, ChannelsProjectKeyStart), strings.HasPrefix(key, ChannelsBoardKeyStart):
		id := strings.TrimPrefix(strings.TrimPrefix(key, ChannelsProjectKeyStart), ChannelsBoardKeyStart)
		if !crdt.ValidID(id) || strings.Contains(id, ".") {
			return fault.New(fault.Invalid, "invalid channel override ID")
		}
		var value string
		if json.Unmarshal(raw, &value) != nil || value != "on" && value != "off" {
			return fault.New(fault.Invalid, `a channel override is "on" or "off"`)
		}
		return nil
	default:
		return fault.New(fault.Invalid, "unsupported experimental key")
	}
}
