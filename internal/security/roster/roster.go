// Package roster verifies an account's device roster: the append-only,
// hash-chained list of device keys that decides which machines and apps may
// talk to each other. Every entry after the self-signed genesis is signed by a
// device that is a member at the previous entry, so a relay that stores and
// serves the roster (the gateway) can withhold entries but cannot add a
// device, forge a revocation, or rewrite history a device has pinned.
//
// The canonical encoding, hashes, device IDs and pairing codes are shared
// with the Kotlin core; tests/fixtures/roster holds the golden vectors.
package roster

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/codes"
)

const (
	// MaxEntries bounds a roster's history.
	MaxEntries = 4096
	// MaxActive bounds the devices that are members at once.
	MaxActive = 64
	// MaxEntryBytes bounds one entry's canonical bytes plus its signature.
	MaxEntryBytes = 1024
	maxNameBytes  = 64
	maxShortField = 128

	signingDomain    = "dieter-roster-v1"
	descriptorDomain = "dieter-device-v1"
	devicePrefix     = "dv_"
)

type (
	Entry      = gatewayv1.DeviceRosterEntry
	Descriptor = gatewayv1.DeviceDescriptor
)

var (
	// ErrConflict reports a roster that does not extend the pinned one: a
	// different entry at a sequence number the device has already seen.
	ErrConflict = errors.New("device roster conflicts with the pinned roster")
	// ErrInvalid reports an entry that is malformed or not authorized.
	ErrInvalid = errors.New("device roster entry is invalid")
)

// Account binds a roster to one gateway account. A roster from another
// gateway or account never verifies here.
func Account(issuer string, githubID int64) string {
	return strings.TrimRight(issuer, "/") + "|github:" + strconv.FormatInt(githubID, 10)
}

// DeviceID derives a device's ID from its DER SubjectPublicKeyInfo, so an ID
// can never be rebound to another key.
func DeviceID(publicKey []byte) string {
	sum := sha256.Sum256(publicKey)
	return devicePrefix + strings.ToLower(codes.Encode(sum[:16]))
}

// Canonical returns the bytes an entry's signature covers and its hash
// commits to: a domain label, then every field as a length-prefixed string.
// The signature itself is excluded.
func Canonical(entry *Entry) []byte {
	device := entry.GetDevice()
	var out bytes.Buffer
	out.WriteString(signingDomain)
	writeFields(&out,
		[]byte(entry.GetAccount()),
		[]byte(strconv.FormatUint(entry.GetSequence(), 10)),
		entry.GetPrevious(),
		[]byte(strconv.FormatInt(int64(entry.GetOperation()), 10)),
		[]byte(device.GetDeviceId()),
		[]byte(strconv.FormatInt(int64(device.GetKind()), 10)),
		[]byte(device.GetPlatform()),
		[]byte(device.GetName()),
		[]byte(strconv.FormatInt(int64(device.GetAlgorithm()), 10)),
		device.GetPublicKey(),
		[]byte(device.GetDaemonId()),
		[]byte(entry.GetSigner()),
		[]byte(entry.GetCreatedAt()),
	)
	return out.Bytes()
}

func writeFields(out *bytes.Buffer, fields ...[]byte) {
	for _, field := range fields {
		var length [4]byte
		binary.BigEndian.PutUint32(length[:], uint32(len(field)))
		out.Write(length[:])
		out.Write(field)
	}
}

// Hash is the SHA-256 of an entry's canonical bytes. The next entry's
// previous field and the pinned head commit to it.
func Hash(entry *Entry) []byte {
	sum := sha256.Sum256(Canonical(entry))
	return sum[:]
}

// EncodeHash is the printable form of a roster hash.
func EncodeHash(hash []byte) string { return base64.RawURLEncoding.EncodeToString(hash) }

// DescriptorBytes is the canonical encoding of a device descriptor, which
// a pairing proof covers.
func DescriptorBytes(device *Descriptor) []byte {
	var out bytes.Buffer
	out.WriteString(descriptorDomain)
	writeFields(&out,
		[]byte(device.GetDeviceId()),
		[]byte(strconv.FormatInt(int64(device.GetKind()), 10)),
		[]byte(device.GetPlatform()),
		[]byte(device.GetName()),
		[]byte(strconv.FormatInt(int64(device.GetAlgorithm()), 10)),
		device.GetPublicKey(),
		[]byte(device.GetDaemonId()),
	)
	return out.Bytes()
}

