package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/peerstore"
)

const peerViewCacheBytes = 4 << 20
const peerViewCacheRecords = 256

// Bound concurrent read transactions without queueing nested projections behind
// one another. Admission fails explicitly if the storage budget is exhausted.
var peerSnapshotSlots = make(chan struct{}, 64)

// A view reads bounded pages at one replica revision. Domain readers pin a
// snapshot; writer views check the revision between reads while holding the
// central cross-process lock. Neither path mixes causal baselines. All callers
// check Err before publishing a projection or committing effects.
type peerView struct {
	db       *sql.DB
	epoch    string
	sequence uint64
	err      error
	cache    map[string]peerstore.Record
	bytes    int
	snapshot *sql.Tx
	close    func()
}

// Domain projections pin an MVCC snapshot so an unrelated streamed update cannot
// abort a normal read. A separate read-only pool leaves the single writer
// connection available, including when a projection performs a nested read.
func (s *Store) openPeerSnapshot(account string) (PeerData, error) {
	if _, err := s.peerDatabase(account); err != nil {
		return PeerData{}, err
	}
	select {
	case peerSnapshotSlots <- struct{}{}:
	default:
		return PeerData{}, peerstore.ErrCapacity
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	v := &peerView{cache: map[string]peerstore.Record{}}
	v.close = func() {
		if v.snapshot != nil {
			_ = v.snapshot.Rollback()
		}
		cancel()
		<-peerSnapshotSlots
	}
	data := PeerData{view: v, State: peerstore.State{Records: map[string]peerstore.Record{}, Dirty: map[string]bool{}}}
	s.peerDBMu.Lock()
	if s.peerReadDBs == nil {
		s.peerReadDBs = map[string]*sql.DB{}
	}
	db := s.peerReadDBs[account]
	var err error
	if db == nil {
		query := url.Values{"mode": {"ro"}, "_pragma": {"query_only(1)", "cache_size(-4096)", "busy_timeout(10000)"}}
		dsn := (&url.URL{Scheme: "file", Path: s.peerPath(account), RawQuery: query.Encode()}).String()
		db, err = sql.Open("sqlite", dsn)
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

func (s *Store) openPeerView(account string) (PeerData, error) {
	db, err := s.peerDatabase(account)
	if err != nil {
		return PeerData{}, err
	}
	v := &peerView{db: db, cache: map[string]peerstore.Record{}}
	if err = db.QueryRow("SELECT epoch,sequence FROM peer_metadata WHERE id=1").Scan(&v.epoch, &v.sequence); err != nil {
		return PeerData{}, err
	}
	return PeerData{Epoch: v.epoch, Sequence: v.sequence, State: peerstore.State{Records: map[string]peerstore.Record{}, Dirty: map[string]bool{}}, view: v}, nil
}

func (d PeerData) Err() error {
	if d.view == nil {
		return nil
	}
	return d.view.err
}
func (d PeerData) record(key string) peerstore.Record {
	if r, ok := d.Records[key]; ok {
		return r
	}
	if d.view == nil || d.view.err != nil {
		return peerstore.Record{}
	}
	if r, ok := d.view.cache[key]; ok {
		return r
	}
	var r peerstore.Record
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
		if err = peerstore.ValidateRecord(r); err != nil {
			return err
		}
		d.view.remember(key, r, len(raw))
		return nil
	})
	return r
}
func (v *peerView) remember(key string, r peerstore.Record, size int) {
	if size > peerViewCacheBytes {
		return
	}
	if v.bytes+size > peerViewCacheBytes || len(v.cache) >= peerViewCacheRecords {
		clear(v.cache)
		v.bytes = 0
	}
	v.cache[key] = r
	v.bytes += size
}
func (v *peerView) read(f func(*sql.Tx) error) {
	if v.err != nil {
		return
	}
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
		err = peerstore.ErrConflict
	}
	if err == nil {
		err = f(tx)
	}
	if err == nil {
		err = tx.Commit()
	}
	v.err = err
}

