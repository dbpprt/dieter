package store

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"strings"

	"github.com/dbpprt/dieter/internal/peerstore"
)

type PeerStoreInfo struct {
	Records, Conflicts                uint32
	LastSyncAt, LastPeerID, LastRoute string
}

// PeerStoreInfo reads counters and the conflict index without decoding history.
func (s *Store) PeerStoreInfo(ctx context.Context, account string) (PeerStoreInfo, error) {
	var result PeerStoreInfo
	db, err := s.peerDatabase(account)
	if err != nil {
		return result, err
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	if err = tx.QueryRow("SELECT record_count FROM peer_metadata WHERE id=1").Scan(&result.Records); err != nil {
		return result, err
	}
	if err = tx.QueryRow("SELECT count(*) FROM peer_records WHERE json_array_length(value,'$.versions')>1").Scan(&result.Conflicts); err != nil {
		return result, err
	}
	if err = tx.Commit(); err != nil {
		return result, err
	}
	var progress peerProgress
	if err = readPeerJSON(s.peerPath(account)+".status", &progress); err != nil && !errors.Is(err, os.ErrNotExist) {
		return result, err
	}
	result.LastSyncAt, result.LastPeerID, result.LastRoute = progress.LastSyncAt, progress.LastPeerID, progress.LastRoute
	return result, nil
}
func (s *Store) ReadPeerRecord(ctx context.Context, account, kind, id string) (peerstore.Record, error) {
	if !peerstore.ValidID(kind) || !peerstore.ValidID(id) {
		return peerstore.Record{}, errors.New("invalid peer record identity")
	}
	db, err := s.peerDatabase(account)
	if err != nil {
		return peerstore.Record{}, err
	}
	var raw []byte
	err = db.QueryRowContext(ctx, "SELECT value FROM peer_records WHERE key=?", peerstore.Key(kind, id)).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return peerstore.Record{}, ErrNotFound
	}
	if err != nil {
		return peerstore.Record{}, err
	}
	return decodePeerRecord(raw)
}

type PeerRecordPage struct {
	Records           []peerstore.Record
	NextKey, Revision string
	PeerCheckpoint
}

// Pages pin a SQLite read snapshot, bounding decoded records and bytes. Replica
// epoch/sequence is an opaque snapshot identity; it needs no full-state hash.
func (s *Store) ListPeerRecordPage(ctx context.Context, account, kind, idPrefix, after, revision string, cursor *PeerCheckpoint) (PeerRecordPage, error) {
	result := PeerRecordPage{}
	db, err := s.peerDatabase(account)
	if err != nil {
		return result, err
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	if err = tx.QueryRow("SELECT epoch,sequence FROM peer_metadata WHERE id=1").Scan(&result.Epoch, &result.Sequence); err != nil {
		return result, err
	}
	result.Revision = peerstore.Revision([]any{account, result.Epoch, result.Sequence})
	if revision != "" && revision != result.Revision || cursor != nil && (cursor.Epoch != result.Epoch || cursor.Sequence != result.Sequence) {
		return result, peerstore.ErrConflict
	}
	prefix := ""
	var accept func(peerstore.Record) bool
	if kind == peerstore.KVKindPrefix {
		prefix = kind
		accept = func(r peerstore.Record) bool {
			return strings.HasPrefix(r.Kind, peerstore.KVKindPrefix) && strings.HasPrefix(r.ID, idPrefix)
		}
	} else if kind != "" {
		prefix = kind + "/" + idPrefix
	}
	var more bool
	maxBytes := peerstore.MaxPageBytes
	if strings.HasPrefix(kind, peerstore.KVKindPrefix) {
		maxBytes /= 2
	}
	result.Records, more, err = readPeerPage(tx, prefix, "", after, maxBytes, accept)
	if err != nil {
		return result, err
	}
	if more {
		last := result.Records[len(result.Records)-1]
		result.NextKey = peerstore.Key(last.Kind, last.ID)
	}
	return result, tx.Commit()
}