// ValidateDescriptor checks a device that asks to join.
func ValidateDescriptor(device *Descriptor) error {
	if device == nil {
		return errors.New("device is missing")
	}
	if device.GetKind() == gatewayv1.DeviceKind_DEVICE_KIND_RECOVERY {
		return errors.New("a recovery key cannot ask to join")
	}
	_, err := newMember(device)
	return err
}

// Member is a device's verified roster record.
type Member struct {
	Descriptor *Descriptor
	AddedBy    string
	AddedAt    uint64
	Revoked    bool
	RevokedAt  uint64
	public     any
}

// Active reports a member that may connect and sign.
func (m *Member) Active() bool { return m != nil && !m.Revoked }

// Connects reports a member that may authenticate a connection: an active
// daemon or client, never a recovery key.
func (m *Member) Connects() bool {
	return m.Active() && m.Descriptor.GetKind() != gatewayv1.DeviceKind_DEVICE_KIND_RECOVERY
}

// PublicKey returns the member's parsed key.
func (m *Member) PublicKey() any { return m.public }

// State is a verified roster. It is immutable; Extend returns a new state.
type State struct {
	account string
	entries []*Entry
	hashes  [][]byte
	members map[string]*Member
	order   []string
}

// Verify checks a complete roster from its genesis entry.
func Verify(entries []*Entry) (*State, error) {
	if len(entries) == 0 {
		return nil, fmt.Errorf("%w: a roster starts with its genesis entry", ErrInvalid)
	}
	return (&State{members: map[string]*Member{}}).Extend(entries)
}

// Extend verifies entries that continue s. Entries s already holds are
// accepted when they are identical, so a device can offer its whole roster to
// a peer. A different entry at a sequence s holds is ErrConflict only when it
// is a valid, signed continuation of the history before it: a fork that a
// member signed. Anything else is ErrInvalid, so malformed data from a relay
// never counts as equivocation.
func (s *State) Extend(entries []*Entry) (*State, error) {
	next := s.clone()
	for _, entry := range entries {
		if entry == nil {
			return nil, fmt.Errorf("%w: missing entry", ErrInvalid)
		}
		if sequence := entry.GetSequence(); sequence < uint64(len(next.entries)) {
			if !bytes.Equal(Hash(entry), next.hashes[sequence]) {
				if err := next.prefix(sequence).append(entry); err != nil {
					return nil, err
				}
				return nil, fmt.Errorf("%w at sequence %d", ErrConflict, sequence)
			}
			continue
		}
		if err := next.append(entry); err != nil {
			return nil, err
		}
	}
	return next, nil
}

// prefix is the verified state before entry sequence. Entries were verified
// when s was built, so replaying them cannot fail.
func (s *State) prefix(sequence uint64) *State {
	state := &State{members: map[string]*Member{}}
	for _, entry := range s.entries[:sequence] {
		_ = state.append(entry)
	}
	return state
}

func (s *State) clone() *State {
	next := &State{account: s.account, entries: append([]*Entry(nil), s.entries...), hashes: append([][]byte(nil), s.hashes...), members: make(map[string]*Member, len(s.members)), order: append([]string(nil), s.order...)}
	for id, member := range s.members {
		copied := *member
		next.members[id] = &copied
	}
	return next
}

