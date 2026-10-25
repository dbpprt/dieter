package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/store/channels"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

// Agent channels (experimental). Messages persist in Store.Channels; this
// file holds the in-process coordination state: live file claims, coalesced
// steer frames into running turns and wake budgets of idle cards.

const (
	channelSteerDelay      = time.Second
	channelSteerSend       = 5 * time.Second
	channelSteerResult     = 15 * time.Second
	channelWakesPerHour    = 4
	channelWakeChain       = 3
	channelWakeSpacing     = 2 * time.Second
	channelSettingsMaxAge  = 2 * time.Second
	channelCheckRecent     = 3
	channelCheckDecisions  = 5
	channelMaxCheckedFiles = 64
	channelParkedClaim     = time.Hour
	channelSteerRetries    = 30
)

// ErrChannelsOff reports a card or project whose agent channels are off.
var ErrChannelsOff = fault.New(fault.FailedPrecondition, "agent channels are off for this card or project (an experimental setting)")

// ChannelCaller identifies who calls a channel operation: an agent (the card
// of a live turn token) or a human (CardID empty).
type ChannelCaller struct {
	CardID   string
	DeviceID string
}

// ChannelPost is a message to post.
type ChannelPost struct {
	ProjectID string
	To        []string
	ThreadID  string
	Kind      string
	Body      string
	Files     []string
	Wake      bool
	// Here steers every running member on every machine; people only.
	Here        bool
	OperationID string
}

// ChannelCheck answers "is anybody else doing this? has this happened before?"
type ChannelCheck struct {
	Conflicts []model.ChannelClaim
	// Elsewhere are other machines' claims on the same paths: advisory, in
	// their own checkouts.
	Elsewhere []model.ChannelClaim
	Decisions []model.ChannelMessage
	Recent    []model.ChannelMessage
	Summary   string
	Unread    int
}

// ChannelMember is a card of a project channel.
type ChannelMember struct {
	Card      model.Card
	Status    string
	Enabled   bool
	Holds     []string
	WaitingOn []string
	// Daemon runs the card; Remote members run on another machine.
	Daemon string
	Remote bool
}

// ChannelSummary describes one project channel of this daemon.
type ChannelSummary struct {
	Project       model.Project
	Enabled       bool
	LastSeq       int64
	SeenSeq       int64
	Unread        int
	Claims        int
	LastMessageAt string
	Members       []ChannelMember
}

type channelHub struct {
	// work counts deferred steer flushes, wakes and releases in flight.
	work       atomic.Int64
	mu         sync.Mutex
	claims     map[string]*channelClaim
	steering   map[string]bool
	wakes      map[string][]time.Time
	wakeChain  map[string]int
	nextWake   time.Time
	settings   model.ChannelSettings
	settingsAt time.Time
	// replication tracks published and ingested account-wide records.
	replication channelReplication
}

type channelClaim struct {
	model.ChannelClaim
	waiting  map[string]bool
	notified map[string]bool
	// parked claims belong to a card that ended its turn waiting.
	parked   bool
	parkedAt time.Time
}

// activeChannel is the channel state of a running turn with channels on.
type activeChannel struct {
	projectID   string
	projectName string
	workspace   string
	title       string
	since       string
	steer       chan harness.SteerCall
	steers      map[string]*pendingSteer
	retries     int
}

type pendingSteer struct {
	messages []model.ChannelMessage
	result   chan steerOutcome
}

type steerOutcome struct {
	accepted bool
	reason   string
}

func (h *channelHub) init() {
	if h.claims == nil {
		h.claims, h.steering = map[string]*channelClaim{}, map[string]bool{}
		h.wakes, h.wakeChain = map[string][]time.Time{}, map[string]int{}
	}
}

func claimKey(workspace, path string) string { return workspace + "\x00" + path }

// ChannelSettings returns the replicated settings.
func (s *Service) ChannelSettings() (model.ChannelSettings, error) {
	settings, err := s.Store.KV.ChannelSettings()
	if err == nil {
		s.channels.mu.Lock()
		s.channels.settings, s.channels.settingsAt = settings, time.Now()
		s.channels.mu.Unlock()
	}
	return settings, err
}

// channelSettings is ChannelSettings cached for channelSettingsMaxAge; an
// unreadable replica reads as off.
func (s *Service) channelSettings() model.ChannelSettings {
	s.channels.mu.Lock()
	if time.Since(s.channels.settingsAt) < channelSettingsMaxAge {
		settings := s.channels.settings
		s.channels.mu.Unlock()
		return settings
	}
	s.channels.mu.Unlock()
	settings, err := s.ChannelSettings()
	if err != nil {
		slog.Warn("agent channel settings unavailable; channels read as off", "error", err)
	}
	return settings
}

// SetChannelSetting writes the global switch or a project/board override.
func (s *Service) SetChannelSetting(scope, id, value string) (model.ChannelSettings, error) {
	switch scope {
	case "project":
		project, err := s.Store.Kanban.ResolveProject(id)
		if err != nil {
			return model.ChannelSettings{}, err
		}
		id = project.ID
	case "board":
		board, err := s.resolveBoardByID(id)
		if err != nil {
			return model.ChannelSettings{}, err
		}
		id = board.ID
	}
	if err := s.Store.KV.SetChannelSetting(scope, id, value); err != nil {
		return model.ChannelSettings{}, err
	}
	return s.ChannelSettings()
}

func (s *Service) resolveBoardByID(id string) (model.Board, error) {
	projects, err := s.Store.Kanban.ListProjects()
	if err != nil {
		return model.Board{}, err
	}
	for _, project := range projects {
		boards, err := s.Store.Kanban.ListBoards(project.ID)
		if err != nil {
			continue
		}
		for _, board := range boards {
			if board.ID == id {
				return board, nil
			}
		}
	}
	return model.Board{}, fault.New(fault.NotFound, "board not found")
}

func cardBoardID(card model.Card) string {
	if card.Scope == model.ConversationScopeBoard {
		return card.BoardID
	}
	return ""
}

// ChannelsEnabled resolves a card's setting.
func (s *Service) ChannelsEnabled(card model.Card) bool {
	return s.channelSettings().Enabled(card.ProjectID, cardBoardID(card))
}

