package schema

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

func channelKV(t *testing.T, ns, key string, value any) crdt.Record {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return crdt.Record{Kind: KVKindPrefix + ns, ID: key, Versions: []crdt.Version{{Clock: crdt.Clock{"a": 1}, Value: raw}}}
}

func TestChannelMessageRecordsAreBoundAndKeyedByOriginRing(t *testing.T) {
	t.Parallel()
	message := ChannelRecord{
		ID: "m_one", ProjectID: "p_one", Origin: "d_mini-home_1", OriginSeq: 65, Kind: "request",
		Author: ChannelAuthor{Kind: "agent", CardID: "c_one", Title: "Fix tests", Harness: "codex"},
		To:     []string{"c_two"}, Body: "Please free src/a.go.", Files: []string{"src/a.go"}, CreatedAt: "2026-10-25T10:00:00.5Z",
	}
	key := ChannelKey("p_one", "d_mini-home_1", 65)
	if key != "p_one.d_mini-home_1.1" {
		t.Fatalf("key = %q", key)
	}
	if err := ValidateKV(channelKV(t, ChannelNamespace, key, message)); err != nil {
		t.Fatalf("valid message rejected: %v", err)
	}
	for name, mutate := range map[string]func(*ChannelRecord){
		"slot":      func(m *ChannelRecord) { m.OriginSeq = 66 },
		"kind":      func(m *ChannelRecord) { m.Kind = "release" },
		"body":      func(m *ChannelRecord) { m.Body = strings.Repeat("x", 4097) },
		"empty":     func(m *ChannelRecord) { m.Body = " " },
		"agentHere": func(m *ChannelRecord) { m.Here = true },
		"recipient": func(m *ChannelRecord) { m.To = []string{"c.two"} },
		"time":      func(m *ChannelRecord) { m.CreatedAt = "yesterday" },
		"noCard":    func(m *ChannelRecord) { m.Author.CardID = "" },
	} {
		changed := message
		changed.To = append([]string(nil), message.To...)
		mutate(&changed)
		if err := ValidateKV(channelKV(t, ChannelNamespace, key, changed)); err == nil {
			t.Errorf("%s: invalid message accepted", name)
		}
	}
	human := message
	human.Author, human.Here, human.To = ChannelAuthor{Kind: "human"}, true, nil
	if err := ValidateKV(channelKV(t, ChannelNamespace, key, human)); err != nil {
		t.Fatalf("a person's @here rejected: %v", err)
	}
	unknown := channelKV(t, ChannelNamespace, key, map[string]any{"id": "m_one", "extra": true})
	if err := ValidateKV(unknown); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestChannelReceiptPinAndClaimRecordsAreBound(t *testing.T) {
	t.Parallel()
	receipt := ChannelReceiptRecord{ProjectID: "p_one", Daemon: "d_one", Deliveries: []ChannelDeliveryEntry{{Message: "m_one", Mode: "steered", At: "2026-10-25T10:00:00Z"}}}
	if err := ValidateKV(channelKV(t, ChannelReceiptNamespace, "c_one", receipt)); err != nil {
		t.Fatalf("receipt rejected: %v", err)
	}
	receipt.Deliveries[0].Mode = "pending"
	if err := ValidateKV(channelKV(t, ChannelReceiptNamespace, "c_one", receipt)); err == nil {
		t.Fatal("pending receipt accepted")
	}
	pins := ChannelPinsRecord{Pins: []ChannelPinEntry{{Message: "m_one", Pinned: true, At: "2026-10-25T10:00:00Z"}}}
	if err := ValidateKV(channelKV(t, ChannelPinsNamespace, ChannelScopeKey("p_one", "d_one"), pins)); err != nil {
		t.Fatalf("pins rejected: %v", err)
	}
	claims := ChannelClaimsRecord{At: "2026-10-25T10:00:00Z", Claims: make([]ChannelClaimEntry, ChannelClaimEntries+1)}
	for i := range claims.Claims {
		claims.Claims[i] = ChannelClaimEntry{Path: "a.go", CardID: "c_one", Since: "2026-10-25T10:00:00Z"}
	}
	if err := ValidateKV(channelKV(t, ChannelClaimsNamespace, ChannelScopeKey("p_one", "d_one"), claims)); err == nil {
		t.Fatal("too many claims accepted")
	}
	claims.Claims = claims.Claims[:2]
	if err := ValidateKV(channelKV(t, ChannelClaimsNamespace, ChannelScopeKey("p_one", "d_one"), claims)); err != nil {
		t.Fatalf("claims rejected: %v", err)
	}
}