func (s *State) append(entry *Entry) error {
	sequence := uint64(len(s.entries))
	invalid := func(reason string) error {
		return fmt.Errorf("%w at sequence %d: %s", ErrInvalid, sequence, reason)
	}
	if sequence >= MaxEntries {
		return invalid("the roster is full")
	}
	if entry.GetSequence() != sequence {
		return invalid("sequence does not follow the head")
	}
	if len(Canonical(entry))+len(entry.GetSignature()) > MaxEntryBytes {
		return invalid("entry is too large")
	}
	if len(entry.GetCreatedAt()) > maxShortField {
		return invalid("created_at is too long")
	}
	device := entry.GetDevice()
	if device == nil || device.GetDeviceId() == "" {
		return invalid("device is missing")
	}
	operation := entry.GetOperation()
	if sequence == 0 {
		if operation != gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_GENESIS || len(entry.GetPrevious()) != 0 {
			return invalid("the first entry must be a genesis entry")
		}
		if account := entry.GetAccount(); account == "" || len(account) > 256 || !utf8.ValidString(account) {
			return invalid("account is invalid")
		}
		s.account = entry.GetAccount()
	} else {
		if entry.GetAccount() != s.account {
			return invalid("entry belongs to another account")
		}
		if !bytes.Equal(entry.GetPrevious(), s.hashes[sequence-1]) {
			return invalid("previous hash does not match the head")
		}
	}
	var signer *Member
	switch operation {
	case gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_GENESIS:
		if sequence != 0 {
			return invalid("genesis must be the first entry")
		}
		member, err := newMember(device)
		if err != nil {
			return invalid(err.Error())
		}
		if device.GetKind() == gatewayv1.DeviceKind_DEVICE_KIND_RECOVERY {
			return invalid("a recovery key cannot start a roster")
		}
		if entry.GetSigner() != device.GetDeviceId() {
			return invalid("genesis must be signed by its own device")
		}
		signer = member
		if err := verifySignature(signer, entry); err != nil {
			return invalid(err.Error())
		}
		member.AddedAt = 0
		s.members[device.GetDeviceId()] = member
		s.order = append(s.order, device.GetDeviceId())
	case gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_ADD:
		signer = s.members[entry.GetSigner()]
		if !signer.Active() {
			return invalid("signer is not an active member")
		}
		if err := verifySignature(signer, entry); err != nil {
			return invalid(err.Error())
		}
		if _, exists := s.members[device.GetDeviceId()]; exists {
			return invalid("device was already added")
		}
		member, err := newMember(device)
		if err != nil {
			return invalid(err.Error())
		}
		if s.activeCount() >= MaxActive {
			return invalid("the roster has too many active devices")
		}
		if device.GetKind() == gatewayv1.DeviceKind_DEVICE_KIND_DAEMON {
			if existing := s.Daemon(device.GetDaemonId()); existing != nil {
				return invalid("another active device is this machine")
			}
		}
		member.AddedBy, member.AddedAt = signer.Descriptor.GetDeviceId(), sequence
		s.members[device.GetDeviceId()] = member
		s.order = append(s.order, device.GetDeviceId())
	case gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_REVOKE:
		signer = s.members[entry.GetSigner()]
		if !signer.Active() {
			return invalid("signer is not an active member")
		}
		if err := verifySignature(signer, entry); err != nil {
			return invalid(err.Error())
		}
		if device.GetKind() != gatewayv1.DeviceKind_DEVICE_KIND_UNSPECIFIED || device.GetPlatform() != "" || device.GetName() != "" ||
			device.GetAlgorithm() != gatewayv1.DeviceKeyAlgorithm_DEVICE_KEY_ALGORITHM_UNSPECIFIED || len(device.GetPublicKey()) != 0 || device.GetDaemonId() != "" {
			return invalid("a revocation names only the device ID")
		}
		target := s.members[device.GetDeviceId()]
		if !target.Active() {
			return invalid("revoked device is not an active member")
		}
		if target.Connects() && s.connectingCount() == 1 {
			return invalid("the last device that can connect cannot be revoked")
		}
		target.Revoked, target.RevokedAt = true, sequence
	default:
		return invalid("operation is unknown")
	}
	s.entries = append(s.entries, entry)
	s.hashes = append(s.hashes, Hash(entry))
	return nil
}

func newMember(device *Descriptor) (*Member, error) {
	name, platform := device.GetName(), device.GetPlatform()
	if len(name) == 0 || len(name) > maxNameBytes || !utf8.ValidString(name) || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return nil, errors.New("device name is invalid")
	}
	if len(platform) == 0 || len(platform) > 16 || strings.IndexFunc(platform, func(r rune) bool { return (r < 'a' || r > 'z') && (r < '0' || r > '9') }) >= 0 {
		return nil, errors.New("device platform is invalid")
	}
	if len(device.GetDaemonId()) > maxShortField {
		return nil, errors.New("daemon ID is too long")
	}
	if DeviceID(device.GetPublicKey()) != device.GetDeviceId() {
		return nil, errors.New("device ID does not match its key")
	}
	public, err := ParsePublicKey(device.GetAlgorithm(), device.GetPublicKey())
	if err != nil {
		return nil, err
	}
	switch device.GetKind() {
	case gatewayv1.DeviceKind_DEVICE_KIND_DAEMON:
		if device.GetDaemonId() == "" || device.GetAlgorithm() != gatewayv1.DeviceKeyAlgorithm_DEVICE_KEY_ALGORITHM_ED25519 {
			return nil, errors.New("a machine needs its daemon ID and an Ed25519 key")
		}
	case gatewayv1.DeviceKind_DEVICE_KIND_CLIENT:
		if device.GetDaemonId() != "" {
			return nil, errors.New("an app has no daemon ID")
		}
	case gatewayv1.DeviceKind_DEVICE_KIND_RECOVERY:
		if device.GetDaemonId() != "" || device.GetAlgorithm() != gatewayv1.DeviceKeyAlgorithm_DEVICE_KEY_ALGORITHM_ED25519 {
			return nil, errors.New("a recovery key is an Ed25519 key without a daemon ID")
		}
	default:
		return nil, errors.New("device kind is unknown")
	}
	return &Member{Descriptor: device, public: public}, nil
}

