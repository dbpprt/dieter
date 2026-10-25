package main

import (
	"encoding/json"

	"github.com/dbpprt/dieter/internal/model"
	boardstore "github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

// seedChannelsFixture turns agent channels on for the account and seeds the
// project channel with the two-agent coordination of the Atrium pair: a
// request, Dieter's heads-up to the holder, the threaded "free" reply, the
// release, a pinned human decision and their delivery receipts. The agents'
// conversations show what reached them: the steered messages in the holder's
// turn, and the waiter's turn that the release woke.
func seedChannelsFixture(data *boardstore.Store, project model.Project, board model.Board) error {
	if err := data.KV.SetChannelSetting("global", "", "on"); err != nil {
		return err
	}
	holder, err := data.Kanban.CreateCard(kanban.CreateCardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning, Title: "Review headers of modules 3, 4, 6, 7",
		Prompt: "Append ' (reviewed)' to the header of modules 3, 4, 6 and 7, then commit them.", Provider: "claude-code", Model: "sonnet",
	})
	if err != nil {
		return err
	}
	waiter, err := data.Kanban.CreateCard(kanban.CreateCardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning, Title: "Add MAX_TIER_3 and module5 owner",
		Prompt: "Add MAX_TIER_3 to src/module3.js and an owner to src/module5.js, then commit.", Provider: "codex", Model: "gpt-6-astra",
	})
	if err != nil {
		return err
	}
	agent := func(card model.Card) model.ChannelAuthor {
		return model.ChannelAuthor{Kind: model.ChannelAuthorAgent, CardID: card.ID, Title: card.Title, Harness: card.Provider, Model: card.Model}
	}
	dieter := model.ChannelAuthor{Kind: model.ChannelAuthorDieter}
	post := func(message model.ChannelMessage) (model.ChannelMessage, error) {
		message.ProjectID = project.ID
		stored, _, err := data.Channels.Post(message, "")
		return stored, err
	}
	request, err := post(model.ChannelMessage{Kind: model.ChannelKindRequest, Author: agent(waiter), To: []string{holder.ID}, Files: []string{"src/module3.js"},
		Body: "I need to append MAX_TIER_3 to src/module3.js; please notify me when your changes are committed and the file is free. I will edit module5 first."})
	if err != nil {
		return err
	}
	headsUp, err := post(model.ChannelMessage{Kind: model.ChannelKindRequest, Author: dieter, To: []string{holder.ID}, Files: []string{"src/module3.js"},
		Body: "Agent " + waiter.ID + " ('" + waiter.Title + "') wants to change src/module3.js, which you are changing. Finish your work on it; Dieter releases it to them when your turn ends."})
	if err != nil {
		return err
	}
	reply, err := post(model.ChannelMessage{Kind: model.ChannelKindDone, Author: agent(holder), To: []string{waiter.ID}, ThreadID: request.ID, Files: []string{"src/module3.js"},
		Body: "My changes are committed (dedaa12), so src/module3.js is free for you to edit."})
	if err != nil {
		return err
	}
	release, err := post(model.ChannelMessage{Kind: model.ChannelKindRelease, Author: dieter, To: []string{waiter.ID}, Files: []string{"src/module3.js"},
		Body: "src/module3.js is free now: agent " + holder.ID + " ('" + holder.Title + "') finished its turn."})
	if err != nil {
		return err
	}
	decision, err := post(model.ChannelMessage{Kind: model.ChannelKindDecision, Author: model.ChannelAuthor{Kind: model.ChannelAuthorHuman},
		Body: "Tier caps live next to their rules in each module; no shared constants file."})
	if err != nil {
		return err
	}
	if _, err = data.Channels.Pin(project.ID, decision.ID, true); err != nil {
		return err
	}
	for _, delivery := range []struct {
		card, mode string
		ids        []string
	}{
		{holder.ID, model.ChannelDeliverySteered, []string{request.ID, headsUp.ID}},
		{waiter.ID, model.ChannelDeliveryWoke, []string{reply.ID, release.ID}},
	} {
		if err := data.Channels.Deliver(project.ID, delivery.card, delivery.mode, delivery.ids); err != nil {
			return err
		}
	}
	notice := func(message model.ChannelMessage) model.UIMessagePart {
		payload, _ := json.Marshal(map[string]any{
			"messageId": message.ID, "projectId": project.ID, "channel": project.Name, "kind": message.Kind,
			"author": message.Author, "direct": len(message.To) > 0, "files": message.Files, "createdAt": message.CreatedAt,
		})
		return model.UIMessagePart{Type: "data-peer-notice", Text: message.Body, Data: payload}
	}
	text := func(value string) model.UIMessagePart { return model.UIMessagePart{Type: "text", Text: value} }
	conversations := map[string][]model.UIMessage{
		holder.ID: {
			{ID: "channels-holder-prompt", Role: "user", Parts: []model.UIMessagePart{text(holder.InitialPrompt)}},
			{ID: "channels-holder-turn", Role: "assistant", Parts: []model.UIMessagePart{
				text("I'll append the review marker to the four module headers."),
				notice(request), notice(headsUp),
				text("Agent " + waiter.ID + " is waiting for src/module3.js, so I'll commit it first and tell them when it is free."),
			}},
		},
		waiter.ID: {
			{ID: "channels-waiter-prompt", Role: "user", Parts: []model.UIMessagePart{text(waiter.InitialPrompt)}},
			{ID: "channels-waiter-turn", Role: "assistant", Parts: []model.UIMessagePart{text("src/module3.js is held by another agent, so I edited module5 first and asked them to tell me when it is free.")}},
			{ID: model.ChannelWakeMessagePrefix + "fixture", Role: "user", Parts: []model.UIMessagePart{text(release.Body)}},
			{ID: "channels-waiter-woken", Role: "assistant", Parts: []model.UIMessagePart{text("Added MAX_TIER_3 to src/module3.js and committed it.")}},
		},
	}
	for cardID, messages := range conversations {
		if _, err := data.Conversations.InitializeFork(cardID, messages); err != nil {
			return err
		}
	}
	return nil
}
