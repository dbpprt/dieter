package api

import (
	"context"
	"fmt"
	"slices"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/dbpprt/dieter/internal/engine"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
)

const (
	maxChannelHookBytes   = 1 << 20
	maxChannelWatches     = 64
	channelWatchWindow    = 200
	channelSummaryRefresh = 2 * time.Second
)

// channelCaller classifies the caller: a live turn token on the local route
// is that card's agent; everyone else is a human. Remote metadata is never
// forwarded, so a token only comes from a local process.
func (s *Server) channelCaller(ctx context.Context) (engine.ChannelCaller, error) {
	device := requestHeader(ctx, deviceIDMetadata)
	if requestHeader(ctx, operatorSubjectMetadata) != "" {
		return engine.ChannelCaller{DeviceID: device}, nil
	}
	token := requestHeader(ctx, turnTokenMetadata)
	if token == "" {
		return engine.ChannelCaller{DeviceID: device}, nil
	}
	cardID, err := s.app.VerifyTurnToken(token)
	if err != nil {
		return engine.ChannelCaller{}, fault.New(fault.PermissionDenied, err.Error())
	}
	return engine.ChannelCaller{CardID: cardID}, nil
}

func (api *channelsAPI) ListChannels(ctx context.Context, _ *dieterv1.ListChannelsRequest) (*dieterv1.ListChannelsResponse, error) {
	summaries, err := api.server.app.ChannelSummaries(ctx)
	if err != nil {
		return nil, domainFailure(err)
	}
	response := &dieterv1.ListChannelsResponse{}
	if identity, err := api.server.store.Replica.EnsureIdentity(); err == nil {
		response.DaemonId = identity.DaemonID
	}
	for _, summary := range summaries {
		response.Channels = append(response.Channels, protoChannelSummary(summary))
	}
	return response, nil
}

func (api *channelsAPI) ListChannelMessages(_ context.Context, r *dieterv1.ListChannelMessagesRequest) (*dieterv1.ChannelMessagePage, error) {
	messages, last, more, err := api.server.app.ChannelMessagePage(r.GetProjectId(), r.GetAfterSeq(), r.GetBeforeSeq(), int(r.GetLimit()), r.GetThreadId())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoChannelPage(messages, last, more), nil
}

func (api *channelsAPI) PostChannelMessage(ctx context.Context, r *dieterv1.PostChannelMessageRequest) (*dieterv1.ChannelMessage, error) {
	caller, err := api.server.channelCaller(ctx)
	if err != nil {
		return nil, err
	}
	message, err := api.server.app.PostChannelMessage(ctx, caller, engine.ChannelPost{
		ProjectID: r.GetProjectId(), To: r.GetToCardIds(), ThreadID: r.GetThreadId(), Kind: r.GetKind(),
		Body: r.GetBody(), Files: r.GetFiles(), Wake: r.GetWake(), Here: r.GetHere(), OperationID: r.GetOperationId(),
	})
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoChannelMessage(message), nil
}

func (api *channelsAPI) PinChannelMessage(_ context.Context, r *dieterv1.PinChannelMessageRequest) (*dieterv1.ChannelMessage, error) {
	message, err := api.server.app.PinChannelMessage(r.GetProjectId(), r.GetMessageId(), r.GetPinned())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoChannelMessage(message), nil
}