func (s *Service) projectChannelsEnabled(projectID string) bool {
	settings := s.channelSettings()
	if settings.Enabled(projectID, "") {
		return true
	}
	boards, _ := s.Store.Kanban.ListBoards(projectID)
	ids := make([]string, 0, len(boards))
	for _, board := range boards {
		ids = append(ids, board.ID)
	}
	return settings.ProjectEnabled(projectID, ids)
}

// PostChannelMessage posts to a project channel and dispatches it: steered
// into running recipients, woken (direct, budgeted) or kept for their digest.
func (s *Service) PostChannelMessage(ctx context.Context, caller ChannelCaller, post ChannelPost) (model.ChannelMessage, error) {
	body := strings.TrimSpace(post.Body)
	if body == "" || len(body) > model.ChannelMaxBodyBytes {
		return model.ChannelMessage{}, fault.Invalidf("a message body is 1 to %d bytes", model.ChannelMaxBodyBytes)
	}
	kind, err := channels.NormalizeKind(post.Kind)
	if err != nil {
		return model.ChannelMessage{}, err
	}
	if len(post.Files) > model.ChannelMaxFiles || len(post.To) > model.ChannelMaxRecipients {
		return model.ChannelMessage{}, fault.Invalidf("at most %d files and %d recipients", model.ChannelMaxFiles, model.ChannelMaxRecipients)
	}
	message := model.ChannelMessage{Kind: kind, Body: body, ThreadID: strings.TrimSpace(post.ThreadID)}
	if caller.CardID != "" {
		detail, err := s.Store.Kanban.CardDetail(caller.CardID)
		if err != nil {
			return model.ChannelMessage{}, err
		}
		if !s.ChannelsEnabled(detail.Card) {
			return model.ChannelMessage{}, ErrChannelsOff
		}
		if post.ProjectID != "" && post.ProjectID != detail.Card.ProjectID {
			return model.ChannelMessage{}, fault.New(fault.PermissionDenied, "an agent posts only to its own project channel")
		}
		message.ProjectID = detail.Card.ProjectID
		message.Author = model.ChannelAuthor{Kind: model.ChannelAuthorAgent, CardID: detail.Card.ID, Title: detail.Card.Title, Harness: detail.Card.Provider, Model: detail.Card.Model}
	} else {
		project, err := s.Store.Kanban.ResolveProject(post.ProjectID)
		if err != nil {
			return model.ChannelMessage{}, err
		}
		if !s.projectChannelsEnabled(project.ID) {
			return model.ChannelMessage{}, ErrChannelsOff
		}
		message.ProjectID = project.ID
		message.Author = model.ChannelAuthor{Kind: model.ChannelAuthorHuman, DeviceID: caller.DeviceID}
	}
	if post.Here {
		if caller.CardID != "" {
			return model.ChannelMessage{}, fault.New(fault.PermissionDenied, "only people mention @here")
		}
		if len(post.To) > 0 {
			return model.ChannelMessage{}, fault.Invalidf("@here already reaches every running agent; leave out the recipients")
		}
		message.Here = true
	}
	origin, err := s.Store.KV.ChannelDaemon()
	if err != nil {
		return model.ChannelMessage{}, err
	}
	message.Origin, message.Wake = origin, post.Wake && len(post.To) > 0
	for _, ref := range post.To {
		card, err := s.Store.Kanban.ResolveCard(ref)
		if err != nil {
			return model.ChannelMessage{}, err
		}
		if card.ProjectID != message.ProjectID {
			return model.ChannelMessage{}, fault.New(fault.Invalid, "recipients must belong to the channel's project")
		}
		if !slices.Contains(message.To, card.ID) {
			message.To = append(message.To, card.ID)
		}
	}
	for _, file := range post.Files {
		clean, ok := workspacePath("/", file)
		if !ok {
			clean, ok = workspacePath("workspace", file)
		}
		if !ok {
			return model.ChannelMessage{}, fault.Invalidf("invalid file %q", file)
		}
		message.Files = append(message.Files, clean)
	}
	if post.OperationID != "" && !validOperationID(post.OperationID) {
		return model.ChannelMessage{}, fault.New(fault.Invalid, "invalid operation ID")
	}
	stored, created, err := s.Store.Channels.Post(message, post.OperationID)
	if err != nil {
		return model.ChannelMessage{}, err
	}
	if created {
		s.publishChannelMessage(stored)
	}
	if created && kind == model.ChannelKindDecision {
		stored, err = s.Store.Channels.Pin(stored.ProjectID, stored.ID, true)
		if err != nil {
			return model.ChannelMessage{}, err
		}
		s.schedulePins(stored.ProjectID)
	}
	if created {
		s.dispatchChannelMessage(stored, stored.Wake)
	}
	return stored, nil
}

