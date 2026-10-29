package schema

import (
	"encoding/json"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

func TestInboxPinRequiresBoolean(t *testing.T) {
	t.Parallel()
	for _, value := range []string{"true", "false", "null", `"true"`, "1", "{}"} {
		t.Run(value, func(t *testing.T) {
			t.Parallel()
			record := crdt.Record{Kind: "kv.navigation", ID: "inbox-pin.c1.pinned", Versions: []crdt.Version{{Value: json.RawMessage(value)}}}
			err := ValidateKV(record)
			valid := value == "true" || value == "false"
			if (err == nil) != valid {
				t.Fatalf("value %s: error = %v", value, err)
			}
		})
	}
}

func TestInboxRuleValidation(t *testing.T) {
	t.Parallel()
	const valid = `{"name":"Quiet","effect":"hide","match":"all","projects":["p_1"],"labels":["l_1"],"enabled":true,"created":1}`
	for name, tc := range map[string]struct {
		key, value string
		ok         bool
	}{
		"rule":              {"inbox-rule.r1.rule", valid, true},
		"labels only":       {"inbox-rule.r1.rule", `{"name":"","effect":"show","match":"any","projects":[],"labels":["l_1"],"enabled":false,"created":0}`, true},
		"wrong prefix":      {"folder.r1.rule", valid, false},
		"no conditions":     {"inbox-rule.r1.rule", `{"name":"","effect":"hide","match":"any","projects":[],"labels":[],"enabled":true,"created":1}`, false},
		"bad effect":        {"inbox-rule.r1.rule", `{"name":"","effect":"mute","match":"any","projects":["p"],"labels":[],"enabled":true,"created":1}`, false},
		"bad match":         {"inbox-rule.r1.rule", `{"name":"","effect":"hide","match":"xor","projects":["p"],"labels":[],"enabled":true,"created":1}`, false},
		"bad project id":    {"inbox-rule.r1.rule", `{"name":"","effect":"hide","match":"any","projects":["a b"],"labels":[],"enabled":true,"created":1}`, false},
		"unknown field":     {"inbox-rule.r1.rule", `{"name":"","effect":"hide","match":"any","projects":["p"],"labels":[],"enabled":true,"created":1,"x":1}`, false},
		"missing enabled":   {"inbox-rule.r1.rule", `{"name":"","effect":"hide","match":"any","projects":["p"],"labels":[],"created":1}`, false},
		"not an object":     {"inbox-rule.r1.rule", `true`, false},
		"too many projects": {"inbox-rule.r1.rule", `{"name":"","effect":"hide","match":"any","projects":[` + manyIDs(65) + `],"labels":[],"enabled":true,"created":1}`, false},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			record := crdt.Record{Kind: "kv.navigation", ID: tc.key, Versions: []crdt.Version{{Value: json.RawMessage(tc.value)}}}
			if err := ValidateKV(record); (err == nil) != tc.ok {
				t.Fatalf("error = %v, want ok = %v", err, tc.ok)
			}
		})
	}
}

func manyIDs(n int) string {
	var out []byte
	for i := 0; i < n; i++ {
		if i > 0 {
			out = append(out, ',')
		}
		out = append(out, '"', 'p', byte('a'+i%26), byte('a'+i/26), '"')
	}
	return string(out)
}

func TestExperimentalChannelKeys(t *testing.T) {
	record := func(id, value string) crdt.Record {
		return crdt.Record{Kind: "kv.experimental", ID: id, Versions: []crdt.Version{{Clock: crdt.Clock{"a": 1}, Value: json.RawMessage(value)}}}
	}
	for _, valid := range []crdt.Record{
		record("channels", "true"), record("channels", "false"),
		record("channels.project.p_0123456789ab", `"on"`), record("channels.board.b_0123456789ab", `"off"`),
		{Kind: "kv.experimental", ID: "channels.board.b_1", Versions: []crdt.Version{{Clock: crdt.Clock{"a": 2}, Deleted: true}}},
	} {
		if err := Validate(valid); err != nil {
			t.Fatalf("%s=%s rejected: %v", valid.ID, valid.Versions[0].Value, err)
		}
	}
	for _, invalid := range []crdt.Record{
		record("channels", `"on"`), record("channels", "null"), record("channels.project.p_1", `"inherit"`),
		record("channels.project.p_1", "true"), record("channels.project.a.b", `"on"`), record("other", "true"),
	} {
		if err := Validate(invalid); err == nil {
			t.Fatalf("%s=%s accepted", invalid.ID, invalid.Versions[0].Value)
		}
	}
}