func (api *channelsAPI) MarkChannelRead(_ context.Context, r *dieterv1.MarkChannelReadRequest) (*emptypb.Empty, error) {
	if err := api.server.app.MarkChannelRead(r.GetProjectId(), r.GetSeq()); err != nil {
		return nil, domainFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *channelsAPI) GetChannelInbox(ctx context.Context, r *dieterv1.GetChannelInboxRequest) (*dieterv1.ChannelMessagePage, error) {
	caller, err := api.server.channelCaller(ctx)
	if err != nil {
		return nil, err
	}
	if caller.CardID == "" && r.GetCardId() == "" {
		return nil, fault.New(fault.Invalid, "card ID required outside an agent turn")
	}
	messages, err := api.server.app.ChannelInbox(caller, r.GetCardId(), r.GetPeek())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoChannelPage(messages, 0, false), nil
}

func (api *channelsAPI) CheckChannelFiles(ctx context.Context, r *dieterv1.CheckChannelFilesRequest) (*dieterv1.ChannelCheck, error) {
	caller, err := api.server.channelCaller(ctx)
	if err != nil {
		return nil, err
	}
	if caller.CardID == "" && r.GetCardId() == "" {
		return nil, fault.New(fault.Invalid, "card ID required outside an agent turn")
	}
	check, err := api.server.app.CheckChannelFiles(caller, r.GetCardId(), r.GetFiles(), r.GetIntent())
	if err != nil {
		return nil, domainFailure(err)
	}
	response := &dieterv1.ChannelCheck{Summary: check.Summary, Unread: int32(check.Unread)}
	for _, claim := range check.Conflicts {
		response.Conflicts = append(response.Conflicts, protoChannelClaim(claim))
	}
	for _, message := range check.Decisions {
		response.Decisions = append(response.Decisions, protoChannelMessage(message))
	}
	for _, message := range check.Recent {
		response.Recent = append(response.Recent, protoChannelMessage(message))
	}
	for _, claim := range check.Elsewhere {
		response.Elsewhere = append(response.Elsewhere, protoChannelClaim(claim))
	}
	return response, nil
}

func (api *channelsAPI) ListChannelClaims(_ context.Context, r *dieterv1.ListChannelClaimsRequest) (*dieterv1.ChannelClaims, error) {
	projectID := r.GetProjectId()
	if projectID != "" {
		project, err := api.server.store.Kanban.ResolveProject(projectID)
		if err != nil {
			return nil, domainFailure(err)
		}
		projectID = project.ID
	}
	return protoChannelClaims(api.server.app.ChannelClaims(projectID)), nil
}

func (api *channelsAPI) ReleaseChannelClaims(ctx context.Context, r *dieterv1.ReleaseChannelClaimsRequest) (*dieterv1.ChannelClaims, error) {
	caller, err := api.server.channelCaller(ctx)
	if err != nil {
		return nil, err
	}
	if caller.CardID == "" && r.GetCardId() == "" {
		return nil, fault.New(fault.Invalid, "card ID required outside an agent turn")
	}
	released, err := api.server.app.ReleaseChannelClaims(caller, r.GetCardId(), r.GetPaths())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoChannelClaims(released), nil
}

// HandleChannelHook fails open: a hook without a live turn, or any failure,
// returns no opinion so the harness proceeds.
func (api *channelsAPI) HandleChannelHook(ctx context.Context, r *dieterv1.ChannelHookRequest) (*dieterv1.ChannelHookResponse, error) {
	if len(r.GetEventJson()) > maxChannelHookBytes {
		return nil, fault.New(fault.Invalid, "hook event too large")
	}
	caller, err := api.server.channelCaller(ctx)
	if err != nil || caller.CardID == "" {
		return &dieterv1.ChannelHookResponse{}, nil
	}
	output, err := api.server.app.HandleChannelHook(caller, r.GetEventJson())
	if err != nil {
		api.server.log.Warn("agent channel hook failed open", "card", caller.CardID, "error", err)
		return &dieterv1.ChannelHookResponse{}, nil
	}
	return &dieterv1.ChannelHookResponse{OutputJson: output}, nil
}

func (api *channelsAPI) GetChannelSettings(context.Context, *dieterv1.GetChannelSettingsRequest) (*dieterv1.ChannelSettings, error) {
	settings, err := api.server.app.ChannelSettings()
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoChannelSettings(settings), nil
}

func (api *channelsAPI) SetChannelSetting(ctx context.Context, r *dieterv1.SetChannelSettingRequest) (*dieterv1.ChannelSettings, error) {
	if requestHeader(ctx, turnTokenMetadata) != "" && requestHeader(ctx, operatorSubjectMetadata) == "" {
		return nil, fault.New(fault.PermissionDenied, "agents cannot change agent channel settings")
	}
	settings, err := api.server.app.SetChannelSetting(r.GetScope(), r.GetId(), r.GetValue())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoChannelSettings(settings), nil
}

func (api *channelsAPI) WatchChannel(ctx context.Context, r *dieterv1.WatchChannelRequest, stream *connect.ServerStream[dieterv1.ChannelFrame]) error {
	return api.server.watchChannel(ctx, r, stream.Send)
}

// watchChannel streams one project channel. The first frame resets with the
// newest page; later frames carry new messages, messages whose pins,
// deliveries or replies changed, and the claims and summary when they change.
func (s *Server) watchChannel(ctx context.Context, r *dieterv1.WatchChannelRequest, send func(*dieterv1.ChannelFrame) error) error {
	if s.channelWatches.Add(1) > maxChannelWatches {
		s.channelWatches.Add(-1)
		return fault.New(fault.ResourceExhausted, "too many channel subscriptions")
	}
	defer s.channelWatches.Add(-1)
	project, err := s.store.Kanban.ResolveProject(r.GetProjectId())
	if err != nil {
		return domainFailure(err)
	}
	heartbeat := defaultChangesBeat
	if beat := time.Duration(r.GetHeartbeatMs()) * time.Millisecond; beat >= time.Second {
		heartbeat = beat
	}
	wake := newChangeWait(s.store)
	defer wake.close()
	fingerprints := map[string]string{}
	lastSeq := r.GetAfterSeq()
	var lastClaims, lastSummary *dieterv1.ChannelFrame
	var summaryAt time.Time
	first := true
	for {
		frame := &dieterv1.ChannelFrame{Reset_: first}
		var window []model.ChannelMessage
		if first && lastSeq == 0 {
			window, frame.LastSeq, _, err = s.store.Channels.Page(project.ID, 0, 0, 50, "")
		} else {
			window, frame.LastSeq, _, err = s.store.Channels.Page(project.ID, max(0, lastSeq-channelWatchWindow), 0, channelWatchWindow+50, "")
		}
		if err != nil {
			return domainFailure(err)
		}
		for _, message := range window {
			fingerprint := channelFingerprint(message)
			fresh := first && r.GetAfterSeq() == 0
			changed := fingerprints[message.ID] != "" && fingerprints[message.ID] != fingerprint
			if message.Seq > lastSeq || fresh || changed {
				frame.Messages = append(frame.Messages, protoChannelMessage(message))
			}
			fingerprints[message.ID] = fingerprint
		}
		lastSeq = max(lastSeq, frame.LastSeq)
		claims := protoChannelClaims(s.app.ChannelClaims(project.ID))
		if first || lastClaims == nil || !proto.Equal(&dieterv1.ChannelFrame{Claims: claims.Claims}, lastClaims) {
			frame.Claims = claims.Claims
			lastClaims = &dieterv1.ChannelFrame{Claims: claims.Claims}
		}
		if first || time.Since(summaryAt) >= channelSummaryRefresh {
			summaryAt = time.Now()
			if summaries, err := s.app.ChannelSummaries(ctx); err == nil {
				for _, summary := range summaries {
					if summary.Project.ID != project.ID {
						continue
					}
					candidate := &dieterv1.ChannelFrame{Summary: protoChannelSummary(summary)}
					if first || lastSummary == nil || !proto.Equal(candidate, lastSummary) {
						frame.Summary, lastSummary = candidate.Summary, candidate
					}
				}
			}
		}
		if first || len(frame.Messages) > 0 || frame.Claims != nil || frame.Summary != nil {
			if err := send(frame); err != nil {
				return err
			}
		}
		first = false
		waitCtx, cancel := context.WithTimeout(ctx, heartbeat)
		err := wake.wait(waitCtx)
		cancel()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			if err := send(&dieterv1.ChannelFrame{Heartbeat: true, LastSeq: lastSeq}); err != nil {
				return err
			}
		}
	}
}

