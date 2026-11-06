package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
)

const remoteDaemon = "d_remote"

func isFault(err error, kind fault.Kind) bool {
	got, ok := fault.KindOf(err)
	return ok && got == kind
}

// remoteMessage is a message another daemon published into its ring.
func remoteMessage(projectID string, seq int64, body string, to ...string) schema.ChannelRecord {
	return schema.ChannelRecord{
		ID: fmt.Sprintf("m_remote%d", seq), ProjectID: projectID, Origin: remoteDaemon, OriginSeq: seq, Kind: "note",
		Author: schema.ChannelAuthor{Kind: "agent", CardID: "c_remote", Title: "Remote agent", Harness: "codex"},
		To:     to, Body: body, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
}

func publishRemote(t *testing.T, service *Service, namespace, key string, value any) {
	t.Helper()
	if err := service.Store.KV.PutChannel(namespace, key, value); err != nil {
		t.Fatal(err)
	}
}

func publishRemoteMessage(t *testing.T, service *Service, record schema.ChannelRecord) {
	t.Helper()
	publishRemote(t, service, schema.ChannelNamespace, schema.ChannelKey(record.ProjectID, record.Origin, record.OriginSeq), record)
}

func TestMessagesFromAnotherMachineReachTheirRecipientsHere(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	enableChannels(t, service)
	card := channelCard(t, service, project, board, "Checkout tests")
	startChannelTurn(t, service, card, "hold while testing")
	waitFor(t, func() bool { return service.turnHasChannelFor(card.ID) })

	post := remoteMessage(project.ID, 1, "FYI the fixtures moved to testdata/.")
	direct := remoteMessage(project.ID, 2, "Please leave go.mod to me, KIWI-3.", card.ID)
	publishRemoteMessage(t, service, post)
	publishRemoteMessage(t, service, direct)
	service.SyncChannels()

	// The direct message interrupts the running turn; the channel post waits.
	text := waitSteer(t, runner, "KIWI-3")
	if strings.Contains(text, "fixtures moved") || !strings.Contains(text, `from="agent c_remote 'Remote agent'"`) {
		t.Fatalf("steer text = %q", text)
	}
	stored, err := service.Store.Channels.Message(project.ID, direct.ID)
	if err != nil || stored.Origin != remoteDaemon || stored.OriginSeq != 2 {
		t.Fatalf("ingested direct = %+v, %v", stored, err)
	}
	waitFor(t, func() bool {
		message, _ := service.Store.Channels.Message(project.ID, direct.ID)
		return len(message.Deliveries) == 1 && message.Deliveries[0].Mode == model.ChannelDeliverySteered
	})

	// The owner publishes the receipt, so the sender's machine sees how it arrived.
	service.SyncChannels()
	var receipt schema.ChannelReceiptRecord
	_ = service.Store.KV.EachChannel(schema.ChannelReceiptNamespace, card.ID, func(key, _ string, value []byte) error {
		if key == card.ID {
			receipt, err = schema.DecodeChannelReceipt(key, value)
		}
		return nil
	})
	if err != nil || len(receipt.Deliveries) != 1 || receipt.Deliveries[0].Message != direct.ID || receipt.Deliveries[0].Mode != model.ChannelDeliverySteered || receipt.Daemon != service.channelOrigin() {
		t.Fatalf("receipt = %+v, %v", receipt, err)
	}

	// Ingesting again changes nothing, and the next turn reads the post.
	service.SyncChannels()
	page, _, _, err := service.Store.Channels.Page(project.ID, 0, 0, 50, "")
	if err != nil || len(page) != 2 {
		t.Fatalf("channel = %d messages, %v", len(page), err)
	}
	close(runner.hold(card.ID))
	waitIdle(t, service, card.ID)
	if _, err := service.SubmitCard(card.ID, "next step", "", "", ""); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return len(runner.turns(card.ID)) == 2 })
	if prompt := runner.turns(card.ID)[1].Prompt; !strings.Contains(prompt, "fixtures moved") || strings.Contains(prompt, "KIWI-3") {
		t.Fatalf("next prompt = %q, want the post's digest only", prompt)
	}
	waitIdle(t, service, card.ID)
}

