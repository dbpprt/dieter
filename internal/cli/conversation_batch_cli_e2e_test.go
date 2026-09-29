package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

const cliBatchPrompt = "stream-batching-regression-128-tokens"

func emitCLIBatch(request harness.Request, emit func(harness.Output) error) error {
	chunks := []string{`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`, `{"type":"text-start","id":"text"}`}
	for i := range 128 {
		chunks = append(chunks, fmt.Sprintf(`{"type":"text-delta","id":"text","delta":"%03d "}`, i))
	}
	chunks = append(chunks, `{"type":"text-end","id":"text"}`, `{"type":"finish","finishReason":"stop"}`)
	for _, chunk := range chunks {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"threadId":"batched-cli"}}`)})
}

func TestDaemonCLIBatchedConversationEndToEnd(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: initTestRepository(t, "batched"), Name: "Batched"})
	if err != nil {
		t.Fatal(err)
	}
	assertBatchedConversationCLI(t, client, output, data, project.ID)
}

// Shared by the local route test and the authenticated direct/relay fixture.
func assertBatchedConversationCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, projectID string) {
	t.Helper()
	card, err := data.CreateChat(store.CreateCardInput{Project: projectID, Title: "Batched stream", Provider: "codex", Model: "gpt-5.5", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	before, _, err := data.SyncEvents(0, 256)
	if err != nil {
		t.Fatal(err)
	}
	runDaemonCLI(t, client, output, "chat", "send", "--message", cliBatchPrompt, card.ID)
	deadline := time.Now().Add(15 * time.Second)
	var conversation model.Conversation
	for {
		conversation, err = data.Conversation(card.ID)
		stored, cardErr := data.ResolveCard(card.ID)
		leased, leaseErr := data.CardHasRuntimeLease(card.ID)
		if err == nil && cardErr == nil && leaseErr == nil && !leased && stored.Runtime == "idle" && conversation.Status == "idle" && len(conversation.Session) != 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("batched CLI turn did not finish: runtime=%s conversation=%s err=%v", stored.Runtime, conversation.Status, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := data.WaitForWriter(t.Context()); err != nil {
		t.Fatal(err)
	}
	var want strings.Builder
	for i := range 128 {
		fmt.Fprintf(&want, "%03d ", i)
	}
	reader := store.New(data.Root)
	defer reader.Close()
	conversation, err = reader.Conversation(card.ID)
	if err != nil || len(conversation.Messages) != 2 || conversation.Messages[1].Parts[0].Text != want.String() || !strings.Contains(string(conversation.Session), "batched-cli") {
		t.Fatalf("fresh store lost batched transcript/session: %+v %v", conversation, err)
	}
	raw := runDaemonCLI(t, client, output, "chat", "watch", "--count", "1", card.ID)
	var update dieterv1.ConversationUpdate
	if err := protojson.Unmarshal([]byte(raw), &update); err != nil {
		t.Fatal(err)
	}
	snapshot := update.GetSnapshot().GetConversation()
	if len(snapshot.GetMessages()) != 2 || snapshot.GetMessages()[1].GetParts()[0].GetText() != want.String() || snapshot.GetLastSeq() != conversation.LastSeq {
		t.Fatalf("wire snapshot lost batched output: %s", raw)
	}
	raw = runDaemonCLI(t, client, output, "chat", "watch", "--after-seq", strconv.FormatInt(conversation.LastSeq, 10), "--count", "1", card.ID)
	update.Reset()
	if err := protojson.Unmarshal([]byte(raw), &update); err != nil || update.GetSnapshot() != nil || len(update.GetChangedMessages()) != 0 || update.GetLastSeq() != conversation.LastSeq {
		t.Fatalf("watch resume replayed batched output: %s %v", raw, err)
	}
	after, _, err := data.SyncEvents(before.Sequence, 256)
	if err != nil || after.Sequence-before.Sequence >= 64 {
		t.Fatalf("128 tokens generated %d sync transactions: %v", after.Sequence-before.Sequence, err)
	}
	t.Logf("route=%s: 128 deltas, durable trailing session, watch and resume passed; %d total turn transactions", client.transport.route, after.Sequence-before.Sequence)
}