func channelFingerprint(message model.ChannelMessage) string {
	fingerprint := fmt.Sprintf("%t/%d", message.Pinned, message.ReplyCount)
	for _, delivery := range message.Deliveries {
		fingerprint += "/" + delivery.CardID + ":" + delivery.Mode + "@" + delivery.At
	}
	return fingerprint
}

func protoChannelAuthor(author model.ChannelAuthor) *dieterv1.ChannelAuthor {
	return &dieterv1.ChannelAuthor{Kind: author.Kind, CardId: author.CardID, Title: author.Title, Harness: author.Harness, Model: author.Model, DeviceId: author.DeviceID}
}

func protoChannelMessage(message model.ChannelMessage) *dieterv1.ChannelMessage {
	result := &dieterv1.ChannelMessage{
		Id: message.ID, ProjectId: message.ProjectID, Seq: message.Seq, ThreadId: message.ThreadID, Kind: message.Kind,
		Author: protoChannelAuthor(message.Author), ToCardIds: slices.Clone(message.To), Body: message.Body,
		Files: slices.Clone(message.Files), Pinned: message.Pinned, CreatedAt: message.CreatedAt, ReplyCount: int32(message.ReplyCount),
		OriginDaemonId: message.Origin, Here: message.Here,
	}
	for _, delivery := range message.Deliveries {
		result.Deliveries = append(result.Deliveries, &dieterv1.ChannelDelivery{CardId: delivery.CardID, Mode: delivery.Mode, At: delivery.At})
	}
	return result
}

