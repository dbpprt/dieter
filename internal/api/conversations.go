package api

import (
	"context"
	"strings"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/commands"
	"github.com/dbpprt/dieter/internal/store/home"
)

func (api *conversationsAPI) PresentConversationContent(ctx context.Context, request *dieterv1.PresentConversationContentRequest) (*dieterv1.ContentPresentation, error) {
	value, err := api.server.app.PresentConversationContent(ctx, request.GetCardId(), "", model.ContentPresentation{
		Path: request.GetPath(), URL: request.GetUrl(), Line: int(request.GetLine()), Title: request.GetTitle(),
	})
	if err != nil {
		return nil, err
	}
	return protoContentPresentation(&value), nil
}

func (api *conversationsAPI) GetConversation(_ context.Context, request *dieterv1.GetConversationRequest) (*dieterv1.ConversationSnapshot, error) {
	value, err := api.server.conversationSnapshot(request.GetCardId(), int(request.GetLimit()), request.Before)
	if err != nil {
		return nil, err
	}
	return value, nil
}

func (api *conversationsAPI) PollConversation(_ context.Context, request *dieterv1.PollConversationRequest) (*dieterv1.ConversationUpdate, error) {
	snapshot, err := api.server.conversationSnapshot(request.GetCardId(), int(request.GetLimit()), nil)
	if err != nil {
		return nil, err
	}
	conversation := snapshot.GetConversation()
	if request.AfterSeq != nil && request.GetAfterSeq() == conversation.GetLastSeq() {
		return &dieterv1.ConversationUpdate{
			Status: conversation.GetStatus(), LastSeq: conversation.GetLastSeq(), UpdatedAt: conversation.GetUpdatedAt(),
		}, nil
	}
	if request.AfterSeq != nil {
		if previous := api.server.rememberedConversationSnapshot(request.GetCardId(), request.GetAfterSeq()); previous != nil {
			return conversationDelta(previous, snapshot), nil
		}
	}
	return &dieterv1.ConversationUpdate{Snapshot: snapshot}, nil
}

func (api *conversationsAPI) GetToolOutput(_ context.Context, request *dieterv1.GetToolOutputRequest) (*dieterv1.ToolOutput, error) {
	conversation, err := api.server.conversation(request.GetCardId())
	if err != nil {
		return nil, err
	}
	for _, message := range conversation.Messages {
		if message.ID != request.GetMessageId() {
			continue
		}
		for _, part := range message.Parts {
			if part.ToolCallID != request.GetToolCallId() || (part.Type != "dynamic-tool" && !strings.HasPrefix(part.Type, "tool-")) {
				continue
			}
			return &dieterv1.ToolOutput{
				CardId: conversation.CardID, MessageId: message.ID,
				ToolCallId: part.ToolCallID, ToolName: part.ToolName, State: part.State,
				InputJson: append([]byte(nil), part.Input...), OutputJson: append([]byte(nil), part.Output...),
				ErrorText: part.ErrorText, Revision: toolPayloadRevision(part),
			}, nil
		}
	}
	return nil, fault.Errorf(fault.NotFound, "tool call %q was not found in message %q", request.GetToolCallId(), request.GetMessageId())
}

func (api *conversationsAPI) WatchConversation(ctx context.Context, request *dieterv1.WatchConversationRequest, stream *connect.ServerStream[dieterv1.ConversationUpdate]) error {
	return api.server.watchConversation(ctx, request, stream.Send)
}

