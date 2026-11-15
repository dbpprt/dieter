package gateway

import (
	"context"
	"crypto/ecdh"
	"encoding/hex"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const maxPushDevices = 16

func (h *Hub) pushDestinations(account int64, lane relay.Lane) []*gatewayv1.PushDestination {
	if h.push == nil || lane != relay.Control {
		return nil
	}
	return h.push.destinations(account)
}

func (h *Hub) refreshPushDestinations(account int64) {
	if h.push == nil {
		return
	}
	daemons, err := h.store.ListDaemons(account)
	if err != nil {
		return
	}
	targets := h.push.destinations(account)
	for _, daemon := range daemons {
		h.mu.RLock()
		link := h.links[daemon.ID]
		h.mu.RUnlock()
		if link != nil {
			_ = link.sendControlFrame(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: daemon.ID, PushDestinations: targets})
		}
	}
}

// Push routes belong to native sessions, so revocation and expiry remove them.
// Neither project metadata nor plaintext notification destinations are stored.
func (s *Service) SetPushDevice(ctx context.Context, request *gatewayv1.SetPushDeviceRequest) (*gatewayv1.SetPushDeviceResponse, error) {
	principal, ok := PrincipalFromContext(ctx)
	if !ok || principal.SessionHash == "" {
		return nil, status.Error(codes.Unauthenticated, "native session required")
	}
	if request.GetToken() != "" {
		if len(request.GetDeviceId()) < 4 || len(request.GetDeviceId()) > 128 || len(request.GetSignature()) < 32 || len(request.GetSignature()) > 256 {
			return nil, status.Error(codes.InvalidArgument, "invalid push device binding")
		}
		if !validPushToken(request.GetProvider(), request.GetToken(), request.GetSandbox()) {
			return nil, status.Error(codes.InvalidArgument, "invalid push provider or device token")
		}
		key, err := ecdh.X25519().NewPublicKey(request.GetPublicKey())
		if err != nil {
			return nil, status.Error(codes.InvalidArgument, "invalid push public key")
		}
		// Reject low-order public keys as well as malformed encodings.
		probe, _ := ecdh.X25519().NewPrivateKey(make([]byte, 32))
		if _, err = probe.ECDH(key); err != nil {
			return nil, status.Error(codes.InvalidArgument, "invalid push public key")
		}
		trusted, _, _, err := s.rosterSnapshot(principal.GitHubID)
		if err != nil {
			return nil, err
		}
		binding := &gatewayv1.PushDestination{DeviceId: request.GetDeviceId(), PublicKey: request.GetPublicKey(), Signature: request.GetSignature()}
		if trusted == nil || trusted.Account() != roster.Account(s.config.IdentityOrigin(), principal.GitHubID) || !roster.VerifyPushKey(trusted, binding) {
			return nil, status.Error(codes.PermissionDenied, "push key requires a trusted device signature")
		}
	}
	token := request.GetToken()
	if request.GetProvider() == gatewayv1.PushProvider_APNS {
		token = strings.ToLower(token)
	}
	available := s.hub.push != nil && s.hub.push.available(request.GetProvider())
	owners := map[int64]bool{principal.GitHubID: true}
	err := s.store.UpdateAuthState(func(state *AuthState) error {
		devices := 0
		found := false
		for _, item := range state.Sessions {
			if item.GitHubID == principal.GitHubID && item.PushToken != "" && (item.PushToken != token || item.PushProvider != int32(request.GetProvider())) && item.ExpiresAt.After(time.Now()) && item.TokenHash != principal.SessionHash {
				devices++
			}
		}
		if token != "" && devices >= maxPushDevices {
			return status.Error(codes.ResourceExhausted, "too many push devices")
		}
		for i := range state.Sessions {
			item := &state.Sessions[i]
			// A provider route has one active account/session, including a later sign-in.
			if item.PushToken == token && item.PushProvider == int32(request.GetProvider()) && item.TokenHash != principal.SessionHash {
				if item.PushToken != "" {
					owners[item.GitHubID] = true
				}
				item.PushToken = ""
				item.PushPublicKey = nil
			}
			if item.TokenHash == principal.SessionHash && item.GitHubID == principal.GitHubID && item.ExpiresAt.After(time.Now()) {
				found = true
				item.PushToken = token
				item.PushProvider = int32(request.GetProvider())
				item.PushPublicKey = nil
				item.PushSandbox = false
				item.PushDeviceID = ""
				item.PushSignature = nil
				if token != "" {
					item.PushPublicKey = append([]byte(nil), request.GetPublicKey()...)
					item.PushSandbox = request.GetSandbox()
					item.PushDeviceID = request.GetDeviceId()
					item.PushSignature = append([]byte(nil), request.GetSignature()...)
				}
			}
		}
		if !found {
			return status.Error(codes.Unauthenticated, "native session expired")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	for owner := range owners {
		s.hub.refreshPushDestinations(owner)
	}
	return &gatewayv1.SetPushDeviceResponse{Available: available && token != ""}, nil
}

func (s *Store) pushSessions(account int64) ([]Session, error) {
	state, err := s.AuthState()
	if err != nil {
		return nil, err
	}
	entries, err := s.DeviceRoster(account)
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, nil
	}
	trusted, err := roster.Verify(entries)
	if err != nil {
		return nil, err
	}
	var result []Session
	for _, item := range state.Sessions {
		if item.GitHubID == account && item.ExpiresAt.After(time.Now()) && item.PushToken != "" && len(item.PushPublicKey) == 32 && roster.VerifyPushKey(trusted, &gatewayv1.PushDestination{DeviceId: item.PushDeviceID, PublicKey: item.PushPublicKey, Signature: item.PushSignature}) {
			result = append(result, item)
			if len(result) >= maxPushDevices {
				break
			}
		}
	}
	return result, nil
}

type pushSender interface {
	Send(context.Context, Session, int, []byte) (bool, error)
}
type pushJob struct {
	account int64
	session string
	sealed  []byte
	badge   int
}
type PushManager struct {
	store  *Store
	sender pushSender
	log    *slog.Logger
	mu     sync.Mutex
	counts map[string]uint32 // Coarse presence, keyed only by authenticated daemon identity.
	queue  chan pushJob
	once   sync.Once
}

func newPushManager(store *Store, sender pushSender, log *slog.Logger) *PushManager {
	return &PushManager{store: store, sender: sender, log: log, counts: map[string]uint32{}, queue: make(chan pushJob, 256)}
}

// Start only from Serve; creating a handler never starts background work.
func (p *PushManager) Start(ctx context.Context) {
	p.once.Do(func() {
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case job := <-p.queue:
					// Re-check revocation/expiry immediately before provider delivery.
					sessions, err := p.store.pushSessions(job.account)
					if err != nil {
						p.log.Warn("push session lookup failed")
						continue
					}
					for _, session := range sessions {
						if session.TokenHash != job.session {
							continue
						}
						sendCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
						invalid, sendErr := p.sender.Send(sendCtx, session, job.badge, job.sealed)
						cancel()
						if sendErr != nil {
							p.log.Warn("push delivery failed")
						}
						if invalid {
							_ = p.store.UpdateAuthState(func(state *AuthState) error {
								for i := range state.Sessions {
									item := &state.Sessions[i]
									if item.TokenHash == session.TokenHash && item.PushToken == session.PushToken && item.PushProvider == session.PushProvider {
										item.PushToken = ""
										item.PushPublicKey = nil
									}
								}
								return nil
							})
						}
					}
				}
			}
		}()
	})
}

