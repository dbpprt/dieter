package replica

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store/home"
)

// EnsureIdentity returns the peer identity, initializing an unenrolled local
// replica and its database under the central mutation lock.
func (s *Store) EnsureIdentity() (PeerIdentity, error) {
	if identity, err := s.PeerIdentity(); err == nil {
		return identity, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return identity, err
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return PeerIdentity{}, err
	}
	defer release()
	identity, err := s.WriterIdentity()
	if err != nil {
		return identity, err
	}
	_, err = s.peerDatabase(identity.Account)
	return identity, err
}

// WriterIdentity is the identity a writer publishes as. Call it under the
// central writer lock; on first creation it records a local identity.
// Unenrolled installations are local replicas. First enrollment adopts these
// records into the authenticated account; later account changes never copy them.
func (s *Store) WriterIdentity() (PeerIdentity, error) {
	identity, err := s.PeerIdentity()
	if err == nil {
		return identity, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return identity, err
	}
	identity = PeerIdentity{Account: "local", DaemonID: home.NewID("local_"), Actor: home.NewID("actor_")}
	return identity, home.WriteJSON(filepath.Join(s.home.Root, "peers", "identity.json"), identity)
}

// Snapshot returns the identity and a pinned snapshot of its replica; an
// unenrolled store returns an empty in-memory state. Close the data.
func (s *Store) Snapshot() (PeerIdentity, PeerData, error) {
	if err := s.home.CheckStorageSchema(); err != nil {
		return PeerIdentity{}, PeerData{}, err
	}
	identity, err := s.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		return identity, PeerData{State: crdt.State{Records: map[string]crdt.Record{}}}, nil
	}
	if err != nil {
		return identity, PeerData{}, err
	}
	data, err := s.OpenPeerSnapshot(identity.Account)
	return identity, data, err
}