func TestMessagesPostedHereReplicateIntoTheOriginRing(t *testing.T) {
	t.Parallel()
	service, _, project, board := channelSetup(t)
	enableChannels(t, service)
	card := channelCard(t, service, project, board, "Recipient")
	posted, err := service.PostChannelMessage(context.Background(), ChannelCaller{DeviceID: "dv_1"}, ChannelPost{ProjectID: project.ID, To: []string{card.ID}, Body: "Ship it.", Kind: "decision"})
	if err != nil {
		t.Fatal(err)
	}
	origin := service.channelOrigin()
	if posted.Origin != origin || posted.OriginSeq != 1 {
		t.Fatalf("posted = %+v", posted)
	}
	var record schema.ChannelRecord
	_ = service.Store.KV.EachChannel(schema.ChannelNamespace, project.ID+".", func(key, _ string, value []byte) error {
		record, err = schema.DecodeChannelRecord(key, value)
		return err
	})
	if err != nil || record.ID != posted.ID || record.Body != "Ship it." || record.Author.Kind != model.ChannelAuthorHuman || len(record.To) != 1 {
		t.Fatalf("replicated record = %+v, %v", record, err)
	}
	// The decision's pin is published as this daemon's pin change.
	service.SyncChannels()
	var pins schema.ChannelPinsRecord
	_ = service.Store.KV.EachChannel(schema.ChannelPinsNamespace, schema.ChannelScopeKey(project.ID, origin), func(key, _ string, value []byte) error {
		pins, err = schema.DecodeChannelPins(key, value)
		return err
	})
	if err != nil || len(pins.Pins) != 1 || pins.Pins[0].Message != posted.ID || !pins.Pins[0].Pinned {
		t.Fatalf("pins = %+v, %v", pins, err)
	}
	// A daemon never ingests its own records.
	service.SyncChannels()
	if page, _, _, _ := service.Store.Channels.Page(project.ID, 0, 0, 50, ""); len(page) != 1 {
		t.Fatalf("own record ingested again: %d messages", len(page))
	}
}

func TestAWakeFromAnotherMachineStartsAnIdleRecipient(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	enableChannels(t, service)
	card := channelCard(t, service, project, board, "Idle")
	record := remoteMessage(project.ID, 1, "Your file is free now.", card.ID)
	record.Wake = true
	publishRemoteMessage(t, service, record)
	service.SyncChannels()
	waitFor(t, func() bool { return len(runner.turns(card.ID)) == 1 })
	if prompt := runner.turns(card.ID)[0].Prompt; !strings.Contains(prompt, "Your file is free now.") || !strings.Contains(prompt, "woke you") {
		t.Fatalf("wake prompt = %q", prompt)
	}
	waitIdle(t, service, card.ID)
}

func TestPinsAndReceiptsFromAnotherMachineApply(t *testing.T) {
	t.Parallel()
	service, _, project, _ := channelSetup(t)
	enableChannels(t, service)
	posted, err := service.PostChannelMessage(context.Background(), ChannelCaller{}, ChannelPost{ProjectID: project.ID, Body: "Use testdata/ for fixtures."})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	publishRemote(t, service, schema.ChannelPinsNamespace, schema.ChannelScopeKey(project.ID, remoteDaemon), schema.ChannelPinsRecord{Pins: []schema.ChannelPinEntry{{Message: posted.ID, Pinned: true, At: now}}})
	publishRemote(t, service, schema.ChannelReceiptNamespace, "c_remote", schema.ChannelReceiptRecord{ProjectID: project.ID, Daemon: remoteDaemon, Deliveries: []schema.ChannelDeliveryEntry{{Message: posted.ID, Mode: "digest", At: now}}})
	service.SyncChannels()
	message, err := service.Store.Channels.Message(project.ID, posted.ID)
	if err != nil || !message.Pinned || len(message.Deliveries) != 1 || message.Deliveries[0].CardID != "c_remote" || message.Deliveries[0].Mode != "digest" {
		t.Fatalf("message = %+v, %v", message, err)
	}
	// An older pin change does not override a newer one.
	if _, err := service.PinChannelMessage(project.ID, posted.ID, false); err != nil {
		t.Fatal(err)
	}
	service.SyncChannels()
	if message, _ := service.Store.Channels.Message(project.ID, posted.ID); message.Pinned {
		t.Fatal("an older remote pin overrode the newer local unpin")
	}
}

