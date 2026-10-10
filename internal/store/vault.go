package store

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/vault"
)

// The account vault replicates only ciphertext through the peer store. This
// machine's member seed and its pinned vault root live in DIETER_HOME/vault and
// never leave the machine; decrypted items exist only in daemon memory.

type vaultMemberFile struct {
	ID       string `json:"id"`
	Seed     string `json:"seed"`
	VaultID  string `json:"vaultId,omitempty"`
	RootHash string `json:"rootHash,omitempty"`
}

type VaultMember struct {
	ID          string
	Name        string
	DaemonID    string
	Recovery    bool
	Pending     bool
	Self        bool
	Code        string
	RequestedAt string
	ApprovedAt  string
	ApprovedBy  string
}

const (
	VaultStateNone     = "none"
	VaultStateLocked   = "locked"
	VaultStatePending  = "pending"
	VaultStateUnlocked = "unlocked"
)

type VaultStatus struct {
	State      string
	VaultID    string
	CurrentKey string
	MemberID   string
	JoinCode   string
	Members    []VaultMember
	Items      int
	Conflicts  []string
	CreatedAt  string
}

type VaultItem struct {
	ID       string
	Revision string
	Conflict bool
	Item     vault.Item
	// Error is set when this machine cannot authenticate the item. It is
	// listed but never revealed, edited or re-encrypted.
	Error string
}

type VaultAuditEntry struct {
	Time     string `json:"time"`
	Action   string `json:"action"`
	ItemID   string `json:"itemId,omitempty"`
	ItemName string `json:"itemName,omitempty"`
	Fields   string `json:"fields,omitempty"`
	Caller   string `json:"caller"`
	CardID   string `json:"cardId,omitempty"`
	Route    string `json:"route,omitempty"`
	Outcome  string `json:"outcome"`
	Detail   string `json:"detail,omitempty"`
}

var vaultB64 = base64.RawStdEncoding

func (s *Store) vaultDir() string               { return filepath.Join(s.Root, "vault") }
func (s *Store) vaultMemberPath() string        { return filepath.Join(s.vaultDir(), "member.json") }
func (s *Store) vaultAuditPath() string         { return filepath.Join(s.vaultDir(), "audit.ndjson") }
func vaultKey(kind, id string) string           { return peerstore.Key(kind, id) }
func vaultNow() string                          { return time.Now().UTC().Format(time.RFC3339) }
func (f vaultMemberFile) seed() ([]byte, error) { return vaultB64.DecodeString(f.Seed) }

func (s *Store) readVaultMember() (vaultMemberFile, error) {
	var file vaultMemberFile
	raw, err := os.ReadFile(s.vaultMemberPath())
	if err != nil {
		return file, err
	}
	if err = json.Unmarshal(raw, &file); err != nil {
		return file, fmt.Errorf("read vault member key: %w", err)
	}
	if seed, err := file.seed(); err != nil || len(seed) != 32 || !peerstore.ValidID(file.ID) {
		return file, errors.New("vault member key file is malformed")
	}
	return file, nil
}

// loadOrCreateVaultMember runs under the writer lock.
func (s *Store) loadOrCreateVaultMember() (vaultMemberFile, error) {
	file, err := s.readVaultMember()
	if err == nil || !errors.Is(err, os.ErrNotExist) {
		return file, err
	}
	file = vaultMemberFile{ID: vault.RandomID("vm_"), Seed: vaultB64.EncodeToString(vault.NewMemberSeed())}
	return file, s.writeVaultMember(file)
}

func (s *Store) writeVaultMember(file vaultMemberFile) error {
	if err := os.MkdirAll(s.vaultDir(), 0o700); err != nil {
		return err
	}
	return writeJSON(s.vaultMemberPath(), file)
}

type vaultView struct {
	data    PeerData
	record  vault.Record
	exists  bool
	member  vaultMemberFile
	hasSeed bool
	ring    vault.Keyring
	keys    map[string][]byte
}

func selectedJSON(record peerstore.Record, value any) (bool, error) {
	raw, ok := peerstore.Selected(record)
	if !ok {
		return false, nil
	}
	return true, json.Unmarshal(raw, value)
}