func validOperationID(id string) bool {
	if len(id) > 128 {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

// dispatchChannelMessage pushes a new message (posted here or replicated) to
// this daemon's running recipients it interrupts (direct messages and @here)
// and wakes its idle direct recipients when wake is set. Others read it in
// their digest.
func (s *Service) dispatchChannelMessage(message model.ChannelMessage, wake bool) {
	s.mu.Lock()
	var running []string
	for cardID, active := range s.active {
		if active.channel != nil && active.channel.projectID == message.ProjectID && !active.finishing && message.AddressedTo(cardID) && steerable(message, cardID) {
			running = append(running, cardID)
		}
	}
	s.mu.Unlock()
	for _, cardID := range running {
		s.scheduleSteer(cardID)
	}
	if !wake {
		return
	}
	for _, cardID := range message.To {
		if slices.Contains(running, cardID) || cardID == message.Author.CardID {
			continue
		}
		// Only the recipient's owner daemon wakes it, within its own budget.
		if card, err := s.Store.Kanban.ResolveCard(cardID); err == nil && s.ownsCard(card) {
			s.requestChannelWake(cardID)
		}
	}
}

// scheduleSteer coalesces deliveries to one card into one steer frame.
func (s *Service) scheduleSteer(cardID string) {
	s.channels.mu.Lock()
	s.channels.init()
	if s.channels.steering[cardID] {
		s.channels.mu.Unlock()
		return
	}
	s.channels.steering[cardID] = true
	s.channels.work.Add(1)
	s.channels.mu.Unlock()
	time.AfterFunc(channelSteerDelay, func() {
		defer s.channels.work.Add(-1)
		s.flushSteer(cardID)
	})
}

func (s *Service) flushSteer(cardID string) {
	again := false
	defer func() {
		s.channels.mu.Lock()
		delete(s.channels.steering, cardID)
		s.channels.mu.Unlock()
		if again {
			s.scheduleSteer(cardID)
		}
	}()
	s.mu.Lock()
	active := s.active[cardID]
	var channel *activeChannel
	if active != nil && !active.finishing && !active.suspend {
		channel = active.channel
	}
	s.mu.Unlock()
	if channel == nil || channel.steer == nil {
		return
	}
	pending, err := s.Store.Channels.Undelivered(channel.projectID, cardID, channel.since)
	pending = keepMessages(pending, func(message model.ChannelMessage) bool { return steerable(message, cardID) })
	if err != nil || len(pending) == 0 {
		return
	}
	batch := pending[:min(len(pending), channelNoticeMessages)]
	text := renderChannelNotice(channel.projectName, batch)
	outcome := s.steerCard(cardID, batch, text)
	switch {
	case outcome.accepted:
		again = len(pending) > len(batch)
	case outcome.reason == harness.SteerNoRunningTurn || outcome.reason == "busy":
		// The worker can still be starting (or between primary and retry
		// streams): retry while this turn runs; the next turn's digest is the
		// fallback.
		again = s.channelSteerRetry(cardID, channel)
	}
}

// channelSteerRetry counts steer retries of a running turn's channel and
// reports whether another one is allowed.
func (s *Service) channelSteerRetry(cardID string, channel *activeChannel) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	active := s.active[cardID]
	if active == nil || active.channel != channel || active.finishing || active.suspend {
		return false
	}
	channel.retries++
	return channel.retries <= channelSteerRetries
}

// steerCard sends one steer frame to a running worker and waits for its
// steer-result. The result handler records the notice and the deliveries.
func (s *Service) steerCard(cardID string, batch []model.ChannelMessage, text string) steerOutcome {
	s.mu.Lock()
	active := s.active[cardID]
	if active == nil || active.finishing || active.suspend || active.channel == nil || active.channel.steer == nil {
		s.mu.Unlock()
		return steerOutcome{reason: harness.SteerNoRunningTurn}
	}
	id := newRuntimeID("steer_")
	pending := &pendingSteer{messages: batch, result: make(chan steerOutcome, 1)}
	active.channel.steers[id] = pending
	steer, done := active.channel.steer, active.done
	s.mu.Unlock()
	timer := time.NewTimer(channelSteerSend)
	defer timer.Stop()
	select {
	case steer <- harness.SteerCall{ID: id, Text: text}:
	case <-done:
		return steerOutcome{reason: harness.SteerNoRunningTurn}
	case <-timer.C:
		s.mu.Lock()
		if current := s.active[cardID]; current != nil && current.channel != nil {
			delete(current.channel.steers, id)
		}
		s.mu.Unlock()
		return steerOutcome{reason: "busy"}
	}
	timer.Reset(channelSteerResult)
	select {
	case outcome := <-pending.result:
		return outcome
	case <-done:
		return steerOutcome{reason: harness.SteerNoRunningTurn}
	case <-timer.C:
		// A late acceptance is still recorded by the result handler.
		return steerOutcome{reason: "timeout"}
	}
}

// completeSteer handles a worker's steer-result in stream order: an accepted
// batch becomes peer-notice parts of the running assistant message and is
// marked delivered.
func (s *Service) completeSteer(cardID, turnID, responseMessageID string, output harness.Output) error {
	s.mu.Lock()
	active := s.active[cardID]
	var pending *pendingSteer
	var channel *activeChannel
	if active != nil && active.turnID == turnID && active.channel != nil {
		channel = active.channel
		pending = channel.steers[output.ID]
		delete(channel.steers, output.ID)
	}
	s.mu.Unlock()
	if pending == nil {
		return nil
	}
	outcome := steerOutcome{accepted: output.Accepted, reason: output.Reason}
	defer func() { pending.result <- outcome }()
	if !output.Accepted {
		return nil
	}
	ids := make([]string, 0, len(pending.messages))
	for _, message := range pending.messages {
		if _, err := s.Store.Conversations.AppendPeerNotice(cardID, turnID, responseMessageID, peerNoticePart(channel.projectName, message)); err != nil {
			return err
		}
		ids = append(ids, message.ID)
	}
	return s.deliverChannel(channel.projectID, cardID, model.ChannelDeliverySteered, ids)
}

// requestChannelWake starts a turn for an idle card within its wake budget:
// channelWakesPerHour, no more than channelWakeChain wakes in a row without a
// human message, and channelWakeSpacing between wakes on this daemon.
func (s *Service) requestChannelWake(cardID string) {
	now := time.Now()
	s.channels.mu.Lock()
	s.channels.init()
	recent := s.channels.wakes[cardID][:0:0]
	for _, at := range s.channels.wakes[cardID] {
		if now.Sub(at) < time.Hour {
			recent = append(recent, at)
		}
	}
	if len(recent) >= channelWakesPerHour || s.channels.wakeChain[cardID] >= channelWakeChain {
		s.channels.wakes[cardID] = recent
		s.channels.mu.Unlock()
		slog.Info("agent channel wake skipped: budget exhausted", "card", cardID)
		return
	}
	s.channels.wakes[cardID] = append(recent, now)
	s.channels.wakeChain[cardID]++
	at := now
	if s.channels.nextWake.After(at) {
		at = s.channels.nextWake
	}
	s.channels.nextWake = at.Add(channelWakeSpacing)
	s.channels.work.Add(1)
	s.channels.mu.Unlock()
	time.AfterFunc(at.Sub(now), func() {
		defer s.channels.work.Add(-1)
		s.wakeCard(cardID)
	})
}

func (s *Service) wakeCard(cardID string) {
	detail, err := s.Store.Kanban.CardDetail(cardID)
	if err != nil || !s.ChannelsEnabled(detail.Card) || detail.Card.Archived || !s.ownsCard(detail.Card) {
		return
	}
	s.mu.Lock()
	running := s.active[cardID] != nil
	s.mu.Unlock()
	if running {
		s.scheduleSteer(cardID)
		return
	}
	pending, err := s.Store.Channels.Undelivered(detail.Card.ProjectID, cardID, detail.Card.CreatedAt)
	now := time.Now()
	pending = keepMessages(pending, func(message model.ChannelMessage) bool { return digestible(message, cardID, now) })
	if err != nil || len(pending) == 0 {
		return
	}
	ids := make([]string, 0, len(pending))
	for _, message := range pending {
		ids = append(ids, message.ID)
	}
	// Mark first so the started turn's digest does not repeat the messages.
	if err := s.deliverChannel(detail.Card.ProjectID, cardID, model.ChannelDeliveryWoke, ids); err != nil {
		slog.Warn("agent channel wake not recorded", "card", cardID, "error", err)
		return
	}
	text := renderChannelDigest(detail.Project.Name, pending) + "\n\nThese agent channel messages woke you. Continue your task where you left off; if nothing needs doing, reply briefly."
	if _, err := s.SubmitCardPartsWithMessageID(cardID, []model.UIMessagePart{{Type: "text", Text: text}}, "", "", "", nil, newRuntimeID(model.ChannelWakeMessagePrefix)); err != nil {
		slog.Warn("agent channel wake failed", "card", cardID, "error", err)
	}
}

// channelTurnStarted resets the wake chain when a human message starts a turn.
func (s *Service) channelTurnStarted(cardID, messageID string) {
	if model.IsChannelWakeMessage(messageID) {
		return
	}
	s.channels.mu.Lock()
	s.channels.init()
	delete(s.channels.wakeChain, cardID)
	s.channels.mu.Unlock()
}

// claimPaths records cardID's writes to paths in workspace. It returns the
// first path another card holds, after registering cardID as its waiter.
func (s *Service) claimPaths(cardID, title, projectID, workspace string, paths []string) (model.ChannelClaim, bool) {
	now := time.Now()
	s.channels.mu.Lock()
	defer s.channels.mu.Unlock()
	s.channels.init()
	for _, path := range paths {
		key := claimKey(workspace, path)
		if claim := s.channels.claims[key]; claim != nil && claim.CardID != cardID {
			claim.waiting[cardID] = true
			return claim.snapshot(), true
		}
	}
	claimed := false
	defer func() {
		if claimed {
			s.Store.NotifyChanges()
		}
	}()
	for _, path := range paths {
		key := claimKey(workspace, path)
		if s.channels.claims[key] == nil {
			claimed = true
			s.channels.claims[key] = &channelClaim{
				ChannelClaim: model.ChannelClaim{ProjectID: projectID, Workspace: workspace, Path: path, CardID: cardID, CardTitle: title, Since: now.UTC().Format(time.RFC3339)},
				waiting:      map[string]bool{}, notified: map[string]bool{},
			}
		}
	}
	return model.ChannelClaim{}, false
}

func (c *channelClaim) snapshot() model.ChannelClaim {
	claim := c.ChannelClaim
	claim.Parked = c.parked
	claim.Waiting = make([]string, 0, len(c.waiting))
	for cardID := range c.waiting {
		claim.Waiting = append(claim.Waiting, cardID)
	}
	sort.Strings(claim.Waiting)
	return claim
}

func heldFor(claim model.ChannelClaim) string {
	since, err := time.Parse(time.RFC3339, claim.Since)
	if err != nil {
		return "a while"
	}
	return time.Since(since).Round(time.Second).String()
}

// notifyHolder tells a claim's holder, once per waiter and file, that another
// card wants the file.
func (s *Service) notifyHolder(claim model.ChannelClaim, waiterID, waiterTitle string) {
	s.channels.mu.Lock()
	held := s.channels.claims[claimKey(claim.Workspace, claim.Path)]
	first := held != nil && !held.notified[waiterID]
	if first {
		held.notified[waiterID] = true
	}
	s.channels.mu.Unlock()
	if !first {
		return
	}
	body := fmt.Sprintf("Agent %s ('%s') wants to change %s, which you are changing. Finish your work on it; Dieter releases it to them when your turn ends.", waiterID, channelAttribute(waiterTitle), claim.Path)
	s.postDieterMessage(claim.ProjectID, model.ChannelKindRequest, body, []string{claim.CardID}, []string{claim.Path}, false)
}

func (s *Service) postDieterMessage(projectID, kind, body string, to, files []string, wake bool) {
	message, _, err := s.Store.Channels.Post(model.ChannelMessage{ProjectID: projectID, Kind: kind, Author: model.ChannelAuthor{Kind: model.ChannelAuthorDieter}, To: to, Body: body, Files: files}, "")
	if err != nil {
		slog.Warn("agent channel event not recorded", "project", projectID, "error", err)
		return
	}
	s.dispatchChannelMessage(message, wake)
}

// channelObservedWrite registers writes seen in a turn's stream (every
// harness). A write to a file another card holds is not prevented (hooks
// do that where available) but warned about immediately.
func (s *Service) channelObservedWrite(cardID string, chunk json.RawMessage) {
	var part struct {
		Type     string          `json:"type"`
		ToolName string          `json:"toolName"`
		Input    json.RawMessage `json:"input"`
	}
	if json.Unmarshal(chunk, &part) != nil || part.Type != "tool-input-available" {
		return
	}
	s.mu.Lock()
	active := s.active[cardID]
	var channel *activeChannel
	if active != nil {
		channel = active.channel
	}
	s.mu.Unlock()
	if channel == nil {
		return
	}
	paths := channelWritePaths(part.ToolName, part.Input, channel.workspace)
	if len(paths) == 0 {
		return
	}
	s.expireParkedClaims()
	claim, conflict := s.claimPaths(cardID, channel.title, channel.projectID, channel.workspace, paths)
	if !conflict {
		return
	}
	body := fmt.Sprintf("You just changed %s, which agent %s ('%s') has been changing for %s. Coordinate with them (%s channel post --to %s \"...\") before you change it further; Dieter tells you when it is free.", claim.Path, claim.CardID, channelAttribute(claim.CardTitle), heldFor(claim), s.CLIWord(), claim.CardID)
	s.postDieterMessage(channel.projectID, model.ChannelKindHold, body, []string{cardID}, []string{claim.Path}, false)
	s.notifyHolder(claim, cardID, channel.title)
}

// HandleChannelHook answers a harness PreToolUse hook: a write to a file
// another card holds is denied with a reason; any other call has no opinion.
func (s *Service) HandleChannelHook(caller ChannelCaller, event []byte) ([]byte, error) {
	if caller.CardID == "" || len(event) == 0 {
		return nil, nil
	}
	var input struct {
		Event     string          `json:"hook_event_name"`
		ToolName  string          `json:"tool_name"`
		ToolInput json.RawMessage `json:"tool_input"`
	}
	if json.Unmarshal(event, &input) != nil || input.Event != "PreToolUse" {
		return nil, nil
	}
	s.mu.Lock()
	active := s.active[caller.CardID]
	var channel *activeChannel
	if active != nil {
		channel = active.channel
	}
	s.mu.Unlock()
	if channel == nil {
		return nil, nil
	}
	s.expireParkedClaims()
	if claim, files, swept := s.commitSweep(caller.CardID, channel.workspace, input.ToolName, input.ToolInput); swept {
		s.notifyHolder(claim, caller.CardID, channel.title)
		reason := fmt.Sprintf("Dieter agent channels: this commit would include %s, which agent %s ('%s') is changing in this shared checkout. Commit only your own files with explicit paths: git commit -m \"MESSAGE\" -- FILE...", strings.Join(files, ", "), claim.CardID, channelAttribute(claim.CardTitle))
		return json.Marshal(map[string]any{"hookSpecificOutput": map[string]string{
			"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason,
		}})
	}
	paths := channelWritePaths(input.ToolName, input.ToolInput, channel.workspace)
	if len(paths) == 0 {
		return nil, nil
	}
	claim, conflict := s.claimPaths(caller.CardID, channel.title, channel.projectID, channel.workspace, paths)
	if !conflict {
		return nil, nil
	}
	s.notifyHolder(claim, caller.CardID, channel.title)
	reason := fmt.Sprintf("Dieter agent channels: %s is being changed by agent %s ('%s') for %s. Do the other parts of your task first. If nothing else is left, end your turn with a one-line status; you will be woken when %s is free. Do not poll or sleep. You can message them with: %s channel post --to %s \"...\"", claim.Path, claim.CardID, channelAttribute(claim.CardTitle), heldFor(claim), claim.Path, s.CLIWord(), claim.CardID)
	return json.Marshal(map[string]any{"hookSpecificOutput": map[string]string{
		"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason,
	}})
}

// commitSweep reports a shell `git commit` without paths whose commit would
// include files another card holds: staged files, or with -a/--all every
// modified tracked file of the shared index.
func (s *Service) commitSweep(cardID, workspace, toolName string, toolInput json.RawMessage) (model.ChannelClaim, []string, bool) {
	switch strings.ToLower(toolName) {
	case "bash", "shell", "exec_command", "local_shell", "exec":
	default:
		return model.ChannelClaim{}, nil, false
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(toolInput, &fields)
	var command string
	_ = json.Unmarshal(fields["command"], &command)
	if command == "" {
		_ = json.Unmarshal(fields["cmd"], &command)
	}
	match := gitCommit.FindStringIndex(command)
	if match == nil || workspace == "" {
		return model.ChannelClaim{}, nil, false
	}
	rest := command[match[1]:]
	if end := strings.IndexAny(rest, ";&|\n"); end >= 0 {
		rest = rest[:end]
	}
	if strings.Contains(rest, " -- ") || strings.HasSuffix(strings.TrimSpace(rest), " --") || gitCommitPathspec(rest, workspace) {
		return model.ChannelClaim{}, nil, false
	}
	args := []string{"-C", workspace, "diff", "--cached", "--name-only"}
	if gitCommitAll.MatchString(rest) {
		args = []string{"-C", workspace, "diff", "HEAD", "--name-only"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "git", args...).Output()
	if err != nil {
		return model.ChannelClaim{}, nil, false
	}
	s.channels.mu.Lock()
	defer s.channels.mu.Unlock()
	var held model.ChannelClaim
	var files []string
	for _, path := range strings.Fields(string(output)) {
		if claim := s.channels.claims[claimKey(workspace, path)]; claim != nil && claim.CardID != cardID {
			if held.CardID == "" {
				held = claim.snapshot()
			}
			if claim.CardID == held.CardID {
				files = append(files, path)
			}
		}
	}
	return held, files, held.CardID != ""
}

// gitCommitPathspec reports whether git commit arguments name files (a commit
// limited to those paths).
func gitCommitPathspec(args, workspace string) bool {
	fields := strings.Fields(args)
	for i := 0; i < len(fields); i++ {
		field := strings.Trim(fields[i], `"'`)
		switch {
		case field == "-m" || field == "-F" || field == "--message" || field == "--file" || field == "-C" || field == "--author":
			i++ // the option's value
		case strings.HasPrefix(field, "-"):
		default:
			if path, ok := workspacePath(workspace, field); ok && pathOrParentExists(workspace, path) {
				if _, err := os.Stat(filepath.Join(workspace, path)); err == nil {
					return true
				}
			}
		}
	}
	return false
}

// releaseChannelClaims ends cardID's claims (all when paths is empty) and
// tells each waiter its files are free: steered if running, woken if idle.
func (s *Service) releaseChannelClaims(cardID string, paths []string) []model.ChannelClaim {
	s.channels.mu.Lock()
	s.channels.init()
	var released []model.ChannelClaim
	waiters := map[string][]string{}
	projects := map[string]string{}
	for key, claim := range s.channels.claims {
		if claim.CardID != cardID || len(paths) > 0 && !slices.Contains(paths, claim.Path) {
			continue
		}
		delete(s.channels.claims, key)
		released = append(released, claim.snapshot())
		for waiter := range claim.waiting {
			waiters[waiter] = append(waiters[waiter], claim.Path)
			projects[waiter] = claim.ProjectID
		}
	}
	for _, claim := range s.channels.claims {
		for waiter := range waiters {
			delete(claim.waiting, waiter)
		}
	}
	s.channels.mu.Unlock()
	if len(released) > 0 {
		s.Store.NotifyChanges()
	}
	if len(waiters) == 0 {
		return released
	}
	title := ""
	if card, err := s.Store.Kanban.ResolveCard(cardID); err == nil {
		title = card.Title
	}
	for waiter, files := range waiters {
		sort.Strings(files)
		// Only facts Dieter observed: the holder's own words would carry
		// Dieter's provenance.
		body := fmt.Sprintf("%s is free now: agent %s ('%s') finished its turn.", strings.Join(files, ", "), cardID, channelAttribute(title))
		s.postDieterMessage(projects[waiter], model.ChannelKindRelease, body, []string{waiter}, files, true)
	}
	return released
}

// ChannelClaims lists live claims, all or of one project.
func (s *Service) ChannelClaims(projectID string) []model.ChannelClaim {
	claims := append(s.localChannelClaims(projectID), s.remoteChannelClaims(projectID)...)
	sort.SliceStable(claims, func(i, j int) bool {
		if claims[i].ProjectID != claims[j].ProjectID {
			return claims[i].ProjectID < claims[j].ProjectID
		}
		return claims[i].Path < claims[j].Path
	})
	return claims
}

// localChannelClaims are the live claims in this daemon's checkouts.
func (s *Service) localChannelClaims(projectID string) []model.ChannelClaim {
	origin := s.channelOrigin()
	s.channels.mu.Lock()
	defer s.channels.mu.Unlock()
	var claims []model.ChannelClaim
	for _, claim := range s.channels.claims {
		if projectID == "" || claim.ProjectID == projectID {
			snapshot := claim.snapshot()
			snapshot.Daemon = origin
			claims = append(claims, snapshot)
		}
	}
	sort.Slice(claims, func(i, j int) bool {
		if claims[i].ProjectID != claims[j].ProjectID {
			return claims[i].ProjectID < claims[j].ProjectID
		}
		return claims[i].Path < claims[j].Path
	})
	return claims
}

// ReleaseChannelClaims releases a card's claims on request: agents release
// their own, humans any card's.
func (s *Service) ReleaseChannelClaims(caller ChannelCaller, cardID string, paths []string) ([]model.ChannelClaim, error) {
	if caller.CardID != "" {
		if cardID != "" && cardID != caller.CardID {
			return nil, fault.New(fault.PermissionDenied, "an agent releases only its own claims")
		}
		cardID = caller.CardID
	}
	card, err := s.Store.Kanban.ResolveCard(cardID)
	if err != nil {
		return nil, err
	}
	return s.releaseChannelClaims(card.ID, paths), nil
}

// ChannelInbox returns a card's undelivered messages, the ones its next digest
// would carry; unless peek, it marks them delivered on the card's owner.
func (s *Service) ChannelInbox(caller ChannelCaller, cardID string, peek bool) ([]model.ChannelMessage, error) {
	if caller.CardID != "" {
		if cardID != "" && cardID != caller.CardID {
			return nil, fault.New(fault.PermissionDenied, "an agent reads only its own inbox")
		}
		cardID = caller.CardID
	}
	card, err := s.Store.Kanban.ResolveCard(cardID)
	if err != nil {
		return nil, err
	}
	pending, err := s.Store.Channels.Undelivered(card.ProjectID, card.ID, card.CreatedAt)
	now := time.Now()
	pending = keepMessages(pending, func(message model.ChannelMessage) bool { return digestible(message, card.ID, now) })
	if err != nil || peek || len(pending) == 0 {
		return pending, err
	}
	// Deliveries are recorded by the card's owner, which publishes its receipt.
	if !s.ownsCard(card) {
		return nil, fault.New(fault.FailedPrecondition, "the card runs on another machine: read its inbox there (--machine), or add --peek")
	}
	ids := make([]string, 0, len(pending))
	for _, message := range pending {
		ids = append(ids, message.ID)
	}
	return pending, s.deliverChannel(card.ProjectID, card.ID, model.ChannelDeliveryInbox, ids)
}

// CheckChannelFiles reports live claims on files, pinned decisions and recent
// notes that mention them. An agent whose files are held becomes a waiter and
// is woken when they are free.
func (s *Service) CheckChannelFiles(caller ChannelCaller, cardID string, files []string, intent string) (ChannelCheck, error) {
	if caller.CardID != "" {
		cardID = caller.CardID
	}
	if len(files) == 0 || len(files) > channelMaxCheckedFiles {
		return ChannelCheck{}, fault.Invalidf("check 1 to %d files", channelMaxCheckedFiles)
	}
	card, err := s.Store.Kanban.ResolveCard(cardID)
	if err != nil {
		return ChannelCheck{}, err
	}
	s.expireParkedClaims()
	workspace := s.cardWorkspace(card.ID)
	var paths []string
	for _, file := range files {
		if path, ok := workspacePath(workspace, file); ok {
			paths = append(paths, path)
		} else if path, ok := workspacePath("/", file); ok && !strings.HasPrefix(file, "/") {
			paths = append(paths, path)
		}
	}
	var check ChannelCheck
	s.channels.mu.Lock()
	s.channels.init()
	for _, path := range paths {
		claim := s.channels.claims[claimKey(workspace, path)]
		if claim == nil || claim.CardID == card.ID {
			continue
		}
		if caller.CardID != "" {
			claim.waiting[card.ID] = true
		}
		check.Conflicts = append(check.Conflicts, claim.snapshot())
	}
	s.channels.mu.Unlock()
	if caller.CardID != "" {
		// An agent that checks and holds off is a waiter: its holders hear of it.
		for _, claim := range check.Conflicts {
			s.notifyHolder(claim, card.ID, card.Title)
		}
	}
	for _, claim := range s.remoteChannelClaims(card.ProjectID) {
		if slices.Contains(paths, claim.Path) && claim.CardID != card.ID {
			check.Elsewhere = append(check.Elsewhere, claim)
		}
	}
	mentions := func(message model.ChannelMessage) bool {
		for _, path := range paths {
			if slices.Contains(message.Files, path) || strings.Contains(message.Body, path) {
				return true
			}
		}
		return false
	}
	check.Decisions, _ = s.Store.Channels.Matching(card.ProjectID, channelCheckDecisions, func(message model.ChannelMessage) bool {
		return message.Pinned && mentions(message)
	})
	check.Recent, _ = s.Store.Channels.Matching(card.ProjectID, channelCheckRecent, func(message model.ChannelMessage) bool {
		return !message.Pinned && message.Author.CardID != card.ID && message.Author.Kind != model.ChannelAuthorDieter && mentions(message)
	})
	if pending, err := s.Store.Channels.Undelivered(card.ProjectID, card.ID, card.CreatedAt); err == nil {
		check.Unread = len(pending)
	}
	var summary strings.Builder
	for _, claim := range check.Conflicts {
		fmt.Fprintf(&summary, "%s: being changed by agent %s ('%s') for %s. Do other work first; you will be woken when it is free.\n", claim.Path, claim.CardID, channelAttribute(claim.CardTitle), heldFor(claim))
	}
	for _, claim := range check.Elsewhere {
		fmt.Fprintf(&summary, "%s: also being changed by agent %s ('%s') on machine %s, in its own checkout. Coordinate with it before you push.\n", claim.Path, claim.CardID, channelAttribute(claim.CardTitle), claim.Daemon)
	}
	if len(check.Decisions) > 0 {
		summary.WriteString("Pinned decisions about these files:\n")
		for _, message := range check.Decisions {
			fmt.Fprintf(&summary, "- %s (%s): %s\n", message.ID, channelSender(message.Author), message.Body)
		}
	}
	if len(check.Recent) > 0 {
		summary.WriteString("Recent notes about these files:\n")
		for _, message := range check.Recent {
			fmt.Fprintf(&summary, "- %s (%s, %s): %s\n", message.ID, channelSender(message.Author), message.Kind, truncateUTF8(message.Body, 300))
		}
	}
	if check.Unread > 0 {
		fmt.Fprintf(&summary, "%d unread channel message(s); read them with: dieter channel inbox\n", check.Unread)
	}
	if summary.Len() == 0 {
		summary.WriteString("No other agent is changing these files, and the channel has no notes about them.")
	}
	check.Summary = strings.TrimSpace(summary.String())
	return check, nil
}

// cardWorkspace is the directory a card's agent works in: the running turn's
// workspace, else the card's workspace record, else its project checkout.
func (s *Service) cardWorkspace(cardID string) string {
	s.mu.Lock()
	if active := s.active[cardID]; active != nil && active.channel != nil {
		workspace := active.channel.workspace
		s.mu.Unlock()
		return workspace
	}
	s.mu.Unlock()
	if workspace, err := s.Store.Workspaces.Get(cardID); err == nil && workspace.Path != "" {
		return workspace.Path
	}
	if detail, err := s.Store.Kanban.CardDetail(cardID); err == nil {
		return detail.Project.Path
	}
	return ""
}

// ChannelSummaries lists the account's project channels: projects with
// channels on or with messages, their read state and members.
func (s *Service) ChannelSummaries(ctx context.Context) ([]ChannelSummary, error) {
	projects, err := s.Store.Kanban.ListProjects()
	if err != nil {
		return nil, err
	}
	logged, _ := s.Store.Channels.Projects()
	// Members are the account's cards of the project on every machine.
	cards, err := s.Store.Kanban.ListCards(kanban.CardFilter{})
	if err != nil {
		return nil, err
	}
	origin := s.channelOrigin()
	settings := s.channelSettings()
	claims := s.ChannelClaims("")
	s.mu.Lock()
	running := map[string]bool{}
	for cardID, active := range s.active {
		running[cardID] = !active.finishing
	}
	s.mu.Unlock()
	var summaries []ChannelSummary
	for _, project := range projects {
		boards, _ := s.Store.Kanban.ListBoards(project.ID)
		boardIDs := make([]string, 0, len(boards))
		for _, board := range boards {
			boardIDs = append(boardIDs, board.ID)
		}
		enabled := settings.ProjectEnabled(project.ID, boardIDs)
		if !enabled && !slices.Contains(logged, project.ID) {
			continue
		}
		summary := ChannelSummary{Project: project, Enabled: enabled}
		summary.LastSeq, summary.LastMessageAt, _ = s.Store.Channels.LastSeq(project.ID)
		summary.SeenSeq, summary.Unread, _ = s.Store.Channels.Unread(project.ID)
		for _, claim := range claims {
			if claim.ProjectID == project.ID {
				summary.Claims++
			}
		}
		for _, card := range cards {
			if card.ProjectID != project.ID || !memberActive(card) {
				continue
			}
			daemon := card.OwnerDaemonID
			if daemon == "" {
				daemon = origin
			}
			remote := daemon != origin
			member := ChannelMember{Card: card, Enabled: settings.Enabled(project.ID, cardBoardID(card)), Status: "idle", Daemon: daemon, Remote: remote}
			if card.Runtime == model.RuntimeFailed {
				member.Status = "failed"
			}
			if running[card.ID] || remote && card.Runtime == model.RuntimeRunning {
				member.Status = "running"
			}
			for _, claim := range claims {
				if claim.CardID == card.ID {
					member.Holds = append(member.Holds, claim.Path)
				}
				if slices.Contains(claim.Waiting, card.ID) {
					member.WaitingOn = append(member.WaitingOn, claim.Path)
				}
			}
			if len(member.WaitingOn) > 0 {
				member.Status = "waiting"
			}
			if member.Enabled || len(member.Holds) > 0 {
				summary.Members = append(summary.Members, member)
			}
		}
		summaries = append(summaries, summary)
	}
	return summaries, nil
}

// channelPlan is how agent channels change a starting turn: the static
// instructions, the digest of undelivered messages ahead of the prompt, the
// steer channel and, where the harness has hooks, the pre-write hook.
type channelPlan struct {
	enabled   bool
	projectID string
	cli       string
	digest    string
	delivered []string
}

func (s *Service) planChannelTurn(detail model.CardDetail, messageID string) channelPlan {
	s.channelTurnStarted(detail.Card.ID, messageID)
	if !s.ChannelsEnabled(detail.Card) {
		return channelPlan{}
	}
	plan := channelPlan{enabled: true, projectID: detail.Card.ProjectID, cli: s.CLIWord()}
	pending, err := s.Store.Channels.Undelivered(detail.Card.ProjectID, detail.Card.ID, detail.Card.CreatedAt)
	now := time.Now()
	pending = keepMessages(pending, func(message model.ChannelMessage) bool { return digestible(message, detail.Card.ID, now) })
	if err == nil && len(pending) > 0 {
		plan.digest = renderChannelDigest(detail.Project.Name, pending)
		for _, message := range pending {
			plan.delivered = append(plan.delivered, message.ID)
		}
	}
	return plan
}

func (p channelPlan) instructions(base string) string {
	if !p.enabled {
		return base
	}
	return strings.TrimSpace(base + "\n\n" + dieterprompt.ChannelInstructions(p.cli))
}

func (p channelPlan) prompt(base string) string {
	if p.digest == "" {
		return base
	}
	return p.digest + "\n\n" + base
}

// commitChannelTurn configures the request and records the digest delivery
// just before the worker starts.
func (s *Service) commitChannelTurn(cardID string, plan channelPlan, request *harness.Request) {
	if !plan.enabled {
		return
	}
	request.SteerEnabled = true
	if s.CLIExecutable != "" {
		request.ChannelHookCommand = s.CLIWord() + " channel hook"
	}
	if err := s.deliverChannel(plan.projectID, cardID, model.ChannelDeliveryDigest, plan.delivered); err != nil {
		slog.Warn("agent channel digest not recorded", "card", cardID, "error", err)
	}
}

// CLIWord is the shell word agents run the Dieter CLI with: CLIExecutable,
// quoted when needed, or "dieter".
func (s *Service) CLIWord() string { return dieterprompt.CLIWord(s.CLIExecutable) }

// DaemonExecutable is the running dieter binary, for CLIExecutable.
func DaemonExecutable() string {
	path, err := os.Executable()
	if err != nil {
		return ""
	}
	return path
}

// channelTurnBegin attaches channel state to a running turn.
func (s *Service) channelTurnBegin(detail model.CardDetail, turnID string, request *harness.Request) {
	if !request.SteerEnabled {
		return
	}
	steer := make(chan harness.SteerCall, 4)
	request.Steer = steer
	s.mu.Lock()
	if active := s.active[detail.Card.ID]; active != nil && active.turnID == turnID {
		active.channel = &activeChannel{
			projectID: detail.Card.ProjectID, projectName: detail.Project.Name, workspace: request.ProjectPath,
			title: detail.Card.Title, since: detail.Card.CreatedAt, steer: steer, steers: map[string]*pendingSteer{},
		}
	}
	s.mu.Unlock()
	s.channels.mu.Lock()
	for _, claim := range s.channels.claims {
		if claim.CardID == detail.Card.ID {
			claim.parked = false
		}
	}
	s.channels.mu.Unlock()
	// Messages that arrived while the turn was starting go out right away.
	if pending, err := s.Store.Channels.Undelivered(detail.Card.ProjectID, detail.Card.ID, detail.Card.CreatedAt); err == nil && len(pending) > 0 {
		s.scheduleSteer(detail.Card.ID)
	}
}

// channelTurnEnd releases a finished turn's claims and wakes waiters. A card
// that ends its turn waiting for a file a running card holds keeps (parks)
// its claims: its changes are usually uncommitted, and it is woken to finish
// them. Waiting on a parked claim never parks, so idle cards cannot hold each
// other's files forever; parked claims also expire after channelParkedClaim.
func (s *Service) channelTurnEnd(cardID string) {
	s.channels.mu.Lock()
	s.channels.init()
	waitingOnRunning := false
	for _, claim := range s.channels.claims {
		if claim.waiting[cardID] && !claim.parked {
			waitingOnRunning = true
		}
	}
	if waitingOnRunning {
		now := time.Now()
		for _, claim := range s.channels.claims {
			if claim.CardID == cardID {
				claim.parked, claim.parkedAt = true, now
			}
		}
		s.channels.mu.Unlock()
		s.Store.NotifyChanges()
		return
	}
	s.channels.mu.Unlock()
	s.releaseChannelClaims(cardID, nil)
}

// expireParkedClaims releases claims parked longer than channelParkedClaim.
// Callers must not hold s.channels.mu.
func (s *Service) expireParkedClaims() {
	s.channels.mu.Lock()
	var expired []string
	for _, claim := range s.channels.claims {
		if claim.parked && time.Since(claim.parkedAt) > channelParkedClaim && !slices.Contains(expired, claim.CardID) {
			expired = append(expired, claim.CardID)
		}
	}
	s.channels.mu.Unlock()
	for _, cardID := range expired {
		s.releaseChannelClaims(cardID, nil)
	}
}

// ChannelMessagePage pages a project channel.
func (s *Service) ChannelMessagePage(projectID string, afterSeq, beforeSeq int64, limit int, threadID string) ([]model.ChannelMessage, int64, bool, error) {
	project, err := s.Store.Kanban.ResolveProject(projectID)
	if err != nil {
		return nil, 0, false, err
	}
	return s.Store.Channels.Page(project.ID, afterSeq, beforeSeq, limit, threadID)
}

// PinChannelMessage pins or unpins a message.
func (s *Service) PinChannelMessage(projectID, messageID string, pinned bool) (model.ChannelMessage, error) {
	project, err := s.Store.Kanban.ResolveProject(projectID)
	if err != nil {
		return model.ChannelMessage{}, err
	}
	message, err := s.Store.Channels.Pin(project.ID, messageID, pinned)
	if err == nil {
		s.schedulePins(project.ID)
	}
	return message, err
}

// MarkChannelRead advances the human read position.
func (s *Service) MarkChannelRead(projectID string, seq int64) error {
	project, err := s.Store.Kanban.ResolveProject(projectID)
	if err != nil {
		return err
	}
	return s.Store.Channels.MarkSeen(project.ID, seq)
}
