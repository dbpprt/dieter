package engine

import (
	"context"
	"log/slog"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
)

// Agent channels are account-wide: each daemon publishes the messages posted
// on it, the receipts of the cards it owns, its pin changes and its live
// claims as replicated KV records (schema.Channel*Namespace), and ingests the
// other daemons' records into its own log. Delivery (steer, digest, wake)
// stays with the owner daemon of each recipient card.

const (
	// channelSyncInterval bounds how late a change is published or ingested
	// when no store change wakes the loop.
	channelSyncInterval = 5 * time.Second
	// channelSyncCoalesce gathers bursts of store changes into one pass.
	channelSyncCoalesce = 300 * time.Millisecond
	// channelClaimsRefresh republishes unchanged live claims; other daemons
	// ignore claims older than channelClaimsStale.
	channelClaimsRefresh = 5 * time.Minute
	channelClaimsStale   = 15 * time.Minute
	// channelDigestWindow bounds which channel posts (not direct messages) a
	// starting turn's digest includes.
	channelDigestWindow = 24 * time.Hour
)

// channelReplication is the replication state of the channel hub.
type channelReplication struct {
	// seen is the record revision last ingested per namespace/key.
	seen map[string]string
	// receipts are cards whose receipt record is due.
	receipts map[string]string
	// pins are projects whose pins record is due.
	pins map[string]bool
	// claims is the last published claims fingerprint and time per project.
	claims map[string]publishedClaims
}

type publishedClaims struct {
	fingerprint string
	at          time.Time
}

func (r *channelReplication) init() {
	if r.seen == nil {
		r.seen, r.receipts, r.pins, r.claims = map[string]string{}, map[string]string{}, map[string]bool{}, map[string]publishedClaims{}
	}
}

// channelOrigin is the daemon ID channel records name as their writer; empty
// before this daemon has an identity (its first post creates one).
func (s *Service) channelOrigin() string {
	origin, err := s.Store.KV.KnownChannelDaemon()
	if err != nil {
		slog.Warn("agent channel origin unavailable", "error", err)
		return ""
	}
	return origin
}

// ownsCard reports whether this daemon runs card's conversation.
func (s *Service) ownsCard(card model.Card) bool {
	return card.OwnerDaemonID == "" || card.OwnerDaemonID == s.channelOrigin()
}

// publishChannelMessage writes a message posted on this daemon into its
// origin ring. Dieter's coordination events have no origin and stay local.
func (s *Service) publishChannelMessage(message model.ChannelMessage) {
	if message.Origin == "" {
		return
	}
	record := schema.ChannelRecord{
		ID: message.ID, ProjectID: message.ProjectID, Origin: message.Origin, OriginSeq: message.OriginSeq,
		ThreadID: message.ThreadID, Kind: message.Kind, To: message.To, Here: message.Here, Wake: message.Wake,
		Body: message.Body, Files: message.Files, CreatedAt: message.CreatedAt,
		Author: schema.ChannelAuthor{Kind: message.Author.Kind, CardID: message.Author.CardID, Title: message.Author.Title,
			Harness: message.Author.Harness, Model: message.Author.Model, DeviceID: message.Author.DeviceID},
	}
	key := schema.ChannelKey(message.ProjectID, message.Origin, message.OriginSeq)
	if err := s.Store.KV.PutChannel(schema.ChannelNamespace, key, record); err != nil {
		slog.Warn("agent channel message not replicated", "message", message.ID, "error", err)
	}
}

// deliverChannel records deliveries to a card and schedules its replicated
// receipt.
func (s *Service) deliverChannel(projectID, cardID, mode string, ids []string) error {
	if err := s.Store.Channels.Deliver(projectID, cardID, mode, ids); err != nil {
		return err
	}
	s.channels.mu.Lock()
	s.channels.replication.init()
	s.channels.replication.receipts[cardID] = projectID
	s.channels.mu.Unlock()
	s.Store.NotifyChanges()
	return nil
}

// schedulePins marks a project's pins record as due.
func (s *Service) schedulePins(projectID string) {
	s.channels.mu.Lock()
	s.channels.replication.init()
	s.channels.replication.pins[projectID] = true
	s.channels.mu.Unlock()
	s.Store.NotifyChanges()
}