// vaultRecord returns the vault metadata. Concurrent rotations leave siblings
// of one vault; siblings with different vault IDs mean two machines initialized
// a vault concurrently, which needs an explicit operator decision.
func vaultRecord(data PeerData) (vault.Record, bool, error) {
	record := data.record(vaultKey(vault.KindVault, vault.VaultRecordID))
	var selected vault.Record
	ok, err := selectedJSON(record, &selected)
	if err != nil || !ok {
		return selected, ok, err
	}
	for _, version := range record.Versions {
		var sibling vault.Record
		if json.Unmarshal(version.Value, &sibling) == nil && sibling.ID != selected.ID {
			return selected, true, errors.New("two vaults were initialized concurrently; inspect both with `dieter peer show --kind vault --id vault` and keep one with `dieter peer put --kind vault --id vault --revision REV --file VALUE.json`")
		}
	}
	return selected, true, nil
}

func (s *Store) openVault(data PeerData) (vaultView, error) {
	view := vaultView{data: data}
	var err error
	view.record, view.exists, err = vaultRecord(data)
	if err != nil {
		return view, err
	}
	member, err := s.readVaultMember()
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return view, err
	}
	view.member, view.hasSeed = member, err == nil
	if !view.exists || !view.hasSeed || member.VaultID == "" {
		return view, nil
	}
	if member.VaultID != view.record.ID {
		return view, nil
	}
	seed, err := member.seed()
	if err != nil {
		return view, err
	}
	var rings []vault.Keyring
	for _, version := range data.record(vaultKey(vault.KindMember, member.ID)).Versions {
		var value vault.Member
		if version.Deleted || json.Unmarshal(version.Value, &value) != nil || value.Keyring == "" {
			continue
		}
		ring, openErr := vault.Open(seed, value.Keyring, member.VaultID, member.ID)
		if openErr != nil {
			return view, fmt.Errorf("open this machine's vault keyring: %w", openErr)
		}
		rings = append(rings, ring)
	}
	if len(rings) == 0 {
		return view, nil
	}
	view.ring = vault.Union(rings...)
	if view.keys, err = view.ring.Verify(member.VaultID, member.RootHash); err != nil {
		return view, fmt.Errorf("verify this machine's vault keyring: %w", err)
	}
	return view, nil
}

func (v vaultView) unlocked() error {
	switch {
	case !v.exists:
		return vault.ErrNoVault
	case v.keys == nil:
		return fmt.Errorf("%w; run `dieter vault join` on this machine", vault.ErrLocked)
	}
	return nil
}

func (v vaultView) currentKey() string {
	if _, ok := v.keys[v.record.Current]; ok {
		return v.record.Current
	}
	// A concurrently rotated current key may not have reached this keyring yet.
	return v.record.Root
}

func (s *Store) vaultSnapshot() (PeerData, error) {
	identity, err := s.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		return PeerData{State: peerstore.State{Records: map[string]peerstore.Record{}}}, nil
	}
	if err != nil {
		return PeerData{}, err
	}
	return s.openPeerSnapshot(identity.Account)
}

func (s *Store) withVault(read func(vaultView) error) error {
	data, err := s.vaultSnapshot()
	if err != nil {
		return err
	}
	defer data.Close()
	view, err := s.openVault(data)
	if err != nil {
		return err
	}
	if err = read(view); err != nil {
		return err
	}
	return data.Err()
}

func (s *Store) mutateVault(mutate func(identity PeerIdentity, view vaultView) error) error {
	identity, err := s.KVIdentity()
	if err != nil {
		return err
	}
	release, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer release()
	if err = s.checkPeerIdentity(identity); err != nil {
		return err
	}
	data, err := s.openPeerView(identity.Account)
	if err != nil {
		return err
	}
	data.State = clonePeerState(data.State)
	view, err := s.openVault(data)
	if err != nil {
		return err
	}
	if err = mutate(identity, view); err != nil {
		return err
	}
	if err = data.Err(); err != nil {
		return err
	}
	if len(data.Dirty) == 0 {
		return nil
	}
	return s.savePeerData(identity.Account, data)
}

