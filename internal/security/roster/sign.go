package roster

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"errors"
	"strings"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/codes"
)

// Signer is a device key that signs roster entries.
type Signer interface {
	Descriptor() *Descriptor
	Sign(message []byte) ([]byte, error)
}

type keySigner struct {
	descriptor *Descriptor
	sign       func([]byte) ([]byte, error)
}

func (s keySigner) Descriptor() *Descriptor             { return s.descriptor }
func (s keySigner) Sign(message []byte) ([]byte, error) { return s.sign(message) }

// Ed25519Signer signs as a daemon or recovery key.
func Ed25519Signer(key ed25519.PrivateKey, descriptor *Descriptor) Signer {
	return keySigner{descriptor: descriptor, sign: func(message []byte) ([]byte, error) { return ed25519.Sign(key, message), nil }}
}

// ECDSASigner signs as an app with a P-256 key (tests and the JVM client).
func ECDSASigner(key crypto.Signer, descriptor *Descriptor) Signer {
	return keySigner{descriptor: descriptor, sign: func(message []byte) ([]byte, error) {
		digest := sha256.Sum256(message)
		return key.Sign(rand.Reader, digest[:], crypto.SHA256)
	}}
}

// Describe returns the descriptor of public, deriving its ID and algorithm.
func Describe(kind gatewayv1.DeviceKind, platform, name, daemonID string, public crypto.PublicKey) (*Descriptor, error) {
	der, err := x509.MarshalPKIXPublicKey(public)
	if err != nil {
		return nil, err
	}
	var algorithm gatewayv1.DeviceKeyAlgorithm
	switch public.(type) {
	case ed25519.PublicKey:
		algorithm = gatewayv1.DeviceKeyAlgorithm_DEVICE_KEY_ALGORITHM_ED25519
	case *ecdsa.PublicKey:
		algorithm = gatewayv1.DeviceKeyAlgorithm_DEVICE_KEY_ALGORITHM_ECDSA_P256_SHA256
	default:
		return nil, errors.New("unsupported device key")
	}
	if len(name) > maxNameBytes {
		name = truncateName(name)
	}
	return &Descriptor{DeviceId: DeviceID(der), Kind: kind, Platform: platform, Name: name, Algorithm: algorithm, PublicKey: der, DaemonId: daemonID}, nil
}

// truncateName shortens a display name to the roster limit on a rune boundary.
func truncateName(name string) string {
	for len(name) > maxNameBytes {
		_, size := lastRune(name)
		name = name[:len(name)-size]
	}
	return name
}

func lastRune(value string) (rune, int) {
	for i := len(value) - 1; i >= 0; i-- {
		if value[i]&0xC0 != 0x80 {
			return rune(value[i]), len(value) - i
		}
	}
	return 0, 1
}

func signed(entry *Entry, signer Signer) (*Entry, error) {
	signature, err := signer.Sign(Canonical(entry))
	if err != nil {
		return nil, err
	}
	entry.Signature = signature
	return entry, nil
}

func now() string { return time.Now().UTC().Format(time.RFC3339) }

// Genesis starts a roster for account with signer's own device.
func Genesis(account string, signer Signer) (*Entry, error) {
	return signed(&Entry{
		Account: account, Sequence: 0, Operation: gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_GENESIS,
		Device: signer.Descriptor(), Signer: signer.Descriptor().GetDeviceId(), CreatedAt: now(),
	}, signer)
}

// Add signs device into the roster after s's head.
func (s *State) Add(device *Descriptor, signer Signer) (*Entry, error) {
	entry, err := signed(&Entry{
		Account: s.account, Sequence: s.Length(), Previous: s.HeadHash(), Operation: gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_ADD,
		Device: device, Signer: signer.Descriptor().GetDeviceId(), CreatedAt: now(),
	}, signer)
	if err != nil {
		return nil, err
	}
	if _, err := s.Extend([]*Entry{entry}); err != nil {
		return nil, err
	}
	return entry, nil
}

