package gateway

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

var (
	errRosterConflict   = errors.New("device roster changed")
	errPairingLimit     = errors.New("too many devices are waiting to pair")
	errPairingNotFound  = errors.New("pairing request not found")
	errPairingConfirmed = errors.New("pairing request was confirmed with another confirmation")
)

const (
	// A pairing request is a short-lived note; its device re-posts it while
	// it waits for a person to type its code.
	pairingRequestTTL = 15 * time.Minute
	// maxPairingRequests bounds the live requests of one account.
	maxPairingRequests = 16
)

// PairingRecord is a stored pairing request. The descriptor and proof are
// the new device's; the confirmation is the approver's.
type PairingRecord struct {
	ID           string
	Device       *gatewayv1.DeviceDescriptor
	Proof        []byte
	Confirmation []byte
	RequestedAt  time.Time
	ExpiresAt    time.Time
}

func (r PairingRecord) proto() *gatewayv1.PairingRequest {
	return &gatewayv1.PairingRequest{
		Id: r.ID, Device: r.Device, Proof: r.Proof, Confirmation: r.Confirmation,
		RequestedAt: r.RequestedAt.UTC().Format(time.RFC3339Nano), ExpiresAt: r.ExpiresAt.UTC().Format(time.RFC3339Nano),
	}
}