func putVaultRecord(data PeerData, identity PeerIdentity, kind, id string, value any, deleted bool) error {
	key := vaultKey(kind, id)
	old := data.record(key)
	var raw []byte
	if !deleted {
		var err error
		if raw, err = json.Marshal(value); err != nil {
			return err
		}
	}
	record, err := peerstore.Put(old, kind, id, identity.Actor, old.Revision(), raw, deleted)
	if err != nil {
		return err
	}
	if err = peerstore.ValidateSettings(record); err != nil {
		return err
	}
	data.Records[key], data.Dirty[key] = record, true
	return nil
}

func vaultMembers(data PeerData) (map[string]vault.Member, error) {
	members := map[string]vault.Member{}
	err := data.each(vault.KindMember+"/", func(record peerstore.Record) error {
		if record.Kind != vault.KindMember {
			return nil
		}
		var member vault.Member
		ok, err := selectedJSON(record, &member)
		if err == nil && ok {
			members[record.ID] = member
		}
		return err
	})
	return members, err
}

func (s *Store) VaultStatus() (VaultStatus, error) {
	var status VaultStatus
	err := s.withVault(func(view vaultView) error {
		status.State = VaultStateNone
		if view.hasSeed {
			status.MemberID = view.member.ID
		}
		if !view.exists {
			return nil
		}
		status.VaultID, status.CurrentKey, status.CreatedAt = view.record.ID, view.record.Current, view.record.CreatedAt
		members, err := vaultMembers(view.data)
		if err != nil {
			return err
		}
		pinned := view.hasSeed && view.member.VaultID == view.record.ID
		switch {
		case view.keys != nil:
			status.State = VaultStateUnlocked
		case pinned && members[view.member.ID].PublicKey != "":
			status.State = VaultStatePending
		default:
			status.State = VaultStateLocked
		}
		for id, member := range members {
			item := VaultMember{ID: id, Name: member.Name, DaemonID: member.DaemonID, Recovery: member.Recovery, Pending: member.Keyring == "",
				Self: view.hasSeed && id == view.member.ID, RequestedAt: member.RequestedAt, ApprovedAt: member.ApprovedAt, ApprovedBy: member.ApprovedBy}
			// Codes are computed from this machine's pinned root, never from a
			// replicated hint, so a substituted key cannot reproduce them.
			if item.Pending && pinned {
				if public, err := vaultB64.DecodeString(member.PublicKey); err == nil {
					item.Code = vault.JoinCode(view.member.VaultID, view.member.RootHash, id, public)
				}
			}
			if item.Self && item.Pending {
				status.JoinCode = item.Code
			}
			status.Members = append(status.Members, item)
		}
		sort.Slice(status.Members, func(i, j int) bool { return status.Members[i].ID < status.Members[j].ID })
		return view.data.each(vault.KindItem+"/", func(record peerstore.Record) error {
			if record.Kind != vault.KindItem {
				return nil
			}
			if _, ok := peerstore.Selected(record); ok {
				status.Items++
				if len(record.Versions) > 1 {
					status.Conflicts = append(status.Conflicts, record.ID)
				}
			}
			return nil
		})
	})
	return status, err
}

// InitVault creates the account vault and returns its printable recovery key,
// which is never stored.
func (s *Store) InitVault(name, daemonID string) (string, error) {
	var recoveryKey string
	err := s.mutateVault(func(identity PeerIdentity, view vaultView) error {
		if view.exists {
			return errors.New("a vault already exists for this account; run `dieter vault join` on this machine instead")
		}
		member, err := s.loadOrCreateVaultMember()
		if err != nil {
			return err
		}
		now := vaultNow()
		record, ring := vault.New(now)
		keys, err := ring.Verify(record.ID, record.RootHash)
		if err != nil {
			return err
		}
		recoverySeed, printed := vault.NewRecoveryKey()
		rootID, rootKey, _ := ring.RootKey(keys)
		if ring.RecoveryCheck, err = vault.RecoveryCheck(recoverySeed, record.ID, rootID, rootKey); err != nil {
			return err
		}
		member.VaultID, member.RootHash = record.ID, record.RootHash
		if err = s.writeVaultMember(member); err != nil {
			return err
		}
		if err = putVaultRecord(view.data, identity, vault.KindVault, vault.VaultRecordID, record, false); err != nil {
			return err
		}
		if err = sealVaultMember(view.data, identity, member.ID, vault.Member{Name: name, DaemonID: daemonID, RequestedAt: now, ApprovedAt: now, ApprovedBy: member.ID}, member, ring); err != nil {
			return err
		}
		if err = sealRecoveryMember(view.data, identity, recoverySeed, ring); err != nil {
			return err
		}
		recoveryKey = printed
		return nil
	})
	return recoveryKey, err
}