// RunChannelReplication publishes and ingests agent channel records until ctx
// ends. It runs once per daemon.
func (s *Service) RunChannelReplication(ctx context.Context) {
	changes, unsubscribe := s.Store.SubscribeChanges()
	defer unsubscribe()
	ticker := time.NewTicker(channelSyncInterval)
	defer ticker.Stop()
	for {
		s.SyncChannels()
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-changes:
			timer := time.NewTimer(channelSyncCoalesce)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
		}
	}
}

// SyncChannels runs one replication pass: publish this daemon's due
// receipts, pins and claims, then ingest other daemons' records.
func (s *Service) SyncChannels() {
	origin := s.channelOrigin()
	if origin == "" {
		return
	}
	s.publishDueReceipts(origin)
	s.publishDuePins(origin)
	s.publishClaims(origin)
	s.ingestChannelMessages(origin)
	s.ingestChannelReceipts(origin)
	s.ingestChannelPins(origin)
}

func (s *Service) publishDueReceipts(origin string) {
	s.channels.mu.Lock()
	s.channels.replication.init()
	due := s.channels.replication.receipts
	s.channels.replication.receipts = map[string]string{}
	s.channels.mu.Unlock()
	for cardID, projectID := range due {
		entries, err := s.Store.Channels.CardDeliveries(projectID, cardID, schema.ChannelReceiptEntries)
		if err != nil || len(entries) == 0 {
			continue
		}
		record := schema.ChannelReceiptRecord{ProjectID: projectID, Daemon: origin}
		for _, entry := range entries {
			record.Deliveries = append(record.Deliveries, schema.ChannelDeliveryEntry{Message: entry.MessageID, Mode: entry.Mode, At: entry.At})
		}
		if err := s.Store.KV.PutChannel(schema.ChannelReceiptNamespace, cardID, record); err != nil {
			slog.Warn("agent channel receipt not replicated", "card", cardID, "error", err)
		}
	}
}

func (s *Service) publishDuePins(origin string) {
	s.channels.mu.Lock()
	s.channels.replication.init()
	due := s.channels.replication.pins
	s.channels.replication.pins = map[string]bool{}
	s.channels.mu.Unlock()
	for projectID := range due {
		changes, err := s.Store.Channels.LocalPins(projectID, schema.ChannelPinEntries)
		if err != nil {
			continue
		}
		record := schema.ChannelPinsRecord{Pins: []schema.ChannelPinEntry{}}
		for _, change := range changes {
			record.Pins = append(record.Pins, schema.ChannelPinEntry{Message: change.MessageID, Pinned: change.Pinned, At: change.At})
		}
		if err := s.Store.KV.PutChannel(schema.ChannelPinsNamespace, schema.ChannelScopeKey(projectID, origin), record); err != nil {
			slog.Warn("agent channel pins not replicated", "project", projectID, "error", err)
		}
	}
}

// publishClaims writes each project's live local claims when they changed,
// and refreshes unchanged ones so other daemons keep showing them.
func (s *Service) publishClaims(origin string) {
	byProject := map[string][]schema.ChannelClaimEntry{}
	for _, claim := range s.localChannelClaims("") {
		if len(byProject[claim.ProjectID]) < schema.ChannelClaimEntries {
			byProject[claim.ProjectID] = append(byProject[claim.ProjectID], schema.ChannelClaimEntry{Path: claim.Path, CardID: claim.CardID, CardTitle: channelAttribute(claim.CardTitle), Since: claim.Since})
		}
	}
	s.channels.mu.Lock()
	s.channels.replication.init()
	for projectID := range s.channels.replication.claims {
		if _, ok := byProject[projectID]; !ok {
			byProject[projectID] = nil
		}
	}
	published := s.channels.replication.claims
	s.channels.mu.Unlock()
	now := time.Now()
	for projectID, claims := range byProject {
		sort.Slice(claims, func(i, j int) bool { return claims[i].Path < claims[j].Path })
		fingerprint := ""
		for _, claim := range claims {
			fingerprint += claim.Path + "\x00" + claim.CardID + "\x00"
		}
		last, known := published[projectID]
		if known && last.fingerprint == fingerprint && (len(claims) == 0 || now.Sub(last.at) < channelClaimsRefresh) {
			continue
		}
		record := schema.ChannelClaimsRecord{At: home.Timestamp(), Claims: claims}
		if record.Claims == nil {
			record.Claims = []schema.ChannelClaimEntry{}
		}
		if err := s.Store.KV.PutChannel(schema.ChannelClaimsNamespace, schema.ChannelScopeKey(projectID, origin), record); err != nil {
			slog.Warn("agent channel claims not replicated", "project", projectID, "error", err)
			continue
		}
		s.channels.mu.Lock()
		if len(claims) == 0 {
			delete(s.channels.replication.claims, projectID)
		} else {
			s.channels.replication.claims[projectID] = publishedClaims{fingerprint: fingerprint, at: now}
		}
		s.channels.mu.Unlock()
	}
}