// DeviceRoster returns an account's stored roster entries in sequence order.
// The gateway stores what devices signed; Service verifies it on load.
func (s *Store) DeviceRoster(githubID int64) ([]*gatewayv1.DeviceRosterEntry, error) {
	rows, err := s.DB.Query(`SELECT sequence, entry FROM device_roster_entries WHERE github_id=? ORDER BY sequence`, githubID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var entries []*gatewayv1.DeviceRosterEntry
	for rows.Next() {
		var sequence int64
		var raw []byte
		if err := rows.Scan(&sequence, &raw); err != nil {
			return nil, err
		}
		entry := &gatewayv1.DeviceRosterEntry{}
		if err := proto.Unmarshal(raw, entry); err != nil {
			return nil, fmt.Errorf("decode device roster entry %d: %w", sequence, err)
		}
		if sequence != int64(len(entries)) || entry.GetSequence() != uint64(sequence) {
			return nil, errors.New("stored device roster is not contiguous")
		}
		entries = append(entries, entry)
	}
	return entries, rows.Err()
}

// AppendDeviceRoster stores entry if the account's roster still has length
// entries. replace deletes the roster first, so entry becomes its genesis.
func (s *Store) AppendDeviceRoster(githubID int64, entry *gatewayv1.DeviceRosterEntry, length uint64, replace bool) error {
	raw, err := proto.Marshal(entry)
	if err != nil {
		return err
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if replace {
		if _, err := tx.Exec(`DELETE FROM device_roster_entries WHERE github_id=?`, githubID); err != nil {
			return err
		}
	} else {
		var count int64
		if err := tx.QueryRow(`SELECT COUNT(*) FROM device_roster_entries WHERE github_id=?`, githubID).Scan(&count); err != nil {
			return err
		}
		if uint64(count) != length || entry.GetSequence() != length {
			return errRosterConflict
		}
	}
	if _, err := tx.Exec(`INSERT INTO device_roster_entries(github_id, sequence, entry) VALUES(?, ?, ?)`, githubID, int64(entry.GetSequence()), raw); err != nil {
		return err
	}
	return tx.Commit()
}

// PutPairingRequest records a device's request to join, or refreshes the
// device's live request: it keeps its ID, takes the new descriptor and proof,
// and drops an approver's confirmation only when the proof changed.
func (s *Store) PutPairingRequest(githubID int64, device *gatewayv1.DeviceDescriptor, proof []byte, now time.Time) (PairingRecord, error) {
	encoded, err := proto.Marshal(device)
	if err != nil {
		return PairingRecord{}, err
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return PairingRecord{}, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM pairing_requests WHERE expires_at<=?`, now.UnixNano()); err != nil {
		return PairingRecord{}, err
	}
	record := PairingRecord{Device: device, Proof: proof, ExpiresAt: now.Add(pairingRequestTTL)}
	var requested int64
	var previousProof []byte
	err = tx.QueryRow(`SELECT id, proof, confirmation, requested_at FROM pairing_requests WHERE github_id=? AND device_id=?`, githubID, device.GetDeviceId()).
		Scan(&record.ID, &previousProof, &record.Confirmation, &requested)
	switch {
	case err == nil:
		if len(record.Confirmation) == 0 || !bytes.Equal(previousProof, proof) {
			record.Confirmation = nil
		}
		record.RequestedAt = time.Unix(0, requested)
		if _, err := tx.Exec(`UPDATE pairing_requests SET device=?, proof=?, confirmation=?, expires_at=? WHERE id=?`,
			encoded, proof, nonNilBytes(record.Confirmation), record.ExpiresAt.UnixNano(), record.ID); err != nil {
			return PairingRecord{}, err
		}
	case errors.Is(err, sql.ErrNoRows):
		var live int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM pairing_requests WHERE github_id=?`, githubID).Scan(&live); err != nil {
			return PairingRecord{}, err
		}
		if live >= maxPairingRequests {
			return PairingRecord{}, errPairingLimit
		}
		record.ID, record.RequestedAt = randomID("pr_"), now
		if _, err := tx.Exec(`INSERT INTO pairing_requests(id, github_id, device_id, device, proof, requested_at, expires_at) VALUES(?, ?, ?, ?, ?, ?, ?)`,
			record.ID, githubID, device.GetDeviceId(), encoded, proof, now.UnixNano(), record.ExpiresAt.UnixNano()); err != nil {
			return PairingRecord{}, err
		}
	default:
		return PairingRecord{}, err
	}
	return record, tx.Commit()
}

// PairingRequests returns an account's live requests, oldest first.
func (s *Store) PairingRequests(githubID int64, now time.Time) ([]PairingRecord, error) {
	rows, err := s.DB.Query(`SELECT id, device, proof, confirmation, requested_at, expires_at FROM pairing_requests WHERE github_id=? AND expires_at>? ORDER BY requested_at, id`, githubID, now.UnixNano())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []PairingRecord
	for rows.Next() {
		record, err := scanPairingRecord(rows.Scan)
		if err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	return records, rows.Err()
}

// ConfirmPairingRequest attaches an approver's confirmation once. Repeating
// the same confirmation is idempotent; a different one is refused.
func (s *Store) ConfirmPairingRequest(githubID int64, id string, confirmation []byte, now time.Time) (PairingRecord, error) {
	tx, err := s.DB.Begin()
	if err != nil {
		return PairingRecord{}, err
	}
	defer tx.Rollback()
	record, err := scanPairingRecord(tx.QueryRow(`SELECT id, device, proof, confirmation, requested_at, expires_at FROM pairing_requests WHERE id=? AND github_id=? AND expires_at>?`, id, githubID, now.UnixNano()).Scan)
	if errors.Is(err, sql.ErrNoRows) {
		return PairingRecord{}, errPairingNotFound
	}
	if err != nil {
		return PairingRecord{}, err
	}
	if len(record.Confirmation) != 0 {
		if !bytes.Equal(record.Confirmation, confirmation) {
			return PairingRecord{}, errPairingConfirmed
		}
		return record, nil
	}
	if _, err := tx.Exec(`UPDATE pairing_requests SET confirmation=? WHERE id=?`, confirmation, id); err != nil {
		return PairingRecord{}, err
	}
	record.Confirmation = confirmation
	return record, tx.Commit()
}

// DeletePairingRequest removes an account's live request.
func (s *Store) DeletePairingRequest(githubID int64, id string, now time.Time) error {
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM pairing_requests WHERE expires_at<=?`, now.UnixNano()); err != nil {
		return err
	}
	result, err := tx.Exec(`DELETE FROM pairing_requests WHERE id=? AND github_id=?`, id, githubID)
	if err != nil {
		return err
	}
	if count, _ := result.RowsAffected(); count != 1 {
		return errPairingNotFound
	}
	return tx.Commit()
}

func scanPairingRecord(scan func(...any) error) (PairingRecord, error) {
	var record PairingRecord
	var device []byte
	var requested, expires int64
	if err := scan(&record.ID, &device, &record.Proof, &record.Confirmation, &requested, &expires); err != nil {
		return record, err
	}
	record.Device = &gatewayv1.DeviceDescriptor{}
	if err := proto.Unmarshal(device, record.Device); err != nil {
		return record, fmt.Errorf("decode pairing request device: %w", err)
	}
	if len(record.Confirmation) == 0 {
		record.Confirmation = nil
	}
	record.RequestedAt, record.ExpiresAt = time.Unix(0, requested), time.Unix(0, expires)
	return record, nil
}

// nonNilBytes stores an absent confirmation as an empty blob.
func nonNilBytes(value []byte) []byte {
	if value == nil {
		return []byte{}
	}
	return value
}