func sealVaultMember(data PeerData, identity PeerIdentity, id string, value vault.Member, own vaultMemberFile, ring vault.Keyring) error {
	if value.PublicKey == "" {
		seed, err := own.seed()
		if err != nil {
			return err
		}
		public, err := vault.PublicKey(seed)
		if err != nil {
			return err
		}
		value.PublicKey = vaultB64.EncodeToString(public)
	}
	public, err := vaultB64.DecodeString(value.PublicKey)
	if err != nil {
		return err
	}
	if value.Keyring, err = vault.Seal(public, ring, id); err != nil {
		return err
	}
	return putVaultRecord(data, identity, vault.KindMember, id, value, false)
}

func sealRecoveryMember(data PeerData, identity PeerIdentity, seed []byte, ring vault.Keyring) error {
	public, err := vault.PublicKey(seed)
	if err != nil {
		return err
	}
	value := vault.Member{PublicKey: vaultB64.EncodeToString(public), Recovery: true, ApprovedAt: vaultNow()}
	if value.Keyring, err = vault.Seal(public, ring, vault.RecoveryMemberID); err != nil {
		return err
	}
	return putVaultRecord(data, identity, vault.KindMember, vault.RecoveryMemberID, value, false)
}

// RequestVaultJoin publishes this machine's public key and pins the replicated
// root it observes. The returned code must match the code an existing member
// shows before that member approves this machine.
func (s *Store) RequestVaultJoin(name, daemonID string) (string, error) {
	var code string
	err := s.mutateVault(func(identity PeerIdentity, view vaultView) error {
		if !view.exists {
			return errors.New("no vault has replicated to this machine yet; wait for peer sync, run `dieter vault init` on the first machine, or join with --recovery-key-stdin")
		}
		if view.keys != nil {
			return errors.New("this machine is already an unlocked vault member")
		}
		member, err := s.loadOrCreateVaultMember()
		if err != nil {
			return err
		}
		if member.VaultID != view.record.ID {
			member.VaultID, member.RootHash = view.record.ID, view.record.RootHash
			if err = s.writeVaultMember(member); err != nil {
				return err
			}
		}
		seed, err := member.seed()
		if err != nil {
			return err
		}
		public, err := vault.PublicKey(seed)
		if err != nil {
			return err
		}
		code = vault.JoinCode(member.VaultID, member.RootHash, member.ID, public)
		var existing vault.Member
		if ok, _ := selectedJSON(view.data.record(vaultKey(vault.KindMember, member.ID)), &existing); ok && existing.PublicKey == vaultB64.EncodeToString(public) {
			return nil
		}
		return putVaultRecord(view.data, identity, vault.KindMember, member.ID, vault.Member{PublicKey: vaultB64.EncodeToString(public), Name: name, DaemonID: daemonID, RequestedAt: vaultNow()}, false)
	})
	return code, err
}

// JoinVaultWithRecovery unlocks this machine with the printed recovery key. The
// key authenticates the vault root, so no replicated metadata is trusted.
func (s *Store) JoinVaultWithRecovery(recoveryKey, name, daemonID string) error {
	seed, err := vault.ParseRecoveryKey(recoveryKey)
	if err != nil {
		return err
	}
	return s.mutateVault(func(identity PeerIdentity, view vaultView) error {
		if !view.exists {
			return errors.New("no vault has replicated to this machine yet; wait for peer sync")
		}
		recovery := view.data.record(vaultKey(vault.KindMember, vault.RecoveryMemberID))
		public, err := vault.PublicKey(seed)
		if err != nil {
			return err
		}
		var rings []vault.Keyring
		for _, version := range recovery.Versions {
			var value vault.Member
			if version.Deleted || json.Unmarshal(version.Value, &value) != nil || value.PublicKey != vaultB64.EncodeToString(public) {
				continue
			}
			ring, err := vault.Open(seed, value.Keyring, view.record.ID, vault.RecoveryMemberID)
			if err != nil {
				return err
			}
			rings = append(rings, ring)
		}
		if len(rings) == 0 {
			return vault.ErrWrongRecovery
		}
		ring := vault.Union(rings...)
		pinned, err := vault.RecoveredRoot(seed, ring)
		if err != nil {
			return err
		}
		if pinned != view.record.RootHash {
			return vault.ErrTampered
		}
		if _, err = ring.Verify(view.record.ID, pinned); err != nil {
			return err
		}
		member, err := s.loadOrCreateVaultMember()
		if err != nil {
			return err
		}
		member.VaultID, member.RootHash = view.record.ID, pinned
		if err = s.writeVaultMember(member); err != nil {
			return err
		}
		now := vaultNow()
		return sealVaultMember(view.data, identity, member.ID, vault.Member{Name: name, DaemonID: daemonID, RequestedAt: now, ApprovedAt: now, ApprovedBy: "recovery-key"}, member, ring)
	})
}

