package store

import (
	"testing"
	"time"
)

func TestPeerSyncIssuePolicy(t *testing.T) {
	now := time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		name    string
		code    string
		age     time.Duration
		offline bool
		record  string
		want    bool
	}{
		{"healthy", "", 0, false, "", false},
		{"online failure", "DeadlineExceeded", time.Minute, false, "", true},
		{"offline laptop", "DeadlineExceeded", time.Minute, true, "", false},
		{"discovery stopped", "Unavailable", PeerSyncIssueMaxAge, false, "", false},
		{"clock moved backward", "Unavailable", -time.Second, false, "", false},
		{"shutdown", "canceled", 0, false, "", false},
		{"record rejection survives offline", "invalid-record", 24 * time.Hour, true, "b_one.retired", true},
		{"authorization requires attention", "PermissionDenied", 24 * time.Hour, true, "", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			d := PeerSyncDiagnostic{FailureCode: test.code, LastAttemptAt: now.Add(-test.age).Format(time.RFC3339Nano), Offline: test.offline, RecordID: test.record}
			if got := d.IsCurrentIssue(now); got != test.want {
				t.Fatalf("got %v, want %v", got, test.want)
			}
		})
	}
}

func TestPeerAvailabilityPreservesHistoryAndWorkspaceCursor(t *testing.T) {
	s := New(t.TempDir())
	identity, err := s.BindPeerAccount("account", "github:1", "local", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now().UTC().Format(time.RFC3339Nano)
	for _, d := range []PeerSyncDiagnostic{
		{PeerID: "laptop", LastAttemptAt: at},
		{PeerID: "laptop", LastAttemptAt: at, FailureCode: "DeadlineExceeded"},
		{PeerID: "removed", LastAttemptAt: at, FailureCode: "Unavailable"},
	} {
		if err := s.RecordPeerSync(identity, d); err != nil {
			t.Fatal(err)
		}
	}
	before, err := s.MetadataCursor()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.ObservePeerAvailability(identity, map[string]bool{"laptop": false}); err != nil {
		t.Fatal(err)
	}
	s = New(s.Root)
	diagnostics, err := s.PeerSyncDiagnostics(identity.Account)
	if err != nil || len(diagnostics) != 2 {
		t.Fatalf("history: %+v %v", diagnostics, err)
	}
	for _, d := range diagnostics {
		if !d.Offline || d.IsCurrentIssue(time.Now()) || d.FailureCode == "" || d.LastAttemptAt != at {
			t.Fatalf("lost history: %+v", d)
		}
		if d.PeerID == "laptop" && d.LastSuccessAt != at {
			t.Fatalf("lost success: %+v", d)
		}
	}
	if err := s.ObservePeerAvailability(identity, map[string]bool{"laptop": true}); err != nil {
		t.Fatal(err)
	}
	diagnostics, err = s.PeerSyncDiagnostics(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range diagnostics {
		if d.PeerID == "laptop" && (d.Offline || !d.IsCurrentIssue(time.Now())) {
			t.Fatalf("lost current problem: %+v", d)
		}
	}
	after, err := s.MetadataCursor()
	if err != nil || before != after {
		t.Fatalf("presence mutated workspace: %v %v %v", before, after, err)
	}
}
