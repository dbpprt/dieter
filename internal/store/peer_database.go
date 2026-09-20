package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"

	"github.com/dbpprt/dieter/internal/peerstore"
)

// The replica's rows and local change sequence commit in the same SQLite
// transaction. Sequence numbers are transport checkpoints, never causal clocks.
func (s *Store) peerDatabase(account string) (*sql.DB, error) {
	s.peerDBMu.Lock()
	defer s.peerDBMu.Unlock()
	if s.peerDBs == nil {
		s.peerDBs = map[string]*sql.DB{}
	}
	if db := s.peerDBs[account]; db != nil {
		return db, nil
	}
	path := s.peerPath(account)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	_ = file.Close()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	_, err = db.Exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=10000;
 CREATE TABLE IF NOT EXISTS peer_metadata (id INTEGER PRIMARY KEY CHECK(id=1), epoch TEXT NOT NULL, sequence INTEGER NOT NULL, record_count INTEGER NOT NULL DEFAULT 0, record_bytes INTEGER NOT NULL DEFAULT 0);
 CREATE TABLE IF NOT EXISTS peer_effects (path TEXT PRIMARY KEY, value BLOB, remove_file INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS peer_records (key TEXT PRIMARY KEY, revision TEXT NOT NULL, sequence INTEGER NOT NULL, value BLOB NOT NULL);
 CREATE INDEX IF NOT EXISTS peer_records_sequence ON peer_records(sequence);`)
	if err == nil {
		_, err = db.Exec("INSERT OR IGNORE INTO peer_metadata(id,epoch,sequence) VALUES(1,?,0)", newID("replica_"))
	}
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	s.peerDBs[account] = db
	return db, nil
}
func (s *Store) readPeerState(account string) (PeerData, error) {
	if _, err := os.Stat(s.peerPath(account)); errors.Is(err, os.ErrNotExist) {
		return PeerData{State: peerstore.State{Records: map[string]peerstore.Record{}}}, nil
	} else if err != nil {
		return PeerData{}, err
	}
	db, err := s.peerDatabase(account)
	if err != nil {
		return PeerData{}, err
	}
	var epoch string
	var seq uint64
	if err = db.QueryRow("SELECT epoch,sequence FROM peer_metadata WHERE id=1").Scan(&epoch, &seq); err != nil {
		return PeerData{}, err
	}
	s.peerCacheMu.Lock()
	defer s.peerCacheMu.Unlock()
	if s.peerCacheAccount == account && s.peerCacheData.Epoch == epoch && s.peerCacheData.Sequence == seq {
		return s.peerCacheData, nil
	}
	tx, err := db.Begin()
	if err != nil {
		return PeerData{}, err
	}
	defer tx.Rollback()
	if err = tx.QueryRow("SELECT epoch,sequence FROM peer_metadata WHERE id=1").Scan(&epoch, &seq); err != nil {
		return PeerData{}, err
	}
	rows, err := tx.Query("SELECT key,value FROM peer_records ORDER BY key")
	if err != nil {
		return PeerData{}, err
	}
	data := PeerData{State: peerstore.State{Records: map[string]peerstore.Record{}}, Epoch: epoch, Sequence: seq}
	for rows.Next() {
		var key string
		var raw []byte
		var record peerstore.Record
		if err = rows.Scan(&key, &raw); err != nil {
			break
		}
		if err = json.Unmarshal(raw, &record); err != nil {
			break
		}
		data.Records[key] = record
	}
	rowErr := rows.Err()
	_ = rows.Close()
	if err != nil {
		return data, err
	}
	if rowErr != nil {
		return data, rowErr
	}
	if err = tx.Commit(); err != nil {
		return data, err
	}
	if err = data.Validate(); err != nil {
		return data, err
	}
	indexPeerData(&data)
	s.peerCacheAccount, s.peerCacheData = account, data
	return data, nil
}
func (s *Store) writePeerState(account string, data PeerData, effects ...localEffect) error {
	db, err := s.peerDatabase(account)
	if err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var epoch string
	var seq uint64
	var count, size int64
	if err = tx.QueryRow("SELECT epoch,sequence,record_count,record_bytes FROM peer_metadata WHERE id=1").Scan(&epoch, &seq, &count, &size); err != nil {
		return err
	}
	previousSequence := seq
	keys := make([]string, 0, len(data.Dirty))
	if data.Dirty == nil {
		for key := range data.Records {
			keys = append(keys, key)
		}
		// Full writes are used only for import/bootstrap. Causal rows cannot vanish.
		rows, err := tx.Query("SELECT key FROM peer_records")
		if err != nil {
			return err
		}
		for rows.Next() {
			var key string
			if err = rows.Scan(&key); err != nil {
				break
			}
			if _, ok := data.Records[key]; !ok {
				err = errors.New("replica writes cannot remove causal records")
				break
			}
		}
		rowErr := rows.Err()
		_ = rows.Close()
		if err != nil {
			return err
		}
		if rowErr != nil {
			return rowErr
		}
	} else {
		if data.Epoch != "" && (data.Epoch != epoch || data.Sequence != seq) {
			return peerstore.ErrConflict
		}
		for key := range data.Dirty {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	for _, key := range keys {
		record := data.Records[key]
		record, err = s.signOwnerRecord(account, data, record)
		if err != nil {
			return err
		}
		data.Records[key] = record
		if err = (peerstore.State{Records: map[string]peerstore.Record{key: record}}).Validate(); err != nil {
			return err
		}
		if err = peerstore.ValidateSettings(record); err != nil {
			return err
		}
		revision := record.Revision()
		var previous string
		var previousSize int64
		e := tx.QueryRow("SELECT revision,length(value) FROM peer_records WHERE key=?", key).Scan(&previous, &previousSize)
		if errors.Is(e, sql.ErrNoRows) {
			count++
		} else if e != nil {
			return e
		}
		if previous == revision {
			continue
		}
		if seq >= 1<<63-1 {
			return peerstore.ErrCapacity
		}
		seq++
		raw, e := json.Marshal(record)
		if e != nil {
			return e
		}
		size += int64(len(raw)) - previousSize
		if count > peerstore.MaxRecords || size > peerstore.MaxStateBytes {
			return peerstore.ErrCapacity
		}
		if _, err = tx.Exec("INSERT INTO peer_records(key,revision,sequence,value) VALUES(?,?,?,?) ON CONFLICT(key) DO UPDATE SET revision=excluded.revision, sequence=excluded.sequence, value=excluded.value", key, revision, seq, raw); err != nil {
			return err
		}
	}
	if _, err = tx.Exec("UPDATE peer_metadata SET sequence=?,record_count=?,record_bytes=? WHERE id=1", seq, count, size); err != nil {
		return err
	}
	for _, effect := range effects {
		if _, err = tx.Exec("INSERT INTO peer_effects(path,value,remove_file) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET value=excluded.value,remove_file=excluded.remove_file", effect.Path, effect.Value, effect.Remove); err != nil {
			return err
		}
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	if seq != previousSequence {
		s.notifyPeerChanges()
	}
	data.Epoch, data.Sequence, data.Dirty = epoch, seq, nil
	indexPeerData(&data)
	s.peerCacheMu.Lock()
	s.peerCacheAccount, s.peerCacheData = account, data
	s.peerCacheMu.Unlock()
	return s.applyPeerEffects(db)
}

type PeerChanges struct {
	Epoch   string
	After   uint64
	More    bool
	Records []peerstore.Record
}

func (s *Store) PeerChanges(account, epoch string, after uint64) (PeerChanges, error) {
	db, err := s.peerDatabase(account)
	if err != nil {
		return PeerChanges{}, err
	}
	tx, err := db.Begin()
	if err != nil {
		return PeerChanges{}, err
	}
	defer tx.Rollback()
	result := PeerChanges{}
	var high uint64
	if err = tx.QueryRow("SELECT epoch,sequence FROM peer_metadata WHERE id=1").Scan(&result.Epoch, &high); err != nil {
		return result, err
	}
	if epoch != "" && epoch != result.Epoch {
		return result, peerstore.ErrConflict
	}
	if after > high {
		return result, peerstore.ErrConflict
	}
	rows, err := tx.Query("SELECT sequence,value FROM peer_records WHERE sequence>? ORDER BY sequence LIMIT ?", after, peerstore.PageSize+1)
	if err != nil {
		return result, err
	}
	result.After = after
	pageBytes := 2
	for rows.Next() {
		var seq uint64
		var raw []byte
		if err = rows.Scan(&seq, &raw); err != nil {
			break
		}
		if len(result.Records) == peerstore.PageSize || (len(result.Records) > 0 && pageBytes+len(raw)+1 > peerstore.MaxPageBytes) {
			result.More = true
			break
		}
		var record peerstore.Record
		if err = json.Unmarshal(raw, &record); err != nil {
			break
		}
		result.Records = append(result.Records, record)
		pageBytes += len(raw) + 1
		result.After = seq
	}
	rowErr := rows.Err()
	_ = rows.Close()
	if err != nil {
		return result, err
	}
	if rowErr != nil {
		return result, rowErr
	}
	if !result.More {
		result.After = high
	}
	return result, tx.Commit()
}

type PeerCheckpoint struct {
	Epoch    string `json:"epoch"`
	Sequence uint64 `json:"sequence"`
}

func (s *Store) PeerCheckpoint(account, peer, direction string) (PeerCheckpoint, error) {
	var value PeerCheckpoint
	err := readJSON(filepath.Join(s.Root, "peers", peerstore.Revision([]string{account, peer, direction})+".cursor"), &value)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, ErrNotFound) {
		err = nil
	}
	return value, err
}
func (s *Store) SavePeerCheckpoint(identity PeerIdentity, peer, direction string, value PeerCheckpoint) error {
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	if err = s.checkPeerIdentity(identity); err != nil {
		return err
	}
	return writeJSON(filepath.Join(s.Root, "peers", peerstore.Revision([]string{identity.Account, peer, direction})+".cursor"), value)
}
