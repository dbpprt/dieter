package main

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	boardstore "github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

// performanceStreamPrompt starts a turn that streams like a busy agent until
// the fixture stops: a text delta every 40 ms with a tool call between parts.
const performanceStreamPrompt = "performance-stream"

// performanceIdleChats give the account view a realistic size around the
// streaming chats: every projection walks all of them.
const performanceIdleChats = 200

// startPerformanceStreams starts DIETER_PERFORMANCE_STREAMS (a count) chats
// that stream without end among idle ones, so client CPU can be measured while
// agents work.
func startPerformanceStreams(ctx context.Context, client dieterclient.ConnectClient, data *boardstore.Store, project model.Project, count string) error {
	streams, err := strconv.Atoi(count)
	if err != nil || streams < 1 {
		return fmt.Errorf("DIETER_PERFORMANCE_STREAMS must be a positive count, not %q", count)
	}
	for index := range performanceIdleChats {
		if _, err := data.Kanban.CreateChat(kanban.CreateCardInput{
			Project: project.ID, Title: fmt.Sprintf("Idle chat %03d", index),
			Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject,
		}); err != nil {
			return err
		}
	}
	for index := range streams {
		card, err := data.Kanban.CreateChat(kanban.CreateCardInput{
			Project: project.ID, Title: fmt.Sprintf("Streaming agent %02d", index),
			Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject,
		})
		if err != nil {
			return err
		}
		if _, err = client.SendMessage(ctx, &dieterv1.SendMessageRequest{
			CardId: card.ID, Parts: []*dieterv1.MessagePart{{Type: "text", Text: performanceStreamPrompt}},
			Provider: "mock", Model: "mock", ClientId: "performance-fixture",
			CommandId: "performance-" + card.ID, MessageId: "msg_performance_" + card.ID,
		}); err != nil {
			return fmt.Errorf("start streaming chat %s: %w", card.ID, err)
		}
		fmt.Printf("DIETER_PERFORMANCE_STREAM_CARD=%s\n", card.ID)
	}
	return nil
}

func runPerformanceStream(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	return runShowcaseTurn(ctx, request, emit, func(s *showcaseStream) error {
		for step := 0; ; step++ {
			if err := s.streamPart("text", strings.Repeat("Streamed agent output keeps arriving. ", 36), 10*time.Millisecond); err != nil {
				return err
			}
			if err := s.shell(fmt.Sprintf("go test ./... # step %d", step), "ok", 500*time.Millisecond); err != nil {
				return err
			}
		}
	})
}
