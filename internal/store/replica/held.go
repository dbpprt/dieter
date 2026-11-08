package replica

import (
	"encoding/json"
	"errors"
	"os"

	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store/home"
)

// A received record whose owner provenance this machine cannot verify is held
// instead of failing its whole page. A failed page keeps its checkpoint, so one
// record signed by a machine that never joined the device roster used to stop
// every later change from that peer. A held record never enters the replica.
const (
	maxHeldPeerRecords = 128
	maxHeldPeerBytes   = crdt.MaxPageBytes
)

// HeldPeerRecord is a received record that did not verify, kept as received so
// a later round can verify it again.
type HeldPeerRecord struct {
	Record crdt.Record `json:"record"`
	Field  string      `json:"field"`
	Code   string      `json:"code"`
	HeldAt string      `json:"heldAt"`
}

func (s *Store) heldPath(account string) string { return s.peerPath(account) + ".held" }

// HeldPeerRecords lists account's held records, oldest first.
func (s *Store) HeldPeerRecords(account string) ([]HeldPeerRecord, error) {
	var values []HeldPeerRecord
	err := readPeerJSON(s.heldPath(account), &values)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return values, err
}

// holdPeerRecords adds records to account's held set. Hold the writer lock. A
// record beyond the set's bounds fails with its own rejection, as its page did
// before records were held.
func (s *Store) holdPeerRecords(account string, records []HeldPeerRecord) error {
	if len(records) == 0 {
		return nil
	}
	values, err := s.HeldPeerRecords(account)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	size := 0
	for _, value := range values {
		seen[value.Record.Revision()] = true
		size += heldSize(value)
	}
	changed := false
	for _, value := range records {
		if seen[value.Record.Revision()] {
			continue
		}
		size += heldSize(value)
		if len(values) >= maxHeldPeerRecords || size > maxHeldPeerBytes {
			return peerRecordFailure(value.Record, value.Code, crdt.ErrCapacity)
		}
		seen[value.Record.Revision()] = true
		values = append(values, value)
		changed = true
	}
	if !changed {
		return nil
	}
	return s.writeHeld(account, values)
}

// RetryHeldPeerRecords merges the held records that verify now, e.g. once the
// roster has the entry a proof needed, and drops those that merged versions
// supersede. The rest stay held.
func (s *Store) RetryHeldPeerRecords(identity PeerIdentity) error {
	if values, err := s.HeldPeerRecords(identity.Account); err != nil || len(values) == 0 {
		return err
	}
	write, err := s.home.BeginConditionalWrite()
	if err != nil {
		return err
	}
	defer write.Finish()
	if err = s.CheckPeerIdentity(identity); err != nil {
		return err
	}
	values, err := s.HeldPeerRecords(identity.Account)
	if err != nil {
		return err
	}
	data, err := s.OpenPeerView(identity.Account)
	data.State = ClonePeerState(data.State)
	if err != nil {
		return err
	}
	var kept []HeldPeerRecord
	changed := false
	for _, value := range values {
		key := crdt.Key(value.Record.Kind, value.Record.ID)
		current := data.Record(key)
		if joined, e := crdt.Merge(current, value.Record); e == nil && joined.Revision() == current.Revision() {
			continue
		}
		merged, e := s.mergePeerRecord(&data, value.Record)
		var rejected *PeerRecordError
		if errors.As(e, &rejected) {
			value.Field, value.Code = rejected.Field, rejected.Code
			kept = append(kept, value)
			continue
		}
		if e != nil {
			return e
		}
		changed = changed || merged
	}
	// The replica commits before the held set shrinks, so a failure in
	// between only leaves records that the next retry finds superseded.
	if changed {
		if err = write.Prepare(home.MetadataChange); err != nil {
			return err
		}
		if err = s.SavePeerData(identity.Account, data); err != nil {
			return err
		}
	}
	if len(kept) == len(values) {
		return nil
	}
	return s.writeHeld(identity.Account, kept)
}

func (s *Store) writeHeld(account string, values []HeldPeerRecord) error {
	if len(values) == 0 {
		if err := os.Remove(s.heldPath(account)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	return home.WriteJSON(s.heldPath(account), values)
}

func heldSize(value HeldPeerRecord) int {
	raw, _ := json.Marshal(value)
	return len(raw)
}
