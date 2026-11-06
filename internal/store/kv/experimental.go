package kv

import (
	"encoding/json"
	"errors"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
)

// ChannelSettings reads the replicated agent channel switches of this
// daemon's account: the global key and every project and board override.
func (s *Store) ChannelSettings() (model.ChannelSettings, error) {
	settings := model.ChannelSettings{Projects: map[string]bool{}, Boards: map[string]bool{}}
	_, data, err := s.replica.Snapshot()
	if err != nil {
		return settings, err
	}
	defer data.Close()
	kind := schema.KVKindPrefix + schema.ExperimentalNamespace
	err = data.Each(crdt.Key(kind, schema.ChannelsKey), func(record crdt.Record) error {
		if record.Kind != kind {
			return nil
		}
		version := schema.SelectedKV(record)
		if version.Deleted || len(version.Value) == 0 {
			return nil
		}
		switch {
		case record.ID == schema.ChannelsKey:
			var value bool
			if json.Unmarshal(version.Value, &value) == nil {
				settings.Global = value
			}
		case strings.HasPrefix(record.ID, schema.ChannelsProjectKeyStart):
			var value string
			if json.Unmarshal(version.Value, &value) == nil {
				settings.Projects[strings.TrimPrefix(record.ID, schema.ChannelsProjectKeyStart)] = value == "on"
			}
		case strings.HasPrefix(record.ID, schema.ChannelsBoardKeyStart):
			var value string
			if json.Unmarshal(version.Value, &value) == nil {
				settings.Boards[strings.TrimPrefix(record.ID, schema.ChannelsBoardKeyStart)] = value == "on"
			}
		}
		return nil
	})
	if err == nil {
		err = data.Err()
	}
	return settings, err
}

// SetChannelSetting writes the global switch (scope "global", value "on" or
// "off") or a project/board override (value "on", "off", or "inherit", which
// deletes the override). Concurrent edits retry on the observed revision.
func (s *Store) SetChannelSetting(scope, id, value string) error {
	key, raw, remove, err := channelSettingRecord(scope, id, value)
	if err != nil {
		return err
	}
	identity, err := s.replica.EnsureIdentity()
	if err != nil {
		return err
	}
	kind := schema.KVKindPrefix + schema.ExperimentalNamespace
	for attempt := 0; attempt < 4; attempt++ {
		_, data, err := s.replica.Snapshot()
		if err != nil {
			return err
		}
		current := data.Record(crdt.Key(kind, key))
		data.Close()
		selected := schema.SelectedKV(current)
		if remove && (len(current.Versions) == 0 || selected.Deleted) {
			return nil
		}
		if !remove && !selected.Deleted && string(selected.Value) == string(raw) && len(current.Versions) == 1 {
			return nil
		}
		_, err = s.Mutate(identity, Mutation{
			Namespace: schema.ExperimentalNamespace, Key: key, Revision: current.Revision(),
			OperationID: home.NewID("op_"), DaemonID: identity.DaemonID, Value: raw, Delete: remove,
		})
		if errors.Is(err, crdt.ErrConflict) {
			continue
		}
		return err
	}
	return crdt.ErrConflict
}

func channelSettingRecord(scope, id, value string) (string, json.RawMessage, bool, error) {
	switch scope {
	case "global":
		if value != "on" && value != "off" {
			return "", nil, false, fault.New(fault.Invalid, `the global channel setting is "on" or "off"`)
		}
		return schema.ChannelsKey, json.RawMessage(map[bool]string{true: "true", false: "false"}[value == "on"]), false, nil
	case "project", "board":
		if !crdt.ValidID(id) || strings.Contains(id, ".") {
			return "", nil, false, fault.Invalidf("a valid %s ID is required", scope)
		}
		key := schema.ChannelsProjectKeyStart + id
		if scope == "board" {
			key = schema.ChannelsBoardKeyStart + id
		}
		switch value {
		case "inherit":
			return key, nil, true, nil
		case "on", "off":
			raw, _ := json.Marshal(value)
			return key, raw, false, nil
		}
		return "", nil, false, fault.New(fault.Invalid, `a channel override is "on", "off" or "inherit"`)
	}
	return "", nil, false, fault.New(fault.Invalid, `the channel setting scope is "global", "project" or "board"`)
}