// ApproveVaultMember seals the keyring to a pending member after the operator
// confirms the code shown on the joining machine.
func (s *Store) ApproveVaultMember(memberID, code string) error {
	return s.mutateVault(func(identity PeerIdentity, view vaultView) error {
		if err := view.unlocked(); err != nil {
			return err
		}
		var member vault.Member
		ok, err := selectedJSON(view.data.record(vaultKey(vault.KindMember, memberID)), &member)
		if err != nil {
			return err
		}
		if !ok || member.Recovery {
			return fmt.Errorf("vault member %q is not a pending machine", memberID)
		}
		public, err := vaultB64.DecodeString(member.PublicKey)
		if err != nil {
			return err
		}
		if !vault.SameCode(vault.JoinCode(view.member.VaultID, view.member.RootHash, memberID, public), code) {
			return errors.New("join code does not match; compare the code printed by `dieter vault join` on the joining machine")
		}
		member.ApprovedAt, member.ApprovedBy = vaultNow(), view.member.ID
		return sealVaultMember(view.data, identity, memberID, member, view.member, view.ring)
	})
}

// RemoveVaultMember revokes a machine and rotates to a key it never received.
// A removed machine keeps whatever it already decrypted.
func (s *Store) RemoveVaultMember(memberID string) error {
	return s.mutateVault(func(identity PeerIdentity, view vaultView) error {
		if err := view.unlocked(); err != nil {
			return err
		}
		if memberID == vault.RecoveryMemberID {
			return errors.New("replace the recovery key with `dieter vault rotate --recovery-key`")
		}
		if memberID == view.member.ID {
			return errors.New("remove this machine from another vault member")
		}
		if _, ok := peerstore.Selected(view.data.record(vaultKey(vault.KindMember, memberID))); !ok {
			return fmt.Errorf("vault member %q was not found", memberID)
		}
		if err := putVaultRecord(view.data, identity, vault.KindMember, memberID, nil, true); err != nil {
			return err
		}
		_, err := rotateVault(view, identity, false)
		return err
	})
}

// RotateVault creates a new current key, reseals every approved member and
// re-encrypts every item. A new recovery key is returned when requested.
func (s *Store) RotateVault(newRecovery bool) (string, error) {
	var printed string
	err := s.mutateVault(func(identity PeerIdentity, view vaultView) error {
		if err := view.unlocked(); err != nil {
			return err
		}
		var err error
		printed, err = rotateVault(view, identity, newRecovery)
		return err
	})
	return printed, err
}