func TestClaimsOnAnotherMachineAreAdvisory(t *testing.T) {
	t.Parallel()
	service, _, project, board := channelSetup(t)
	enableChannels(t, service)
	card := channelCard(t, service, project, board, "Local")
	fresh := schema.ChannelClaimsRecord{At: time.Now().UTC().Format(time.RFC3339Nano), Claims: []schema.ChannelClaimEntry{{Path: "src/a.go", CardID: "c_remote", CardTitle: "Remote agent", Since: time.Now().UTC().Format(time.RFC3339Nano)}}}
	publishRemote(t, service, schema.ChannelClaimsNamespace, schema.ChannelScopeKey(project.ID, remoteDaemon), fresh)
	check, err := service.CheckChannelFiles(ChannelCaller{}, card.ID, []string{"src/a.go"}, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(check.Conflicts) != 0 || len(check.Elsewhere) != 1 || !check.Elsewhere[0].Remote || !strings.Contains(check.Summary, "on machine "+remoteDaemon) {
		t.Fatalf("check = %+v", check)
	}
	claims := service.ChannelClaims(project.ID)
	if len(claims) != 1 || !claims[0].Remote || claims[0].Daemon != remoteDaemon {
		t.Fatalf("claims = %+v", claims)
	}
	stale := fresh
	stale.At = time.Now().Add(-channelClaimsStale - time.Minute).UTC().Format(time.RFC3339Nano)
	publishRemote(t, service, schema.ChannelClaimsNamespace, schema.ChannelScopeKey(project.ID, remoteDaemon), stale)
	if claims := service.ChannelClaims(project.ID); len(claims) != 0 {
		t.Fatalf("stale remote claims shown: %+v", claims)
	}
}

func TestLocalClaimsArePublishedForOtherMachines(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	enableChannels(t, service)
	card := channelCard(t, service, project, board, "Writer")
	startChannelTurn(t, service, card, "hold write:src/claimed.go")
	waitFor(t, func() bool { return len(service.localChannelClaims(project.ID)) == 1 })
	service.SyncChannels()
	key := schema.ChannelScopeKey(project.ID, service.channelOrigin())
	var record schema.ChannelClaimsRecord
	read := func() {
		record = schema.ChannelClaimsRecord{}
		_ = service.Store.KV.EachChannel(schema.ChannelClaimsNamespace, key, func(k string, _ string, value []byte) error {
			if k == key {
				_ = json.Unmarshal(value, &record)
			}
			return nil
		})
	}
	read()
	if len(record.Claims) != 1 || record.Claims[0].Path != "src/claimed.go" || record.Claims[0].CardID != card.ID {
		t.Fatalf("published claims = %+v", record)
	}
	close(runner.hold(card.ID))
	waitIdle(t, service, card.ID)
	waitFor(t, func() bool { return len(service.localChannelClaims(project.ID)) == 0 })
	service.SyncChannels()
	read()
	if len(record.Claims) != 0 {
		t.Fatalf("released claims still published: %+v", record)
	}
}

func TestDigestsCarryDirectMessagesAndRecentPostsOnly(t *testing.T) {
	t.Parallel()
	now := time.Now()
	old := now.Add(-channelDigestWindow - time.Hour).UTC().Format(time.RFC3339Nano)
	recent := now.Add(-time.Hour).UTC().Format(time.RFC3339Nano)
	for name, test := range map[string]struct {
		message model.ChannelMessage
		want    bool
	}{
		"recent post":  {model.ChannelMessage{CreatedAt: recent}, true},
		"old post":     {model.ChannelMessage{CreatedAt: old}, false},
		"old direct":   {model.ChannelMessage{CreatedAt: old, To: []string{"c_me"}}, true},
		"here":         {model.ChannelMessage{CreatedAt: recent, Here: true}, false},
		"other direct": {model.ChannelMessage{CreatedAt: recent, To: []string{"c_other"}}, true},
	} {
		if got := digestible(test.message, "c_me", now); got != test.want {
			t.Errorf("%s: digestible = %t, want %t", name, got, test.want)
		}
	}
	if steerable(model.ChannelMessage{}, "c_me") || !steerable(model.ChannelMessage{Here: true}, "c_me") || !steerable(model.ChannelMessage{To: []string{"c_me"}}, "c_me") {
		t.Fatal("only direct messages and @here interrupt a turn")
	}
}

func TestHereReachesOnlyRunningTurns(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	enableChannels(t, service)
	busy, idle := channelCard(t, service, project, board, "Busy"), channelCard(t, service, project, board, "Idle")
	startChannelTurn(t, service, busy, "hold while testing")
	waitFor(t, func() bool { return service.turnHasChannelFor(busy.ID) })
	if _, err := service.PostChannelMessage(context.Background(), ChannelCaller{CardID: busy.ID}, ChannelPost{Here: true, Body: "Everyone stop."}); !isFault(err, fault.PermissionDenied) {
		t.Fatalf("an agent's @here = %v", err)
	}
	if _, err := service.PostChannelMessage(context.Background(), ChannelCaller{}, ChannelPost{ProjectID: project.ID, Here: true, Body: "Stop pushing to main, MANGO-7."}); err != nil {
		t.Fatal(err)
	}
	waitSteer(t, runner, "MANGO-7")
	if pending, err := service.ChannelInbox(ChannelCaller{}, idle.ID, true); err != nil || len(pending) != 0 {
		t.Fatalf("idle inbox = %+v, %v", pending, err)
	}
	close(runner.hold(busy.ID))
	waitIdle(t, service, busy.ID)
}

func TestReceiptsAndPinsThatArriveBeforeTheirMessageApplyOnceItDoes(t *testing.T) {
	t.Parallel()
	service, _, project, _ := channelSetup(t)
	enableChannels(t, service)
	record := remoteMessage(project.ID, 1, "Tier caps live next to their rules.")
	now := time.Now().UTC().Format(time.RFC3339Nano)
	publishRemote(t, service, schema.ChannelReceiptNamespace, "c_remote", schema.ChannelReceiptRecord{ProjectID: project.ID, Daemon: remoteDaemon, Deliveries: []schema.ChannelDeliveryEntry{{Message: record.ID, Mode: "steered", At: now}}})
	publishRemote(t, service, schema.ChannelPinsNamespace, schema.ChannelScopeKey(project.ID, remoteDaemon), schema.ChannelPinsRecord{Pins: []schema.ChannelPinEntry{{Message: record.ID, Pinned: true, At: now}}})
	service.SyncChannels()
	if service.Store.Channels.Has(project.ID, record.ID) {
		t.Fatal("the message arrived early")
	}
	publishRemoteMessage(t, service, record)
	service.SyncChannels()
	message, err := service.Store.Channels.Message(project.ID, record.ID)
	if err != nil || !message.Pinned || len(message.Deliveries) != 1 || message.Deliveries[0].Mode != model.ChannelDeliverySteered {
		t.Fatalf("message = %+v, %v", message, err)
	}
}
