package cli

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"
	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/model"
)

const daemonCardSendTimeout = 5 * time.Second

// sendCardThroughDaemon admits the turn through the long-lived daemon whenever
// this store has a current daemon heartbeat. The daemon deliberately owns the
// agent lifecycle after SendMessage returns, so the invoking CLI (or a parent
// tool session) can exit without interrupting the turn.
//
// Once a current daemon is observed, an RPC failure is returned instead of
// falling back to an in-process worker. The request may have reached the daemon
// before the client observed the failure; a fallback could start the same turn
// twice under separate process owners.
func (c *CLI) sendCardThroughDaemon(ctx context.Context, cardID string, parts []model.UIMessagePart, provider, modelName, effort string) (submitted, queued bool, err error) {
	status, err := dieterdaemon.LoadRuntimeStatus(c.Store.Root)
	if dieterdaemon.IsRuntimeStatusMissing(err) {
		return false, false, nil
	}
	if err != nil {
		return false, false, fmt.Errorf("read Dieter daemon status: %w", err)
	}
	if !dieterdaemon.RuntimeStatusCurrent(status, time.Now().UTC()) {
		return false, false, nil
	}
	address := strings.TrimSpace(status.ListenAddress)
	if address == "" {
		return true, false, errors.New("running Dieter daemon has no local API address")
	}
	commandID, err := newCLICardCommandID()
	if err != nil {
		return true, false, err
	}
	request := &dieterv1.SendMessageRequest{
		CardId: cardID, Provider: provider, Model: modelName, Effort: effort,
		ClientId: "dieter-cli", CommandId: commandID,
	}
	for _, part := range parts {
		request.Parts = append(request.Parts, &dieterv1.MessagePart{
			Type: part.Type, Text: part.Text, MediaType: part.MediaType,
			Filename: part.Filename, Url: part.URL,
		})
	}
	requestCtx, cancel := context.WithTimeout(ctx, daemonCardSendTimeout)
	defer cancel()
	client := dieterv1connect.NewDieterServiceClient(http.DefaultClient, "http://"+address)
	response, err := client.SendMessage(requestCtx, connect.NewRequest(request))
	if err != nil {
		return true, false, fmt.Errorf("submit card turn to running Dieter daemon at %s: %w", address, err)
	}
	return true, response.Msg.GetQueued(), nil
}

func newCLICardCommandID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", fmt.Errorf("create card command ID: %w", err)
	}
	return "cmd_" + hex.EncodeToString(value[:]), nil
}