func (p *PushManager) destinations(account int64) []*gatewayv1.PushDestination {
	sessions, err := p.store.pushSessions(account)
	if err != nil {
		return nil
	}
	result := make([]*gatewayv1.PushDestination, 0, len(sessions))
	for _, session := range sessions {
		if !p.available(gatewayv1.PushProvider(session.PushProvider)) {
			continue
		}
		result = append(result, &gatewayv1.PushDestination{Id: session.TokenHash, PublicKey: session.PushPublicKey, DeviceId: session.PushDeviceID, Signature: session.PushSignature})
	}
	return result
}

func (p *PushManager) handle(record DaemonRecord, presence *gatewayv1.AttentionPresence) error {
	if presence == nil || presence.GetCount() > 100000 || len(presence.GetAlerts()) > maxPushDevices {
		return errors.New("invalid attention presence")
	}
	sessions, err := p.store.pushSessions(record.GitHubID)
	if err != nil {
		return err
	}
	byID := map[string]Session{}
	for _, session := range sessions {
		byID[session.TokenHash] = session
	}
	for _, alert := range presence.GetAlerts() {
		// Expired routes can be in flight; discard them, never route to another account.
		if len(alert.GetSealed()) < 60 || len(alert.GetSealed()) > 2048 {
			return errors.New("invalid sealed attention")
		}
	}
	daemons, err := p.store.ListDaemons(record.GitHubID)
	if err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, known := p.counts[record.ID]; !known && len(p.counts) >= 4096 {
		return errors.New("attention presence capacity reached")
	}
	changed := p.counts[record.ID] != presence.GetCount()
	p.counts[record.ID] = presence.GetCount()
	badge := 0
	for _, daemon := range daemons {
		if !daemon.Revoked {
			badge += int(p.counts[daemon.ID])
		}
	}
	if badge > 9999 {
		badge = 9999
	}
	alerted := map[string]bool{}
	enqueue := func(job pushJob) error {
		select {
		case p.queue <- job:
			return nil
		default:
			return errors.New("push queue is full")
		}
	}
	for _, alert := range presence.GetAlerts() {
		if _, ok := byID[alert.GetDestinationId()]; !ok {
			continue
		}
		if err := enqueue(pushJob{account: record.GitHubID, session: alert.GetDestinationId(), sealed: append([]byte(nil), alert.GetSealed()...), badge: badge}); err != nil {
			return err
		}
		alerted[alert.GetDestinationId()] = true
	}
	if changed {
		for _, session := range sessions {
			if !alerted[session.TokenHash] {
				if err := enqueue(pushJob{account: record.GitHubID, session: session.TokenHash, badge: badge}); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// APNs tokens are hexadecimal; FCM registration tokens are opaque and case-sensitive.
func validPushToken(provider gatewayv1.PushProvider, token string, sandbox bool) bool {
	switch provider {
	case gatewayv1.PushProvider_APNS:
		if len(token) < 32 || len(token) > 512 {
			return false
		}
		_, err := hex.DecodeString(token)
		return err == nil
	case gatewayv1.PushProvider_FCM:
		if sandbox || len(token) < 32 || len(token) > 4096 {
			return false
		}
		for _, c := range token {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == ':' || c == '_' || c == '-') {
				return false
			}
		}
		return true
	default:
		return false
	}
}

type pushProviders map[gatewayv1.PushProvider]pushSender

func (s pushProviders) Send(ctx context.Context, session Session, badge int, sealed []byte) (bool, error) {
	sender := s[gatewayv1.PushProvider(session.PushProvider)]
	if sender == nil {
		return false, errors.New("push provider unavailable")
	}
	return sender.Send(ctx, session, badge, sealed)
}

func (p *PushManager) available(provider gatewayv1.PushProvider) bool {
	if senders, ok := p.sender.(pushProviders); ok {
		return senders[provider] != nil
	}
	return p.sender != nil
}