// ParsePublicKey parses a DER SubjectPublicKeyInfo of algorithm.
func ParsePublicKey(algorithm gatewayv1.DeviceKeyAlgorithm, der []byte) (any, error) {
	if len(der) == 0 || len(der) > maxShortField {
		return nil, errors.New("device key is invalid")
	}
	value, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, errors.New("device key is invalid")
	}
	switch algorithm {
	case gatewayv1.DeviceKeyAlgorithm_DEVICE_KEY_ALGORITHM_ED25519:
		if key, ok := value.(ed25519.PublicKey); ok {
			return key, nil
		}
	case gatewayv1.DeviceKeyAlgorithm_DEVICE_KEY_ALGORITHM_ECDSA_P256_SHA256:
		if key, ok := value.(*ecdsa.PublicKey); ok && key.Curve == elliptic.P256() {
			return key, nil
		}
	}
	return nil, errors.New("device key does not match its algorithm")
}

func verifySignature(signer *Member, entry *Entry) error {
	if !Verifies(signer.public, Canonical(entry), entry.GetSignature()) {
		return errors.New("signature is invalid")
	}
	return nil
}

// Verifies checks a device signature over message: Ed25519 directly, ECDSA
// P-256 as a DER signature over SHA-256(message).
func Verifies(public any, message, signature []byte) bool {
	switch key := public.(type) {
	case ed25519.PublicKey:
		return len(signature) == ed25519.SignatureSize && ed25519.Verify(key, message, signature)
	case *ecdsa.PublicKey:
		digest := sha256.Sum256(message)
		return ecdsa.VerifyASN1(key, digest[:], signature)
	}
	return false
}

func (s *State) activeCount() int {
	count := 0
	for _, member := range s.members {
		if member.Active() {
			count++
		}
	}
	return count
}

func (s *State) connectingCount() int {
	count := 0
	for _, member := range s.members {
		if member.Connects() {
			count++
		}
	}
	return count
}

// Account is the account the roster belongs to.
func (s *State) Account() string { return s.account }

// Length is the number of entries.
func (s *State) Length() uint64 { return uint64(len(s.entries)) }

// Root is the genesis entry's hash: what a paired device pins.
func (s *State) Root() []byte { return append([]byte(nil), s.hashes[0]...) }

// HeadSequence and HeadHash identify the newest entry.
func (s *State) HeadSequence() uint64 { return uint64(len(s.entries) - 1) }
func (s *State) HeadHash() []byte     { return append([]byte(nil), s.hashes[len(s.hashes)-1]...) }

// HashAt returns the hash of entry sequence, or nil past the head.
func (s *State) HashAt(sequence uint64) []byte {
	if sequence >= uint64(len(s.hashes)) {
		return nil
	}
	return append([]byte(nil), s.hashes[sequence]...)
}

// Entries returns the entries from sequence on.
func (s *State) Entries(from uint64) []*Entry {
	if from >= uint64(len(s.entries)) {
		return nil
	}
	return append([]*Entry(nil), s.entries[from:]...)
}

// Member returns a device ever added to the roster, revoked or not.
func (s *State) Member(deviceID string) *Member { return s.members[deviceID] }

// Daemon returns the active daemon device of a gateway daemon ID.
func (s *State) Daemon(daemonID string) *Member {
	if daemonID == "" {
		return nil
	}
	for _, id := range s.order {
		member := s.members[id]
		if member.Active() && member.Descriptor.GetKind() == gatewayv1.DeviceKind_DEVICE_KIND_DAEMON && member.Descriptor.GetDaemonId() == daemonID {
			return member
		}
	}
	return nil
}

// Members returns every device in the order it was added.
func (s *State) Members() []*Member {
	result := make([]*Member, 0, len(s.order))
	for _, id := range s.order {
		result = append(result, s.members[id])
	}
	return result
}

// Proto returns the roster as served by the gateway from sequence on.
func (s *State) Proto(from uint64) *gatewayv1.DeviceRoster {
	return &gatewayv1.DeviceRoster{Entries: s.Entries(from), HeadSequence: s.HeadSequence(), HeadHash: s.HeadHash(), Length: s.Length()}
}