func rotateVault(view vaultView, identity PeerIdentity, newRecovery bool) (string, error) {
	ring, current, err := view.ring.Rotate(view.keys, view.currentKey())
	if err != nil {
		return "", err
	}
	keys, err := ring.Verify(view.member.VaultID, view.member.RootHash)
	if err != nil {
		return "", err
	}
	var printed string
	var recoverySeed []byte
	if newRecovery {
		recoverySeed, printed = vault.NewRecoveryKey()
		rootID, rootKey, _ := ring.RootKey(keys)
		if ring.RecoveryCheck, err = vault.RecoveryCheck(recoverySeed, view.member.VaultID, rootID, rootKey); err != nil {
			return "", err
		}
	}
	record := view.record
	record.Current = current
	if err = putVaultRecord(view.data, identity, vault.KindVault, vault.VaultRecordID, record, false); err != nil {
		return "", err
	}
	members, err := vaultMembers(view.data)
	if err != nil {
		return "", err
	}
	for id, member := range members {
		if member.Keyring == "" {
			continue
		}
		if member.Recovery {
			if newRecovery {
				err = sealRecoveryMember(view.data, identity, recoverySeed, ring)
			} else {
				err = sealVaultMember(view.data, identity, id, member, view.member, ring)
			}
		} else {
			err = sealVaultMember(view.data, identity, id, member, view.member, ring)
		}
		if err != nil {
			return "", err
		}
	}
	items, err := vaultItems(view)
	if err != nil {
		return "", err
	}
	for _, item := range items {
		if item.Error != "" {
			continue
		}
		envelope, err := vault.SealItem(keys, current, view.member.VaultID, item.ID, item.Item)
		if err != nil {
			return "", err
		}
		if err = putVaultRecord(view.data, identity, vault.KindItem, item.ID, envelope, false); err != nil {
			return "", err
		}
	}
	return printed, nil
}

func vaultItems(view vaultView) ([]VaultItem, error) {
	var items []VaultItem
	err := view.data.each(vault.KindItem+"/", func(record peerstore.Record) error {
		if record.Kind != vault.KindItem {
			return nil
		}
		raw, ok := peerstore.Selected(record)
		if !ok {
			return nil
		}
		var envelope vault.Envelope
		if err := json.Unmarshal(raw, &envelope); err != nil {
			return err
		}
		item, err := vault.OpenItem(view.keys, view.member.VaultID, record.ID, envelope)
		value := VaultItem{ID: record.ID, Revision: record.Revision(), Conflict: len(record.Versions) > 1, Item: item}
		if err != nil {
			value.Error = err.Error()
		}
		items = append(items, value)
		return nil
	})
	sort.Slice(items, func(i, j int) bool {
		left, right := strings.ToLower(items[i].Item.Name), strings.ToLower(items[j].Item.Name)
		return left < right || left == right && items[i].ID < items[j].ID
	})
	return items, err
}

func resolveVaultItem(items []VaultItem, ref string) (VaultItem, error) {
	ref = strings.TrimSpace(ref)
	var matches []VaultItem
	for _, item := range items {
		if item.ID == ref {
			if item.Error != "" {
				return VaultItem{}, fmt.Errorf("vault item %s cannot be opened on this machine: %s", item.ID, item.Error)
			}
			return item, nil
		}
		if item.Error == "" && strings.EqualFold(item.Item.Name, ref) {
			matches = append(matches, item)
		}
	}
	switch len(matches) {
	case 0:
		return VaultItem{}, fmt.Errorf("%w: vault item %q", ErrNotFound, ref)
	case 1:
		return matches[0], nil
	}
	ids := make([]string, 0, len(matches))
	for _, item := range matches {
		ids = append(ids, item.ID)
	}
	return VaultItem{}, fmt.Errorf("vault item name %q is ambiguous; use one of %s", ref, strings.Join(ids, ", "))
}

func (s *Store) ListVaultItems() ([]VaultItem, error) {
	var items []VaultItem
	err := s.withVault(func(view vaultView) error {
		if err := view.unlocked(); err != nil {
			return err
		}
		var err error
		items, err = vaultItems(view)
		return err
	})
	return items, err
}

func (s *Store) VaultItem(ref string) (VaultItem, error) {
	var result VaultItem
	err := s.withVault(func(view vaultView) error {
		if err := view.unlocked(); err != nil {
			return err
		}
		items, err := vaultItems(view)
		if err != nil {
			return err
		}
		result, err = resolveVaultItem(items, ref)
		return err
	})
	return result, err
}

func uniqueVaultName(items []VaultItem, name, except string) error {
	for _, item := range items {
		if item.ID != except && strings.EqualFold(item.Item.Name, name) {
			return fmt.Errorf("a vault item named %q already exists (%s)", name, item.ID)
		}
	}
	return nil
}

