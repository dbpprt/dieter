package api

import (
	"context"
	"strings"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/commands"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *cardsAPI) ListArchivedCards(_ context.Context, request *dieterv1.BoardRef) (*dieterv1.CardsResponse, error) {
	board, err := api.server.store.Kanban.ResolveBoard("", request.GetBoardId())
	if err != nil {
		return nil, err
	}
	values, err := api.server.store.Kanban.ListCards(kanban.CardFilter{
		Board: board.ID, Scope: model.ConversationScopeBoard, IncludeArchived: true,
	})
	if err != nil {
		return nil, err
	}
	result := &dieterv1.CardsResponse{}
	for _, value := range values {
		if value.Archived {
			result.Cards = append(result.Cards, protoCard(value))
		}
	}
	return result, nil
}

func (api *cardsAPI) CreateCard(ctx context.Context, request *dieterv1.CreateConversationRequest) (*dieterv1.Card, error) {
	return api.server.idempotentConversation(ctx, request, model.ConversationScopeBoard)
}

func (api *cardsAPI) CreateChat(ctx context.Context, request *dieterv1.CreateConversationRequest) (*dieterv1.Card, error) {
	return api.server.idempotentConversation(ctx, request, model.ConversationScopeChat)
}

func (api *cardsAPI) ForkChat(_ context.Context, request *dieterv1.ForkChatRequest) (*dieterv1.Card, error) {
	value, err := api.server.app.ForkChat(request.GetSourceCardId(), request.GetMessageId(), request.GetTitle())
	if err != nil {
		return nil, err
	}
	return protoCard(value), nil
}

func (api *cardsAPI) ListChats(_ context.Context, request *dieterv1.ListChatsRequest) (*dieterv1.ChatsResponse, error) {
	projects, err := api.server.store.Kanban.ListProjects()
	if err != nil {
		return nil, err
	}
	chats, err := api.server.store.Kanban.ListCards(kanban.CardFilter{
		Scope: model.ConversationScopeChat, IncludeArchived: request.GetIncludeArchived(),
	})
	if err != nil {
		return nil, err
	}
	result := &dieterv1.ChatsResponse{}
	for _, value := range projects {
		result.Projects = append(result.Projects, protoProject(value))
	}
	for _, value := range chats {
		chat := protoCard(value)
		if model.RuntimeHoldsTurn(value.Runtime) {
			conversation, conversationErr := api.server.conversation(value.ID)
			if conversationErr != nil {
				return nil, conversationErr
			}
			for _, subagent := range conversation.Subagents {
				if subagent.Status == "running" || subagent.Status == "pending" {
					chat.ActiveSubagents = append(chat.ActiveSubagents, protoSubagent(subagent))
				}
			}
		}
		result.Chats = append(result.Chats, chat)
	}
	return result, nil
}

func (api *cardsAPI) GetCard(_ context.Context, request *dieterv1.GetCardRequest) (*dieterv1.CardDetail, error) {
	value, err := api.server.store.Kanban.CardDetail(request.GetCardId())
	if err != nil {
		return nil, err
	}
	return protoCardDetail(value), nil
}

func (api *cardsAPI) MoveCard(_ context.Context, request *dieterv1.MoveCardRequest) (*dieterv1.Card, error) {
	before, err := api.server.store.Kanban.ResolveCard(request.GetCardId())
	if err != nil {
		return nil, err
	}
	if request.GetLane() == model.LaneRunning && before.InitialPromptSentAt == "" {
		if err = api.server.store.Kanban.RequireLocalCard(before); err != nil {
			return nil, err
		}
	}
	value, err := api.server.store.Kanban.MoveCardBetween(before.ID, request.GetLane(), request.GetAfterCardId(), request.GetBeforeCardId(), request.GetExpectedRevision())
	if err != nil {
		return nil, err
	}
	if value.Lane == model.LaneRunning && value.InitialPromptSentAt == "" {
		updates, startErr := api.server.app.StartCard(value.ID, "", value.Provider, value.Model, "")
		if startErr != nil {
			_, _ = api.server.store.Kanban.MoveCard(value.ID, before.Lane, nil)
			return nil, startErr
		}
		go drainUpdates(updates)
		// StartCard durably updates the runtime and initial prompt marker before
		// returning. Resolve again so MoveCard callers never receive the
		// stale "running lane / idle runtime" projection.
		value, _ = api.server.store.Kanban.ResolveCard(value.ID)
	}
	if value.Lane == model.LaneDone {
		if _, err := api.server.store.Kanban.ArchiveDoneCards(time.Now()); err != nil {
			return nil, err
		}
		value, _ = api.server.store.Kanban.ResolveCard(value.ID)
	}
	return protoCard(value), nil
}