// changedRecord reports whether namespace/key moved past the revision this
// daemon last ingested, and records the new revision.
func (s *Service) changedRecord(namespace, key, revision string) bool {
	s.channels.mu.Lock()
	defer s.channels.mu.Unlock()
	s.channels.replication.init()
	id := namespace + "/" + key
	if s.channels.replication.seen[id] == revision {
		return false
	}
	s.channels.replication.seen[id] = revision
	return true
}

func (s *Service) ingestChannelMessages(origin string) {
	var arrived []model.ChannelMessage
	// A project that has not replicated here yet is retried on later passes.
	projects := map[string]bool{}
	known := func(projectID string) bool {
		if ok, seen := projects[projectID]; seen {
			return ok
		}
		_, err := s.Store.Kanban.ResolveProject(projectID)
		projects[projectID] = err == nil
		return err == nil
	}
	err := s.Store.KV.EachChannel(schema.ChannelNamespace, "", func(key, revision string, value []byte) error {
		parts := schema.SplitChannelKey(key)
		if len(parts) != 3 || parts[1] == origin || !s.changedRecord(schema.ChannelNamespace, key, revision) {
			return nil
		}
		record, err := schema.DecodeChannelRecord(key, value)
		if err != nil {
			slog.Warn("agent channel message ignored", "key", key, "error", err)
			return nil
		}
		message := model.ChannelMessage{
			ID: record.ID, ProjectID: record.ProjectID, ThreadID: record.ThreadID, Kind: record.Kind, To: record.To,
			Here: record.Here, Wake: record.Wake, Body: record.Body, Files: record.Files, Origin: record.Origin,
			OriginSeq: record.OriginSeq, CreatedAt: record.CreatedAt,
			Author: model.ChannelAuthor{Kind: record.Author.Kind, CardID: record.Author.CardID, Title: record.Author.Title,
				Harness: record.Author.Harness, Model: record.Author.Model, DeviceID: record.Author.DeviceID},
		}
		if !known(message.ProjectID) {
			s.forgetRecord(schema.ChannelNamespace, key)
			return nil
		}
		stored, added, err := s.Store.Channels.Ingest(message)
		if err != nil {
			slog.Warn("agent channel message not ingested", "message", message.ID, "error", err)
			s.forgetRecord(schema.ChannelNamespace, key)
			return nil
		}
		if added {
			arrived = append(arrived, stored)
		}
		return nil
	})
	if err != nil {
		slog.Warn("agent channel messages unavailable", "error", err)
	}
	sort.Slice(arrived, func(i, j int) bool { return arrived[i].CreatedAt < arrived[j].CreatedAt })
	for _, message := range arrived {
		s.dispatchChannelMessage(message, message.Wake)
	}
}

func (s *Service) forgetRecord(namespace, key string) {
	s.channels.mu.Lock()
	delete(s.channels.replication.seen, namespace+"/"+key)
	s.channels.mu.Unlock()
}