// SendMessage only uses the RPC context for admission. SubmitCardParts creates
// a daemon-owned turn context, so a client disconnect after this method returns
// never cancels an admitted agent turn.
func (api *conversationsAPI) SendMessage(_ context.Context, request *dieterv1.SendMessageRequest) (*dieterv1.SendMessageResponse, error) {
	parts, err := modelUserMessageParts(request.GetParts())
	if err != nil {
		return nil, err
	}
	clientID, commandID := strings.TrimSpace(request.GetClientId()), strings.TrimSpace(request.GetCommandId())
	if (clientID == "") != (commandID == "") {
		return nil, fault.New(fault.Invalid, "client_id and command_id must be supplied together")
	}
	if clientID == "" {
		queued, submitErr := api.server.app.SubmitCardParts(
			request.GetCardId(), parts, request.GetProvider(), request.GetModel(), request.GetEffort(), cloneProtoStringMap(request.GetProviderOptions()),
		)
		if submitErr != nil {
			return nil, sendMessageFailure(submitErr)
		}
		return &dieterv1.SendMessageResponse{Sent: !queued, Queued: queued}, nil
	}
	api.server.commandMu.Lock()
	defer api.server.commandMu.Unlock()
	if result, ok, loadErr := api.server.store.Commands.Load(clientID, commandID); loadErr != nil {
		return nil, loadErr
	} else if ok {
		if result.Kind != "send_message" {
			return nil, fault.New(fault.AlreadyExists, "command_id was already used for another operation")
		}
		return &dieterv1.SendMessageResponse{Sent: result.Sent, Queued: result.Queued, MessageId: result.MessageID}, nil
	}
	messageID := strings.TrimSpace(request.GetMessageId())
	if messageID == "" {
		messageID, err = commands.DeterministicID("msg_", clientID, commandID)
		if err != nil {
			return nil, err
		}
	}
	if len(messageID) > 200 || strings.ContainsAny(messageID, `/\\`) {
		return nil, fault.New(fault.Invalid, "message_id is invalid")
	}
	if conversation, conversationErr := api.server.store.Conversations.Get(request.GetCardId()); conversationErr == nil {
		for _, message := range conversation.Messages {
			if message.ID == messageID {
				result := commands.Result{Kind: "send_message", MessageID: messageID, Sent: true}
				if saveErr := api.server.store.Commands.Save(clientID, commandID, result); saveErr != nil {
					return nil, saveErr
				}
				return &dieterv1.SendMessageResponse{Sent: true, MessageId: messageID}, nil
			}
		}
		for _, queuedMessage := range conversation.Queue {
			if queuedMessage.ID == messageID {
				result := commands.Result{Kind: "send_message", MessageID: messageID, Queued: true}
				if saveErr := api.server.store.Commands.Save(clientID, commandID, result); saveErr != nil {
					return nil, saveErr
				}
				return &dieterv1.SendMessageResponse{Queued: true, MessageId: messageID}, nil
			}
		}
	}
	queued, err := api.server.app.SubmitCardPartsWithMessageID(
		request.GetCardId(), parts, request.GetProvider(), request.GetModel(), request.GetEffort(), cloneProtoStringMap(request.GetProviderOptions()),
		messageID,
	)
	if err != nil {
		return nil, sendMessageFailure(err)
	}
	result := commands.Result{Kind: "send_message", MessageID: messageID, Sent: !queued, Queued: queued}
	if err := api.server.store.Commands.Save(clientID, commandID, result); err != nil {
		return nil, err
	}
	return &dieterv1.SendMessageResponse{Sent: !queued, Queued: queued, MessageId: messageID}, nil
}

func (api *conversationsAPI) RemoveQueuedMessage(_ context.Context, request *dieterv1.RemoveQueuedMessageRequest) (*dieterv1.QueuedMessage, error) {
	removed, _, err := api.server.store.Conversations.RemoveQueuedMessage(request.GetCardId(), request.GetMessageId())
	if err != nil {
		return nil, err
	}
	return protoQueuedMessage(removed, api.server.previews), nil
}

func (api *conversationsAPI) MarkConversationRead(_ context.Context, request *dieterv1.MarkConversationReadRequest) (*dieterv1.Card, error) {
	card, err := api.server.store.Conversations.MarkRead(request.GetCardId(), request.GetResponseSeq())
	if err != nil {
		return nil, err
	}
	return protoCard(card), nil
}

func (api *conversationsAPI) UpdateConversationWorkspace(_ context.Context, request *dieterv1.UpdateConversationWorkspaceRequest) (*dieterv1.Card, error) {
	current, err := api.server.store.Kanban.ResolveCard(request.GetCardId())
	if err != nil {
		return nil, err
	}
	baseRemote := request.GetBaseRemote()
	if strings.TrimSpace(baseRemote) == "" {
		baseRemote = current.WorkspaceBaseRemote
	}
	remotePublishMode := request.GetRemotePublishMode()
	if strings.TrimSpace(remotePublishMode) == "" {
		remotePublishMode = current.RemotePublishMode
	}
	card, err := api.server.store.Kanban.UpdateCardWorkspaceSelection(
		request.GetCardId(), request.GetMode(), request.GetBranch(), request.GetBaseBranch(),
		baseRemote, remotePublishMode, false,
	)
	if err != nil {
		return nil, err
	}
	return protoCard(card), nil
}

// A quiet selected conversation must not repeatedly decode its card, copy its
// transcript, rebuild protobufs and serialize/hash the entire visible tail.
// The metadata revision covers read receipts, workspace, project and board metadata as
// well as peer commits; transcript revision also covers asynchronous checkpoints.
type conversationWatchRevision struct {
	metadata   home.Revision
	transcript string
}

func (s *Server) conversationWatchRevision(cardID string) (conversationWatchRevision, bool, error) {
	metadata, err := s.store.MetadataRevision()
	if err != nil {
		return conversationWatchRevision{}, false, err
	}
	transcript, err := s.store.Conversations.RevisionByID(cardID)
	return conversationWatchRevision{metadata, transcript}, s.store.SyncMutationPending(), err
}