func protoChannelPage(messages []model.ChannelMessage, last int64, more bool) *dieterv1.ChannelMessagePage {
	page := &dieterv1.ChannelMessagePage{LastSeq: last, HasMore: more}
	for _, message := range messages {
		page.Messages = append(page.Messages, protoChannelMessage(message))
	}
	return page
}

func protoChannelClaim(claim model.ChannelClaim) *dieterv1.ChannelClaim {
	return &dieterv1.ChannelClaim{ProjectId: claim.ProjectID, Path: claim.Path, CardId: claim.CardID, CardTitle: claim.CardTitle, Since: claim.Since, WaitingCardIds: slices.Clone(claim.Waiting), Parked: claim.Parked, DaemonId: claim.Daemon, Remote: claim.Remote}
}

func protoChannelClaims(claims []model.ChannelClaim) *dieterv1.ChannelClaims {
	result := &dieterv1.ChannelClaims{}
	for _, claim := range claims {
		result.Claims = append(result.Claims, protoChannelClaim(claim))
	}
	return result
}

func protoChannelSummary(summary engine.ChannelSummary) *dieterv1.ChannelSummary {
	result := &dieterv1.ChannelSummary{
		ProjectId: summary.Project.ID, ProjectName: summary.Project.Name, Enabled: summary.Enabled,
		LastSeq: summary.LastSeq, SeenSeq: summary.SeenSeq, Unread: int32(summary.Unread), Claims: int32(summary.Claims),
		LastMessageAt: summary.LastMessageAt,
	}
	for _, member := range summary.Members {
		result.Members = append(result.Members, &dieterv1.ChannelMember{
			CardId: member.Card.ID, Title: member.Card.Title, BoardId: member.Card.BoardID, Harness: member.Card.Provider,
			Model: member.Card.Model, Status: member.Status, Enabled: member.Enabled,
			Holds: slices.Clone(member.Holds), WaitingOn: slices.Clone(member.WaitingOn),
			DaemonId: member.Daemon, Remote: member.Remote,
		})
	}
	return result
}

func protoChannelSettings(settings model.ChannelSettings) *dieterv1.ChannelSettings {
	result := &dieterv1.ChannelSettings{Global: settings.Global}
	add := func(scope string, values map[string]bool) {
		ids := make([]string, 0, len(values))
		for id := range values {
			ids = append(ids, id)
		}
		slices.Sort(ids)
		for _, id := range ids {
			value := "off"
			if values[id] {
				value = "on"
			}
			result.Overrides = append(result.Overrides, &dieterv1.ChannelSettingOverride{Scope: scope, Id: id, Value: value})
		}
	}
	add("project", settings.Projects)
	add("board", settings.Boards)
	return result
}
