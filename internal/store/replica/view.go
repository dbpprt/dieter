package replica

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
)

const peerViewCacheBytes = 4 << 20
const peerViewCacheRecords = 256

// Bound concurrent read transactions without queueing nested projections behind
// one another. Admission fails explicitly if the storage budget is exhausted.
const maxPeerSnapshots = 64

// A view reads bounded pages at one replica revision. Domain readers pin a
// snapshot; writer views check the revision between reads while holding the
// central cross-process lock. Neither path mixes causal baselines. All callers
// check Err before publishing a projection or committing effects.
type peerView struct {
	db       *sql.DB
	epoch    string
	sequence uint64
	err      error
	cache    map[string]crdt.Record
	bytes    int
	snapshot *sql.Tx
	close    func()
	shared   *snapshotRecordCache
	account  string
	queries  int
}

// Domain projections pin an MVCC snapshot so an unrelated streamed update cannot
// abort a normal read. A separate read-only pool leaves the single writer
// connection available, including when a projection performs a nested read.
func (s *Store) OpenPeerSnapshot(account string) (PeerData, error) {
	if _, err := s.peerDatabase(account); err != nil {
		return PeerData{}, err
	}
	select {
	case s.peerSnapshotSlots <- struct{}{}:
	default:
		return PeerData{}, crdt.ErrCapacity
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	v := &peerView{cache: map[string]crdt.Record{}}
	v.close = func() {
		if v.snapshot != nil {
			_ = v.snapshot.Rollback()
		}
		cancel()
		<-s.peerSnapshotSlots
	}
	data := PeerData{view: v, State: crdt.State{Records: map[string]crdt.Record{}, Dirty: map[string]bool{}}}
	s.peerDBMu.Lock()
	if s.peerReadDBs == nil {
		s.peerReadDBs = map[string]*sql.DB{}
	}
	db := s.peerReadDBs[account]
	var err error
	if db == nil {
		query := url.Values{"mode": {"ro"}, "_pragma": {"query_only(1)", "cache_size(-4096)", "busy_timeout(10000)"}}
		dsn := (&url.URL{Scheme: "file", Path: s.peerPath(account), RawQuery: query.Encode()}).String()
		db, err = home.OpenSQLite(dsn)
		if err == nil {
			db.SetMaxIdleConns(4)
			s.peerReadDBs[account] = db
		}
	}
	s.peerDBMu.Unlock()
	if err == nil {
		v.snapshot, err = db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	}
	if err == nil {
		err = v.snapshot.QueryRow("SELECT epoch,sequence FROM peer_metadata WHERE id=1").Scan(&v.epoch, &v.sequence)
	}
	if err != nil {
		data.Close()
		return PeerData{}, err
	}
	v.shared, v.account = &s.snapshotRecords, account
	data.Epoch, data.Sequence = v.epoch, v.sequence
	return data, nil
}

// Close releases a domain read snapshot. Optimistic writer views and diagnostic
// materializations own no transaction, so closing them is a no-op.
func (d PeerData) Close() {
	if d.view != nil && d.view.close != nil {
		d.view.close()
		d.view.close = nil
	}
}

// OpenPeerView reads the account's records for a mutation; hold the writer
// lock and close the view.
func (s *Store) OpenPeerView(account string) (PeerData, error) {
	db, err := s.peerDatabase(account)
	if err != nil {
		return PeerData{}, err
	}
	v := &peerView{db: db, cache: map[string]crdt.Record{}}
	if err = db.QueryRow("SELECT epoch,sequence FROM peer_metadata WHERE id=1").Scan(&v.epoch, &v.sequence); err != nil {
		return PeerData{}, err
	}
	return PeerData{Epoch: v.epoch, Sequence: v.sequence, State: crdt.State{Records: map[string]crdt.Record{}, Dirty: map[string]bool{}}, view: v}, nil
}

// Err reports the first read failure of the view.
func (d PeerData) Err() error {
	if d.view == nil {
		return nil
	}
	return d.view.err
}

// Record returns one record of the view, or the zero record.
func (d PeerData) Record(key string) crdt.Record {
	if r, ok := d.Records[key]; ok {
		return r
	}
	if d.view == nil || d.view.err != nil {
		return crdt.Record{}
	}
	if r, ok := d.view.cached(key); ok {
		return r
	}
	var r crdt.Record
	d.view.read(func(tx *sql.Tx) error {
		var raw []byte
		err := tx.QueryRow("SELECT value FROM peer_records WHERE key=?", key).Scan(&raw)
		if errors.Is(err, sql.ErrNoRows) {
			d.view.remember(key, r, len(key))
			return nil
		}
		if err != nil {
			return err
		}
		if err = json.Unmarshal(raw, &r); err != nil {
			return err
		}
		if err = crdt.ValidateRecord(r); err != nil {
			return err
		}
		d.view.remember(key, r, len(raw))
		return nil
	})
	return r
}
func (v *peerView) remember(key string, r crdt.Record, size int) {
	if size > peerViewCacheBytes {
		return
	}
	if v.bytes+size > peerViewCacheBytes || len(v.cache) >= peerViewCacheRecords {
		clear(v.cache)
		v.bytes = 0
	}
	v.cache[key] = r
	v.bytes += size
	if v.shared != nil {
		v.shared.remember(v, key, r, size)
	}
}

func (v *peerView) cached(key string) (crdt.Record, bool) {
	if r, ok := v.cache[key]; ok {
		return r, true
	}
	if v.shared != nil {
		if r, size, ok := v.shared.record(v, key); ok {
			// The shared cache returns owned data. Keep it in this view without
			// publishing it back into the shared cache.
			if v.bytes+size > peerViewCacheBytes || len(v.cache) >= peerViewCacheRecords {
				clear(v.cache)
				v.bytes = 0
			}
			v.cache[key] = r
			v.bytes += size
			return r, true
		}
	}
	return crdt.Record{}, false
}
func (v *peerView) read(f func(*sql.Tx) error) {
	if v.err != nil {
		return
	}
	v.queries++
	if v.snapshot != nil {
		v.err = f(v.snapshot)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tx, err := v.db.BeginTx(ctx, nil)
	if err != nil {
		v.err = err
		return
	}
	defer tx.Rollback()
	var epoch string
	var sequence uint64
	if err = tx.QueryRow("SELECT epoch,sequence FROM peer_metadata WHERE id=1").Scan(&epoch, &sequence); err == nil && (epoch != v.epoch || sequence != v.sequence) {
		err = crdt.ErrConflict
	}
	if err == nil {
		err = f(tx)
	}
	if err == nil {
		err = tx.Commit()
	}
	v.err = err
}

// Each scans in key order with a bounded page, overlaying pending local edits.
// Callbacks may perform point reads; no active SQL rows survive into a callback.
// A domain snapshot reuses its read transaction for those nested point reads.
func (d PeerData) Each(prefix string, visit func(crdt.Record) error) error {
	return d.EachMatching(prefix, "", visit)
}

// EachMatching is Each restricted to keys that also end with suffix.
func (d PeerData) EachMatching(prefix, suffix string, visit func(crdt.Record) error) error {
	keys := make([]string, 0, len(d.Records))
	for key := range d.Records {
		if strings.HasPrefix(key, prefix) && strings.HasSuffix(key, suffix) {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	emitBefore := func(key string) error {
		for len(keys) > 0 && (key == "" || keys[0] < key) {
			if err := visit(d.Records[keys[0]]); err != nil {
				return err
			}
			keys = keys[1:]
		}
		return nil
	}
	if d.view != nil {
		after := ""
		for {
			var page []crdt.Record
			var more bool
			d.view.read(func(tx *sql.Tx) error {
				var err error
				page, more, err = readPeerPage(tx, prefix, suffix, after, crdt.MaxPageBytes, nil)
				return err
			})
			if d.Err() != nil {
				return d.Err()
			}
			for _, r := range page {
				key := crdt.Key(r.Kind, r.ID)
				if err := emitBefore(key); err != nil {
					return err
				}
				if len(keys) > 0 && keys[0] == key {
					r = d.Records[key]
					keys = keys[1:]
				}
				if err := visit(r); err != nil {
					return err
				}
				after = key
			}
			if !more {
				break
			}
		}
	}
	if err := emitBefore(""); err != nil {
		return err
	}
	return d.Err()
}

// The lexical range uses only validated ASCII peer keys. Filtering is evaluated
// before the page bound so an unrelated namespace cannot starve a KV page.
func readPeerPage(tx *sql.Tx, prefix, suffix, after string, maxBytes int, accept func(crdt.Record) bool) ([]crdt.Record, bool, error) {
	query := "SELECT key,value FROM peer_records WHERE key>? AND key>=? AND key<? AND (?='' OR substr(key,-length(?))=?) ORDER BY key"
	upper := prefix + "\x7f"
	rows, err := tx.Query(query, after, prefix, upper, suffix, suffix, suffix)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	records := make([]crdt.Record, 0, crdt.PageSize)
	size := 2
	for rows.Next() {
		var key string
		var raw []byte
		if err = rows.Scan(&key, &raw); err != nil {
			return nil, false, err
		}
		var r crdt.Record
		if err = json.Unmarshal(raw, &r); err != nil {
			return nil, false, err
		}
		if key != crdt.Key(r.Kind, r.ID) {
			return nil, false, fault.New(fault.Invalid, "invalid peer record key")
		}
		if err = crdt.ValidateRecord(r); err != nil {
			return nil, false, err
		}
		if accept != nil && !accept(r) {
			continue
		}
		if len(records) == crdt.PageSize || len(records) > 0 && size+len(raw)+1 > maxBytes {
			return records, true, nil
		}
		records = append(records, r)
		size += len(raw) + 1
	}
	return records, false, rows.Err()
}

// Fail records the first error of a projection; Err reports it.
func (d PeerData) Fail(err error) {
	if d.view != nil && d.view.err == nil {
		d.view.err = err
	}
}

// AssignmentIDs lists the card-label assignment entities of card id.
func (d PeerData) AssignmentIDs(id string) []string {
	if d.view == nil {
		return d.Membership[id]
	}
	var ids []string
	err := d.Each("assignment/"+id+".", func(r crdt.Record) error {
		if _, ok := crdt.Selected(r); ok {
			entity, _ := crdt.SplitField(r.ID)
			ids = append(ids, entity)
		}
		return nil
	})
	d.Fail(err)
	return ids
}

func decodePeerRecord(raw []byte) (crdt.Record, error) {
	var r crdt.Record
	if err := json.Unmarshal(raw, &r); err != nil {
		return r, err
	}
	return r, crdt.ValidateRecord(r)
}

// Most domain reads need several fields of one entity. Fetch them with one
// indexed range read and cache explicit absences too, within the same bounds.
func (d PeerData) primeEntity(kind, id string) {
	if d.view == nil || d.Err() != nil {
		return
	}
	complete := true
	for field := range schema.DomainFields[kind] {
		key := crdt.Key(kind, id+"."+field)
		_, cached := d.view.cached(key)
		_, edited := d.Records[key]
		complete = complete && (cached || edited)
	}
	if complete {
		return
	}
	found := map[string]crdt.Record{}
	err := d.Each(kind+"/"+id+".", func(r crdt.Record) error {
		entity, field := crdt.SplitField(r.ID)
		if entity == id {
			if _, ok := schema.DomainFields[kind][field]; ok {
				found[field] = r
			}
		}
		return nil
	})
	d.Fail(err)
	for field := range schema.DomainFields[kind] {
		r := found[field]
		raw, _ := json.Marshal(r)
		d.view.remember(crdt.Key(kind, id+"."+field), r, len(raw))
	}
}