// each scans in key order with a bounded page, overlaying pending local edits.
// Callbacks may perform point reads; no active SQL rows survive into a callback.
// A domain snapshot reuses its read transaction for those nested point reads.
func (d PeerData) each(prefix string, visit func(peerstore.Record) error) error {
	return d.eachMatching(prefix, "", visit)
}

func (d PeerData) eachMatching(prefix, suffix string, visit func(peerstore.Record) error) error {
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
			var page []peerstore.Record
			var more bool
			d.view.read(func(tx *sql.Tx) error {
				var err error
				page, more, err = readPeerPage(tx, prefix, suffix, after, peerstore.MaxPageBytes, nil)
				return err
			})
			if d.Err() != nil {
				return d.Err()
			}
			for _, r := range page {
				key := peerstore.Key(r.Kind, r.ID)
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
func readPeerPage(tx *sql.Tx, prefix, suffix, after string, maxBytes int, accept func(peerstore.Record) bool) ([]peerstore.Record, bool, error) {
	query := "SELECT key,value FROM peer_records WHERE key>? AND key>=? AND key<? AND (?='' OR substr(key,-length(?))=?) ORDER BY key"
	upper := prefix + "\x7f"
	rows, err := tx.Query(query, after, prefix, upper, suffix, suffix, suffix)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	records := make([]peerstore.Record, 0, peerstore.PageSize)
	size := 2
	for rows.Next() {
		var key string
		var raw []byte
		if err = rows.Scan(&key, &raw); err != nil {
			return nil, false, err
		}
		var r peerstore.Record
		if err = json.Unmarshal(raw, &r); err != nil {
			return nil, false, err
		}
		if key != peerstore.Key(r.Kind, r.ID) {
			return nil, false, errors.New("invalid peer record key")
		}
		if err = peerstore.ValidateRecord(r); err != nil {
			return nil, false, err
		}
		if accept != nil && !accept(r) {
			continue
		}
		if len(records) == peerstore.PageSize || len(records) > 0 && size+len(raw)+1 > maxBytes {
			return records, true, nil
		}
		records = append(records, r)
		size += len(raw) + 1
	}
	return records, false, rows.Err()
}

func (d PeerData) fail(err error) {
	if d.view != nil && d.view.err == nil {
		d.view.err = err
	}
}
func (d PeerData) assignmentIDs(id string) []string {
	if d.view == nil {
		return d.Membership[id]
	}
	var ids []string
	err := d.each("assignment/"+id+".", func(r peerstore.Record) error {
		if _, ok := peerstore.Selected(r); ok {
			entity, _ := peerstore.SplitField(r.ID)
			ids = append(ids, entity)
		}
		return nil
	})
	d.fail(err)
	return ids
}

func decodePeerRecord(raw []byte) (peerstore.Record, error) {
	var r peerstore.Record
	if err := json.Unmarshal(raw, &r); err != nil {
		return r, err
	}
	return r, peerstore.ValidateRecord(r)
}

// Most domain reads need several fields of one entity. Fetch them with one
// indexed range read and cache explicit absences too, within the same bounds.
func (d PeerData) primeEntity(kind, id string) {
	if d.view == nil || d.Err() != nil {
		return
	}
	complete := true
	for field := range peerstore.DomainFields[kind] {
		key := peerstore.Key(kind, id+"."+field)
		_, cached := d.view.cache[key]
		_, edited := d.Records[key]
		complete = complete && (cached || edited)
	}
	if complete {
		return
	}
	found := map[string]peerstore.Record{}
	err := d.each(kind+"/"+id+".", func(r peerstore.Record) error {
		entity, field := peerstore.SplitField(r.ID)
		if entity == id {
			if _, ok := peerstore.DomainFields[kind][field]; ok {
				found[field] = r
			}
		}
		return nil
	})
	d.fail(err)
	for field := range peerstore.DomainFields[kind] {
		r := found[field]
		raw, _ := json.Marshal(r)
		d.view.remember(peerstore.Key(kind, id+"."+field), r, len(raw))
	}
}