func (s *Store) CreateVaultItem(item vault.Item, actor string) (VaultItem, error) {
	var result VaultItem
	err := s.mutateVault(func(identity PeerIdentity, view vaultView) error {
		if err := view.unlocked(); err != nil {
			return err
		}
		items, err := vaultItems(view)
		if err != nil {
			return err
		}
		if err = uniqueVaultName(items, item.Name, ""); err != nil {
			return err
		}
		now := vaultNow()
		item.CreatedAt, item.UpdatedAt, item.UpdatedBy = now, now, actor
		id := vault.RandomID("vi_")
		envelope, err := vault.SealItem(view.keys, view.currentKey(), view.member.VaultID, id, item)
		if err != nil {
			return err
		}
		result = VaultItem{ID: id, Item: item}
		return putVaultRecord(view.data, identity, vault.KindItem, id, envelope, false)
	})
	return result, err
}

// UpdateVaultItem applies an edit to the selected version. The write supersedes
// concurrent siblings, which resolves an item conflict.
func (s *Store) UpdateVaultItem(ref string, edit func(*vault.Item) error, actor string) (VaultItem, error) {
	var result VaultItem
	err := s.mutateVault(func(identity PeerIdentity, view vaultView) error {
		if err := view.unlocked(); err != nil {
			return err
		}
		items, err := vaultItems(view)
		if err != nil {
			return err
		}
		current, err := resolveVaultItem(items, ref)
		if err != nil {
			return err
		}
		item := current.Item
		if err = edit(&item); err != nil {
			return err
		}
		if err = uniqueVaultName(items, item.Name, current.ID); err != nil {
			return err
		}
		item.UpdatedAt, item.UpdatedBy = vaultNow(), actor
		envelope, err := vault.SealItem(view.keys, view.currentKey(), view.member.VaultID, current.ID, item)
		if err != nil {
			return err
		}
		result = VaultItem{ID: current.ID, Item: item}
		return putVaultRecord(view.data, identity, vault.KindItem, current.ID, envelope, false)
	})
	return result, err
}

func (s *Store) DeleteVaultItem(ref string) (VaultItem, error) {
	var result VaultItem
	err := s.mutateVault(func(identity PeerIdentity, view vaultView) error {
		if err := view.unlocked(); err != nil {
			return err
		}
		items, err := vaultItems(view)
		if err != nil {
			return err
		}
		if result, err = resolveVaultItem(items, ref); err != nil {
			return err
		}
		return putVaultRecord(view.data, identity, vault.KindItem, result.ID, nil, true)
	})
	return result, err
}

const maxVaultAuditBytes = 4 << 20

// AppendVaultAudit records one access decision on this machine. The audit log
// is local, bounded to two generations and never contains secret values.
func (s *Store) AppendVaultAudit(entry VaultAuditEntry) error {
	if entry.Time == "" {
		entry.Time = time.Now().UTC().Format(time.RFC3339Nano)
	}
	raw, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	if err = os.MkdirAll(s.vaultDir(), 0o700); err != nil {
		return err
	}
	path := s.vaultAuditPath()
	if info, statErr := os.Stat(path); statErr == nil && info.Size()+int64(len(raw)) > maxVaultAuditBytes {
		if err = os.Rename(path, path+".1"); err != nil {
			return err
		}
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	if _, err = file.Write(append(raw, '\n')); err != nil {
		file.Close()
		return err
	}
	if err = file.Sync(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

// VaultAudit returns the newest matching entries first.
func (s *Store) VaultAudit(limit int, itemID, cardID string) ([]VaultAuditEntry, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	var entries []VaultAuditEntry
	for _, path := range []string{s.vaultAuditPath() + ".1", s.vaultAuditPath()} {
		raw, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		scanner := bufio.NewScanner(bytes.NewReader(raw))
		scanner.Buffer(make([]byte, 64<<10), 1<<20)
		for scanner.Scan() {
			var entry VaultAuditEntry
			if json.Unmarshal(scanner.Bytes(), &entry) != nil {
				continue
			}
			if itemID != "" && entry.ItemID != itemID || cardID != "" && entry.CardID != cardID {
				continue
			}
			entries = append(entries, entry)
		}
	}
	for left, right := 0, len(entries)-1; left < right; left, right = left+1, right-1 {
		entries[left], entries[right] = entries[right], entries[left]
	}
	if len(entries) > limit {
		entries = entries[:limit]
	}
	return entries, nil
}