func (s *Service) ingestChannelReceipts(origin string) {
	err := s.Store.KV.EachChannel(schema.ChannelReceiptNamespace, "", func(key, revision string, value []byte) error {
		if !s.changedRecord(schema.ChannelReceiptNamespace, key, revision) {
			return nil
		}
		record, err := schema.DecodeChannelReceipt(key, value)
		if err != nil || record.Daemon == origin {
			return nil
		}
		entries := make([]model.ChannelDeliveryEntry, 0, len(record.Deliveries))
		missing := false
		for _, delivery := range record.Deliveries {
			entries = append(entries, model.ChannelDeliveryEntry{MessageID: delivery.Message, Mode: delivery.Mode, At: delivery.At})
			missing = missing || !s.Store.Channels.Has(record.ProjectID, delivery.Message)
		}
		// A receipt can arrive before its messages: apply what is here and
		// read it again on the next pass.
		if err := s.Store.Channels.DeliverRemote(record.ProjectID, key, entries); err != nil || missing {
			s.forgetRecord(schema.ChannelReceiptNamespace, key)
		}
		return nil
	})
	if err != nil {
		slog.Warn("agent channel receipts unavailable", "error", err)
	}
}

// ingestChannelPins applies other daemons' pin changes; the newest change of
// a message wins. A pin can arrive before its message, so a record with
// missing messages is read again on the next pass.
func (s *Service) ingestChannelPins(origin string) {
	err := s.Store.KV.EachChannel(schema.ChannelPinsNamespace, "", func(key, revision string, value []byte) error {
		parts := schema.SplitChannelKey(key)
		if len(parts) != 2 || parts[1] == origin || !s.changedRecord(schema.ChannelPinsNamespace, key, revision) {
			return nil
		}
		record, err := schema.DecodeChannelPins(key, value)
		if err != nil {
			return nil
		}
		retry := false
		for _, pin := range record.Pins {
			if !s.Store.Channels.Has(parts[0], pin.Message) {
				retry = true
				continue
			}
			if _, err := s.Store.Channels.PinRemote(parts[0], pin.Message, pin.Pinned, pin.At); err != nil {
				slog.Warn("agent channel pin not applied", "message", pin.Message, "error", err)
				retry = true
			}
		}
		if retry {
			s.forgetRecord(schema.ChannelPinsNamespace, key)
		}
		return nil
	})
	if err != nil {
		slog.Warn("agent channel pins unavailable", "error", err)
	}
}

// remoteChannelClaims returns other daemons' live claims of a project (all
// projects when empty), advisory only: they are in another checkout.
func (s *Service) remoteChannelClaims(projectID string) []model.ChannelClaim {
	origin := s.channelOrigin()
	prefix := ""
	if projectID != "" {
		prefix = projectID + "."
	}
	var claims []model.ChannelClaim
	_ = s.Store.KV.EachChannel(schema.ChannelClaimsNamespace, prefix, func(key, _ string, value []byte) error {
		parts := schema.SplitChannelKey(key)
		if len(parts) != 2 || parts[1] == origin {
			return nil
		}
		record, err := schema.DecodeChannelClaims(key, value)
		if err != nil {
			return nil
		}
		at, err := time.Parse(time.RFC3339Nano, record.At)
		if err != nil || time.Since(at) > channelClaimsStale {
			return nil
		}
		for _, claim := range record.Claims {
			claims = append(claims, model.ChannelClaim{ProjectID: parts[0], Path: claim.Path, CardID: claim.CardID,
				CardTitle: claim.CardTitle, Since: claim.Since, Daemon: parts[1], Remote: true})
		}
		return nil
	})
	return claims
}

// steerable reports whether a message interrupts cardID's running turn: a
// direct message or a person's @here. Channel posts wait for the digest.
func steerable(message model.ChannelMessage, cardID string) bool {
	return message.Direct(cardID) || message.Here
}

// digestible reports whether a message belongs in cardID's next digest: a
// direct message, or a channel post from the last channelDigestWindow.
// @here only reaches turns that were running when it was posted.
func digestible(message model.ChannelMessage, cardID string, now time.Time) bool {
	if message.Direct(cardID) {
		return true
	}
	if message.Here {
		return false
	}
	created, err := time.Parse(time.RFC3339Nano, message.CreatedAt)
	return err == nil && !created.Before(now.Add(-channelDigestWindow))
}

func keepMessages(messages []model.ChannelMessage, keep func(model.ChannelMessage) bool) []model.ChannelMessage {
	return slices.DeleteFunc(messages, func(message model.ChannelMessage) bool { return !keep(message) })
}

// memberActive reports whether a card listens to channel posts: it is not
// archived and not Done.
func memberActive(card model.Card) bool {
	return !card.Archived && !strings.EqualFold(card.Lane, model.LaneDone)
}
