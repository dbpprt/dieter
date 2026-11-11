package link

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

// Mirrors the shared Inbox's classification: questions and unread replies, with
// active turns suppressed. A Review placement alone is not an unread reply.
func attentionFingerprint(card model.Card) string {
	if card.Archived {
		return ""
	}
	switch strings.ToLower(strings.TrimSpace(card.Runtime)) {
	case "waiting", "waiting_for_user", "needs_input":
		return fmt.Sprintf("question:%s:%d", card.RuntimeUpdatedAt, card.ResponseSeq)
	case "starting", "running", "working", "streaming", "active", "cancelling":
		return ""
	}
	if card.ResponseSeq > card.SeenResponseSeq {
		return fmt.Sprintf("reply:%d", card.ResponseSeq)
	}
	return ""
}

// Baselines survive transport reconnects; reconnecting can deliver a transition
// that happened while the tunnel was down, without replaying the first snapshot.
type attentionTracker struct {
	mu       sync.Mutex
	previous map[string]string
}

func (t *attentionTracker) update(cards []model.Card, owner string) (uint32, []string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	next := map[string]string{}
	var changed []string
	for _, card := range cards {
		if card.OwnerDaemonID != owner {
			continue
		}
		fingerprint := attentionFingerprint(card)
		if fingerprint == "" {
			continue
		}
		next[card.ID] = fingerprint
		if t.previous != nil && t.previous[card.ID] != fingerprint {
			changed = append(changed, card.ID)
		}
	}
	t.previous = next
	return uint32(len(next)), changed
}

func sealAttention(publicKey []byte, cardID string) ([]byte, error) {
	recipient, err := ecdh.X25519().NewPublicKey(publicKey)
	if err != nil {
		return nil, err
	}
	ephemeral, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	shared, err := ephemeral.ECDH(recipient)
	if err != nil {
		return nil, err
	}
	key, err := hkdf.Key(sha256.New, shared, nil, "dieter-attention-v1", 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return nil, err
	}
	plain, _ := json.Marshal(map[string]string{"cardId": cardID})
	result := append(ephemeral.PublicKey().Bytes(), nonce...)
	return aead.Seal(result, nonce, plain, []byte("dieter-attention-v1")), nil
}

func validPushDestination(state *roster.State, destination *gatewayv1.PushDestination) bool {
	return roster.VerifyPushKey(state, destination)
}

func (c *GatewayClient) runAttention(ctx context.Context, destinations <-chan []*gatewayv1.PushDestination, send func(*gatewayv1.DaemonLinkFrame) bool) {
	if c.Store == nil {
		return
	}
	changes, unsubscribe := c.Store.SubscribeChanges()
	defer unsubscribe()
	recovery := time.NewTicker(2 * time.Second)
	defer recovery.Stop()
	var targets []*gatewayv1.PushDestination
	var lastCount uint32
	first := true
	publish := func(force bool) {
		if len(targets) == 0 {
			return
		}
		cards, err := c.Store.Kanban.ListCards(kanban.CardFilter{})
		if err != nil {
			c.Log.Warn("attention snapshot unavailable")
			return
		}
		count, changed := c.attention.update(cards, c.Identity.ID)
		if first || force || count != lastCount {
			if !send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_ATTENTION, DaemonId: c.Identity.ID, Attention: &gatewayv1.AttentionPresence{Count: count}}) {
				return
			}
			first = false
			lastCount = count
		}
		trusted, trustErr := PinnedRoster(c.Identity.Root)
		if trustErr != nil {
			return
		}
		for _, cardID := range changed {
			presence := &gatewayv1.AttentionPresence{Count: count}
			for _, destination := range targets {
				if !validPushDestination(trusted, destination) {
					continue
				}
				sealed, sealErr := sealAttention(destination.GetPublicKey(), cardID)
				if sealErr != nil {
					continue
				}
				presence.Alerts = append(presence.Alerts, &gatewayv1.SealedAttention{DestinationId: destination.GetId(), Sealed: sealed})
			}
			if !send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_ATTENTION, DaemonId: c.Identity.ID, Attention: presence}) {
				return
			}
		}
	}
	for {
		select {
		case <-ctx.Done():
			return
		case next := <-destinations:
			if len(next) > 16 {
				next = next[:16]
			}
			targets = next
			publish(true)
		case <-changes:
			publish(false)
		case <-recovery.C:
			publish(false)
		}
	}
}
