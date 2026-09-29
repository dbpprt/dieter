package store

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/peerstore"
)

// PeerRecordError exposes only bounded identity and an error category, never a
// record value, proof, credential or arbitrary validation error payload.
type PeerRecordError struct {
	Kind, ID, Field, Code string
	cause                 error
}

func (e *PeerRecordError) Error() string {
	return fmt.Sprintf("peer record rejected: kind=%s id=%s field=%s code=%s", e.Kind, e.ID, e.Field, e.Code)
}
func (e *PeerRecordError) Unwrap() error { return e.cause }
func peerRecordFailure(record peerstore.Record, code string, err error) error {
	_, field := peerstore.SplitField(record.ID)
	for _, prefix := range []string{"unknown shared object field: ", "null shared object field: "} {
		if strings.HasPrefix(err.Error(), prefix) {
			field = strings.TrimPrefix(err.Error(), prefix)
		}
	}
	safe := func(value string) string {
		if peerstore.ValidID(value) {
			return value
		}
		return "invalid"
	}
	return &PeerRecordError{Kind: safe(record.Kind), ID: safe(record.ID), Field: safe(field), Code: code, cause: err}
}

type PeerSyncDiagnostic struct {
	PeerID        string         `json:"peerId"`
	LastAttemptAt string         `json:"lastAttemptAt"`
	LastSuccessAt string         `json:"lastSuccessAt,omitempty"`
	Route         string         `json:"route,omitempty"`
	Direction     string         `json:"direction,omitempty"`
	FailureCode   string         `json:"failureCode,omitempty"`
	RecordKind    string         `json:"recordKind,omitempty"`
	RecordID      string         `json:"recordId,omitempty"`
	Field         string         `json:"field,omitempty"`
	Actor         string         `json:"actor,omitempty"`
	Pull          PeerCheckpoint `json:"pull"`
	Push          PeerCheckpoint `json:"push"`
	// Presence is advisory and never changes the retained failure or success.
	Offline bool `json:"offline,omitempty"`
}

// Transport failures describe a recent attempt, not a durable data problem.
// Cover the two-minute retry backoff and a bounded exchange, but do not keep
// warning forever when discovery stops. Rejected records remain actionable.
const PeerSyncIssueMaxAge = 5 * time.Minute

func (d PeerSyncDiagnostic) IsCurrentIssue(now time.Time) bool {
	if d.FailureCode == "" {
		return false
	}
	if d.RecordID != "" || d.RecordKind != "" || d.Field != "" {
		return true
	}
	switch d.FailureCode {
	case "Canceled", "canceled":
		return false
	case "Unavailable", "unavailable", "DeadlineExceeded", "deadline", "ResourceExhausted", "Aborted":
		attempt, err := time.Parse(time.RFC3339Nano, d.LastAttemptAt)
		return !d.Offline && err == nil && !attempt.After(now) && now.Sub(attempt) < PeerSyncIssueMaxAge
	default:
		return true
	}
}

// ObservePeerAvailability uses only an authenticated, successfully fetched
// directory. Missing/offline peers keep their history without an active
// transport warning. It must also run when no peer is online.
func (s *Store) ObservePeerAvailability(identity PeerIdentity, online map[string]bool) error {
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	if err = s.checkPeerIdentity(identity); err != nil {
		return err
	}
	values, err := s.PeerSyncDiagnostics(identity.Account)
	if err != nil {
		return err
	}
	changed := false
	for i := range values {
		offline := !online[values[i].PeerID]
		if values[i].Offline != offline {
			values[i].Offline = offline
			changed = true
		}
	}
	if !changed {
		return nil
	}
	return writeJSON(s.peerPath(identity.Account)+".diagnostics", values)
}

func (s *Store) PeerSyncDiagnostics(account string) ([]PeerSyncDiagnostic, error) {
	var values []PeerSyncDiagnostic
	err := readPeerJSON(s.peerPath(account)+".diagnostics", &values)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return values, err
}

// Diagnostics do not publish domain commits or wake anti-entropy themselves.
func (s *Store) RecordPeerSync(identity PeerIdentity, value PeerSyncDiagnostic) error {
	if !peerstore.ValidID(value.PeerID) {
		return errors.New("invalid peer ID")
	}
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	if err = s.checkPeerIdentity(identity); err != nil {
		return err
	}
	values, err := s.PeerSyncDiagnostics(identity.Account)
	if err != nil {
		return err
	}
	for index, previous := range values {
		if previous.PeerID != value.PeerID {
			continue
		}
		value.LastSuccessAt = previous.LastSuccessAt
		values = append(values[:index], values[index+1:]...)
		break
	}
	if value.FailureCode == "" && value.Direction != "catchup" {
		value.LastSuccessAt = value.LastAttemptAt
	}
	values = append(values, value)
	sort.Slice(values, func(i, j int) bool { return values[i].LastAttemptAt > values[j].LastAttemptAt })
	// Bound retained diagnostics independently of concurrent agent turns.
	if len(values) > 128 {
		values = values[:128]
	}
	return writeJSON(s.peerPath(identity.Account)+".diagnostics", values)
}