// Revoke signs deviceID out of the roster after s's head.
func (s *State) Revoke(deviceID string, signer Signer) (*Entry, error) {
	entry, err := signed(&Entry{
		Account: s.account, Sequence: s.Length(), Previous: s.HeadHash(), Operation: gatewayv1.DeviceRosterOperation_DEVICE_ROSTER_OPERATION_REVOKE,
		Device: &Descriptor{DeviceId: deviceID}, Signer: signer.Descriptor().GetDeviceId(), CreatedAt: now(),
	}, signer)
	if err != nil {
		return nil, err
	}
	if _, err := s.Extend([]*Entry{entry}); err != nil {
		return nil, err
	}
	return entry, nil
}

const (
	recoveryPrefix   = "DRK1"
	recoverySeed     = 32
	recoveryRoot     = 10
	recoveryChecksum = "dieter-roster-recovery-checksum-v1"
)

// NewRecoveryKey returns a printable recovery key for the roster with root
// and its signer. The key is added to the roster at initialization and can
// later sign a replacement machine into that roster when no other device can.
// It commits to the root, so it never signs into a roster the gateway made up
// around the recovery key's public half.
func NewRecoveryKey(root []byte) (string, Signer, error) {
	if len(root) < recoveryRoot {
		return "", nil, errors.New("roster root is invalid")
	}
	seed := make([]byte, recoverySeed)
	if _, err := rand.Read(seed); err != nil {
		return "", nil, err
	}
	signer, err := recoverySigner(seed)
	if err != nil {
		return "", nil, err
	}
	payload := append(append([]byte(nil), seed...), root[:recoveryRoot]...)
	sum := sha256.Sum256(append([]byte(recoveryChecksum), payload...))
	return recoveryPrefix + "-" + codes.Group(codes.Encode(append(payload, sum[:2]...)), 5), signer, nil
}

// ParseRecoveryKey accepts the printed form with any case or spacing. It
// returns the signer and the root prefix the key commits to.
func ParseRecoveryKey(value string) (Signer, []byte, error) {
	normalized := codes.Normalize(strings.TrimSpace(value))
	if !strings.HasPrefix(normalized, recoveryPrefix) {
		return nil, nil, errors.New("recovery key must start with " + recoveryPrefix)
	}
	raw, err := codes.Decode(strings.TrimPrefix(normalized, recoveryPrefix))
	if err != nil || len(raw) != recoverySeed+recoveryRoot+2 {
		return nil, nil, errors.New("recovery key is malformed")
	}
	payload := raw[:recoverySeed+recoveryRoot]
	sum := sha256.Sum256(append([]byte(recoveryChecksum), payload...))
	if subtle.ConstantTimeCompare(sum[:2], raw[len(payload):]) != 1 {
		return nil, nil, errors.New("recovery key checksum does not match; check for typing errors")
	}
	signer, err := recoverySigner(payload[:recoverySeed])
	return signer, payload[recoverySeed:], err
}

// RecoveryCommits reports whether a recovery key's root prefix matches root.
func RecoveryCommits(prefix, root []byte) bool {
	return len(prefix) == recoveryRoot && len(root) >= recoveryRoot && subtle.ConstantTimeCompare(prefix, root[:recoveryRoot]) == 1
}

func recoverySigner(seed []byte) (Signer, error) {
	key := ed25519.NewKeyFromSeed(seed)
	descriptor, err := Describe(gatewayv1.DeviceKind_DEVICE_KIND_RECOVERY, "recovery", "Recovery key", "", key.Public())
	if err != nil {
		return nil, err
	}
	return Ed25519Signer(key, descriptor), nil
}

func groupCode(raw []byte) string { return codes.Group(codes.Encode(raw), 4) }

func decodeCode(value string) ([]byte, error) { return codes.Decode(value) }