func (api *cardsAPI) StartCard(_ context.Context, request *dieterv1.StartCardRequest) (*dieterv1.StartCardResponse, error) {
	clientID, commandID := strings.TrimSpace(request.GetClientId()), strings.TrimSpace(request.GetCommandId())
	if clientID == "" || commandID == "" {
		return nil, fault.New(fault.Invalid, "client_id and command_id are required")
	}
	api.server.commandMu.Lock()
	defer api.server.commandMu.Unlock()
	if result, ok, err := api.server.store.Commands.Load(clientID, commandID); err != nil {
		return nil, err
	} else if ok {
		if result.Kind != "start_card" || result.CardID != request.GetCardId() {
			return nil, fault.New(fault.AlreadyExists, "command_id was already used for another operation")
		}
		card, resolveErr := api.server.store.Kanban.ResolveCard(result.CardID)
		if resolveErr != nil {
			return nil, resolveErr
		}
		return &dieterv1.StartCardResponse{Card: protoCard(card), Accepted: true, Replayed: true, CommandId: commandID}, nil
	}

	card, err := api.server.store.Kanban.ResolveCard(request.GetCardId())
	if err != nil {
		return nil, err
	}
	if card.Scope != model.ConversationScopeBoard {
		return nil, fault.New(fault.FailedPrecondition, "only board cards can be started")
	}
	if card.InitialPromptSentAt != "" {
		if model.RuntimeHoldsTurn(card.Runtime) {
			if saveErr := api.server.store.Commands.Save(clientID, commandID, commands.Result{Kind: "start_card", CardID: card.ID}); saveErr != nil {
				return nil, saveErr
			}
			return &dieterv1.StartCardResponse{Card: protoCard(card), Accepted: true, AlreadyRunning: true, CommandId: commandID}, nil
		}
		return nil, fault.New(fault.FailedPrecondition, "card has already been started; send a message to resume its conversation")
	}

	updates, err := api.server.app.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
	if err != nil {
		return nil, err
	}
	go drainUpdates(updates)
	fresh, err := api.server.store.Kanban.ResolveCard(card.ID)
	if err != nil {
		return nil, err
	}
	if err := api.server.store.Commands.Save(clientID, commandID, commands.Result{Kind: "start_card", CardID: fresh.ID}); err != nil {
		return nil, err
	}
	return &dieterv1.StartCardResponse{Card: protoCard(fresh), Accepted: true, CommandId: commandID}, nil
}

func (api *cardsAPI) SetCardLabels(_ context.Context, request *dieterv1.SetCardLabelsRequest) (*dieterv1.Card, error) {
	value, err := api.server.store.Kanban.SetCardLabels(request.GetCardId(), request.GetLabelIds())
	if err != nil {
		return nil, err
	}
	return protoCard(value), nil
}

func (api *cardsAPI) CancelCard(_ context.Context, request *dieterv1.GetCardRequest) (*emptypb.Empty, error) {
	if err := api.server.app.CancelCard(request.GetCardId()); err != nil {
		return nil, err
	}
	return &emptypb.Empty{}, nil
}

func (api *cardsAPI) RenameCard(_ context.Context, request *dieterv1.RenameCardRequest) (*dieterv1.Card, error) {
	value, err := api.server.store.Kanban.RenameCard(request.GetCardId(), request.GetTitle())
	if err != nil {
		return nil, err
	}
	return protoCard(value), nil
}

func (api *cardsAPI) MergeCard(_ context.Context, request *dieterv1.MergeCardRequest) (*dieterv1.Card, error) {
	value, err := api.server.app.MergeCard(request.GetCardId(), request.GetTargetCardId())
	if err != nil {
		return nil, err
	}
	return protoCard(value), nil
}

func (api *cardsAPI) UpdateCard(_ context.Context, request *dieterv1.UpdateCardRequest) (*dieterv1.Card, error) {
	var settings []kanban.DraftAgentSettings
	if config := request.GetAgentSettings(); config != nil {
		provider := config.GetProvider()
		if provider == "" {
			provider = "codex"
		}
		adapter, selected, err := api.server.app.Catalog.ResolveSelection(provider, config.GetModel())
		if err != nil {
			return nil, err
		}
		effort := config.GetEffort()
		if effort == "" {
			effort = selected.DefaultEffort
		}
		effort, err = harness.ResolveEffort(adapter, selected, effort)
		if err != nil {
			return nil, err
		}
		options, err := harness.ResolveOptionsForModel(adapter, selected.ID, config.GetProviderOptions())
		if err != nil {
			return nil, err
		}
		settings = append(settings, kanban.DraftAgentSettings{Provider: adapter.ID, Model: selected.ID, Effort: effort, ProviderOptions: options})
	}
	value, err := api.server.store.Kanban.UpdateCard(request.GetCardId(), request.GetTitle(), request.GetInitialPrompt(), settings...)
	if err != nil {
		return nil, err
	}
	return protoCard(value), nil
}

func (api *cardsAPI) ArchiveCard(_ context.Context, request *dieterv1.ArchiveCardRequest) (*dieterv1.Card, error) {
	value, err := api.server.store.Kanban.ArchiveCard(request.GetCardId(), request.GetArchived())
	if err != nil {
		return nil, err
	}
	return protoCard(value), nil
}

func (api *cardsAPI) PinChat(_ context.Context, request *dieterv1.PinChatRequest) (*dieterv1.Card, error) {
	value, err := api.server.store.Kanban.PinChat(request.GetCardId(), request.GetPinned())
	if err != nil {
		return nil, err
	}
	return protoCard(value), nil
}
