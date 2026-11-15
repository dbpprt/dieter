package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dbpprt/dieter/internal/engine/accounts"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/kv"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

const providerTestDaemon = "dm_provider_api"

// newProviderAccountsClient serves the API over an enrolled store whose
// accounts engine signs in through the in-process fixture backend.
func newProviderAccountsClient(t *testing.T, runner harness.Runner) (dieterclient.ConnectClient, *store.Store) {
	t.Helper()
	data := testkit.PeerStore(t, providerTestDaemon)
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	fixture := accounts.NewFixtureBackend()
	fixture.DeviceApproval = 50 * time.Millisecond
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	service, err := accounts.New(accounts.Options{Store: data, Backend: fixture, Logger: logger, MachineName: func() string { return "desk" }})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Shutdown)
	if runner == nil {
		runner = &testkit.FakeRunner{}
	}
	application := NewWithOptions(data, logger, Options{Runner: runner, Catalog: testkit.MockCatalog(), Accounts: service})
	server := testkit.HTTPServer(application.Handler())
	t.Cleanup(server.Close)
	return dieterclient.NewConnect(localHTTPClient(server.Client(), data.Root), server.URL), data
}

func createProviderAccount(t *testing.T, client dieterclient.ConnectClient, provider dieterv1.ProviderKind, label string, method dieterv1.ProviderLoginMethod) *dieterv1.ProviderAccount {
	t.Helper()
	account, err := client.CreateProviderAccount(t.Context(), &dieterv1.CreateProviderAccountRequest{Provider: provider, Label: label, Method: method})
	if err != nil {
		t.Fatal(err)
	}
	return account
}

// watchProviderLogin streams a sign-in until it ends and returns every state.
func watchProviderLogin(t *testing.T, client dieterclient.ConnectClient, loginID string) []*dieterv1.ProviderLogin {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(20*time.Second))
	defer cancel()
	stream, err := client.WatchProviderLogin(ctx, &dieterv1.WatchProviderLoginRequest{LoginId: loginID, HeartbeatSeconds: 1})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	var states []*dieterv1.ProviderLogin
	for stream.Receive() {
		states = append(states, stream.Msg())
		switch stream.Msg().GetPhase() {
		case dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_SUCCEEDED, dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_FAILED, dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_CANCELED:
			// The stream ends after a terminal state; read it to the end.
		}
	}
	if err := stream.Err(); err != nil {
		t.Fatalf("watch %s: %v", loginID, err)
	}
	if len(states) == 0 {
		t.Fatalf("watch %s emitted nothing", loginID)
	}
	return states
}

func lastPhase(states []*dieterv1.ProviderLogin) dieterv1.ProviderLoginPhase {
	return states[len(states)-1].GetPhase()
}

func machineLogin(account *dieterv1.ProviderAccount, daemonID string) *dieterv1.ProviderMachineLogin {
	for _, login := range account.GetLogins() {
		if login.GetDaemonId() == daemonID {
			return login
		}
	}
	return nil
}

func TestProviderAccountRPCsManageAccountsAndDefaults(t *testing.T) {
	t.Parallel()
	client, _ := newProviderAccountsClient(t, nil)
	ctx := t.Context()

	work := createProviderAccount(t, client, dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, " Work ", dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_UNSPECIFIED)
	if !strings.HasPrefix(work.GetId(), "pa_") || work.GetLabel() != "Work" || work.GetMethod() != dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CLAUDE_CODE ||
		!work.GetIsDefault() || !work.GetIncludeInSummary() || work.GetCreatedBy() != providerTestDaemon || len(work.GetLogins()) != 0 {
		t.Fatalf("first Claude account = %v", work)
	}
	// A retry with the same ID is idempotent; a different record under it is not.
	const sideID = "pa_sideaccountsideaccount2222"
	side, err := client.CreateProviderAccount(ctx, &dieterv1.CreateProviderAccountRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "Side", AccountId: sideID})
	if err != nil || side.GetId() != sideID || side.GetIsDefault() {
		t.Fatalf("second Claude account = %v, %v", side, err)
	}
	if again, err := client.CreateProviderAccount(ctx, &dieterv1.CreateProviderAccountRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "Side", AccountId: sideID}); err != nil || again.GetId() != sideID {
		t.Fatalf("idempotent create = %v, %v", again, err)
	}
	_, err = client.CreateProviderAccount(ctx, &dieterv1.CreateProviderAccountRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "Other", AccountId: sideID})
	wantCode(t, err, connect.CodeAlreadyExists, "a different account under a taken ID")
	personal := createProviderAccount(t, client, dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT, "Personal", dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_UNSPECIFIED)
	if personal.GetMethod() != dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CODEX || !personal.GetIsDefault() {
		t.Fatalf("first ChatGPT account = %v", personal)
	}

	for name, request := range map[string]*dieterv1.CreateProviderAccountRequest{
		"no provider":         {Label: "X"},
		"no label":            {Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE},
		"multi-line label":    {Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "a\nb"},
		"long label":          {Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: strings.Repeat("x", 61)},
		"foreign method":      {Provider: dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT, Label: "X", Method: dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CLAUDE_CODE},
		"adopted-only method": {Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "X", Method: dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_HOST},
		"malformed ID":        {Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "X", AccountId: "pa_UPPER"},
	} {
		_, err := client.CreateProviderAccount(ctx, request)
		wantCode(t, err, connect.CodeInvalidArgument, name)
	}

	listed, err := client.ListProviderAccounts(ctx, &dieterv1.ListProviderAccountsRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE})
	if err != nil || len(listed.GetAccounts()) != 2 {
		t.Fatalf("Claude accounts = %v, %v", listed, err)
	}
	if all, err := client.ListProviderAccounts(ctx, &dieterv1.ListProviderAccountsRequest{}); err != nil || len(all.GetAccounts()) != 3 {
		t.Fatalf("all accounts = %v, %v", all, err)
	}

	label, excluded := "Day job", false
	updated, err := client.UpdateProviderAccount(ctx, &dieterv1.UpdateProviderAccountRequest{AccountId: work.GetId(), Label: &label, IncludeInSummary: &excluded})
	if err != nil || updated.GetLabel() != "Day job" || updated.GetIncludeInSummary() {
		t.Fatalf("update = %v, %v", updated, err)
	}
	_, err = client.UpdateProviderAccount(ctx, &dieterv1.UpdateProviderAccountRequest{AccountId: "pa_missingmissingmissing22222"})
	wantCode(t, err, connect.CodeNotFound, "update of an unknown account")

	if value, err := client.SetDefaultProviderAccount(ctx, &dieterv1.SetDefaultProviderAccountRequest{AccountId: sideID}); err != nil || !value.GetIsDefault() {
		t.Fatalf("set default = %v, %v", value, err)
	}
	listed, _ = client.ListProviderAccounts(ctx, &dieterv1.ListProviderAccountsRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE})
	for _, account := range listed.GetAccounts() {
		if account.GetIsDefault() != (account.GetId() == sideID) {
			t.Fatalf("defaults after the switch: %v", listed)
		}
	}
	_, err = client.SetDefaultProviderAccount(ctx, &dieterv1.SetDefaultProviderAccountRequest{AccountId: "pa_missingmissingmissing22222"})
	wantCode(t, err, connect.CodeNotFound, "default of an unknown account")

	if _, err := client.DeleteProviderAccount(ctx, &dieterv1.DeleteProviderAccountRequest{AccountId: sideID}); err != nil {
		t.Fatal(err)
	}
	_, err = client.DeleteProviderAccount(ctx, &dieterv1.DeleteProviderAccountRequest{AccountId: sideID})
	wantCode(t, err, connect.CodeNotFound, "second delete")
	_, err = client.CreateProviderAccount(ctx, &dieterv1.CreateProviderAccountRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "Side", AccountId: sideID})
	wantCode(t, err, connect.CodeNotFound, "re-create of a removed account")
	listed, _ = client.ListProviderAccounts(ctx, &dieterv1.ListProviderAccountsRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE})
	if len(listed.GetAccounts()) != 1 || listed.GetAccounts()[0].GetId() != work.GetId() || listed.GetAccounts()[0].GetIsDefault() {
		t.Fatalf("after removing the default: %v", listed)
	}
}

func TestProviderLoginRPCsSignInWithAPastedCode(t *testing.T) {
	t.Parallel()
	client, data := newProviderAccountsClient(t, nil)
	ctx := t.Context()
	work := createProviderAccount(t, client, dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, "Work", dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_UNSPECIFIED)

	_, err := client.StartProviderLogin(ctx, &dieterv1.StartProviderLoginRequest{AccountId: work.GetId(), Flow: dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_DEVICE_CODE})
	wantCode(t, err, connect.CodeInvalidArgument, "a Claude device-code sign-in")
	_, err = client.StartProviderLogin(ctx, &dieterv1.StartProviderLoginRequest{AccountId: "pa_missingmissingmissing22222"})
	wantCode(t, err, connect.CodeNotFound, "a sign-in of an unknown account")
	_, err = client.CheckProviderLogin(ctx, &dieterv1.CheckProviderLoginRequest{AccountId: work.GetId()})
	if err == nil {
		// A check of a machine that never signed in reports no login.
		if checked, _ := client.ListProviderAccounts(ctx, &dieterv1.ListProviderAccountsRequest{}); machineLogin(checked.GetAccounts()[0], providerTestDaemon).GetState() == dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN {
			t.Fatal("a check signed a machine in")
		}
	}

	login, err := client.StartProviderLogin(ctx, &dieterv1.StartProviderLoginRequest{AccountId: work.GetId()})
	if err != nil {
		t.Fatal(err)
	}
	challenge := login.GetChallenge()
	if login.GetFlow() != dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_PASTE_CODE || login.GetPhase() != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_WAITING ||
		login.GetDaemonId() != providerTestDaemon || challenge.GetExpects() != dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE ||
		!strings.HasPrefix(challenge.GetOpenUrl(), "https://") || challenge.GetCallbackPort() == 0 {
		t.Fatalf("started sign-in = %v", login)
	}
	_, err = client.SubmitProviderLoginInput(ctx, &dieterv1.SubmitProviderLoginInputRequest{LoginId: login.GetLoginId()})
	wantCode(t, err, connect.CodeInvalidArgument, "an empty submission")
	_, err = client.SubmitProviderLoginInput(ctx, &dieterv1.SubmitProviderLoginInputRequest{LoginId: login.GetLoginId(), Input: &dieterv1.SubmitProviderLoginInputRequest_CallbackUrl{CallbackUrl: "http://evil.example/callback?code=fixture"}})
	wantCode(t, err, connect.CodeInvalidArgument, "a callback off loopback")
	submitted, err := client.SubmitProviderLoginInput(ctx, &dieterv1.SubmitProviderLoginInputRequest{LoginId: login.GetLoginId(), Input: &dieterv1.SubmitProviderLoginInputRequest_Code{Code: accounts.FixtureCode + "#state"}})
	if err != nil {
		t.Fatal(err)
	}
	if submitted.GetLoginId() != login.GetLoginId() {
		t.Fatalf("submitted = %v", submitted)
	}
	states := watchProviderLogin(t, client, login.GetLoginId())
	if final := states[len(states)-1]; final.GetPhase() != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_SUCCEEDED || final.GetIdentity().GetEmail() != "fixture@example.com" {
		t.Fatalf("final sign-in state = %v", final)
	}
	_, err = client.SubmitProviderLoginInput(ctx, &dieterv1.SubmitProviderLoginInputRequest{LoginId: login.GetLoginId(), Input: &dieterv1.SubmitProviderLoginInputRequest_Code{Code: accounts.FixtureCode}})
	wantCode(t, err, connect.CodeFailedPrecondition, "input to a finished sign-in")

	listed, err := client.ListProviderAccounts(ctx, &dieterv1.ListProviderAccountsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	account := listed.GetAccounts()[0]
	mine := machineLogin(account, providerTestDaemon)
	if mine.GetState() != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN || mine.GetMethod() != dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CLAUDE_CODE ||
		mine.GetVerifiedAt() == "" || account.GetIdentity().GetEmail() != "fixture@example.com" || account.GetIdentity().GetOrganizationId() != "org_fixture" {
		t.Fatalf("signed-in account = %v", account)
	}
	// The login record carries no credential: only the replicated JSON shape.
	if raw := providerLoginValue(t, data, work.GetId()); strings.Contains(raw, accounts.FixtureCode) || strings.Contains(strings.ToLower(raw), "token") {
		t.Fatalf("the login record leaks sign-in material: %s", raw)
	}

	checked, err := client.CheckProviderLogin(ctx, &dieterv1.CheckProviderLoginRequest{AccountId: work.GetId()})
	if err != nil || machineLogin(checked, providerTestDaemon).GetState() != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN {
		t.Fatalf("check = %v, %v", checked, err)
	}
	refreshed, err := client.RefreshProviderUsage(ctx, &dieterv1.RefreshProviderUsageRequest{AccountId: work.GetId()})
	if err != nil || refreshed.GetUsage() == nil || len(refreshed.GetUsage().GetWindows()) != 2 || refreshed.GetUsage().GetSource() != "probe" || refreshed.GetUsage().GetPlan() != "max" {
		t.Fatalf("refreshed usage = %v, %v", refreshed, err)
	}
	if window := refreshed.GetUsage().GetWindows()[0]; window.GetKind() != "five_hour" || window.GetUsedPercent() <= 0 || window.GetDurationMinutes() != 300 || window.GetResetsAt() == "" {
		t.Fatalf("five-hour window = %v", window)
	}

	signedOut, err := client.SignOutProviderAccount(ctx, &dieterv1.SignOutProviderAccountRequest{AccountId: work.GetId()})
	if err != nil || machineLogin(signedOut, providerTestDaemon).GetState() != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_OUT || machineLogin(signedOut, providerTestDaemon).GetUsage() != nil {
		t.Fatalf("sign-out = %v, %v", signedOut, err)
	}
	_, err = client.RefreshProviderUsage(ctx, &dieterv1.RefreshProviderUsageRequest{AccountId: work.GetId()})
	wantCode(t, err, connect.CodeFailedPrecondition, "usage of a signed-out machine")

	// A wrong code fails the sign-in and leaves the machine signed out.
	retry, err := client.StartProviderLogin(ctx, &dieterv1.StartProviderLoginRequest{AccountId: work.GetId(), Flow: dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_PASTE_CODE})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SubmitProviderLoginInput(ctx, &dieterv1.SubmitProviderLoginInputRequest{LoginId: retry.GetLoginId(), Input: &dieterv1.SubmitProviderLoginInputRequest_Code{Code: "WRONG-CODE"}}); err != nil {
		t.Fatal(err)
	}
	failed := watchProviderLogin(t, client, retry.GetLoginId())
	if final := failed[len(failed)-1]; final.GetPhase() != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_FAILED || final.GetErrorCode() != "login_failed" || final.GetErrorMessage() == "" {
		t.Fatalf("wrong-code sign-in = %v", final)
	}
	listed, _ = client.ListProviderAccounts(ctx, &dieterv1.ListProviderAccountsRequest{})
	if state := machineLogin(listed.GetAccounts()[0], providerTestDaemon).GetState(); state != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_OUT {
		t.Fatalf("after a failed sign-in the machine is %v", state)
	}
	_, err = client.CancelProviderLogin(ctx, &dieterv1.CancelProviderLoginRequest{LoginId: "pl_unknown"})
	wantCode(t, err, connect.CodeNotFound, "cancel of an unknown sign-in")
	stream, err := client.WatchProviderLogin(ctx, &dieterv1.WatchProviderLoginRequest{LoginId: "pl_unknown"})
	if err == nil {
		for stream.Receive() {
		}
		err = stream.Err()
		_ = stream.Close()
	}
	wantCode(t, err, connect.CodeNotFound, "watch of an unknown sign-in")
}

func TestProviderLoginRPCsDeviceCodeCancelAndReset(t *testing.T) {
	t.Parallel()
	client, _ := newProviderAccountsClient(t, nil)
	ctx := t.Context()
	personal := createProviderAccount(t, client, dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT, "Personal", dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CODEX)

	// A browser sign-in is canceled; its watchers see the end.
	browser, err := client.StartProviderLogin(ctx, &dieterv1.StartProviderLoginRequest{AccountId: personal.GetId(), Flow: dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_BROWSER})
	if err != nil || browser.GetChallenge().GetExpects() != dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CALLBACK || browser.GetChallenge().GetCallbackPort() != 1455 {
		t.Fatalf("browser sign-in = %v, %v", browser, err)
	}
	canceled, err := client.CancelProviderLogin(ctx, &dieterv1.CancelProviderLoginRequest{LoginId: browser.GetLoginId()})
	if err != nil || canceled.GetPhase() != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_CANCELED {
		t.Fatalf("cancel = %v, %v", canceled, err)
	}
	if phase := lastPhase(watchProviderLogin(t, client, browser.GetLoginId())); phase != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_CANCELED {
		t.Fatalf("watch after cancel ended %v", phase)
	}

	// A device code approves itself; it takes no input.
	device, err := client.StartProviderLogin(ctx, &dieterv1.StartProviderLoginRequest{AccountId: personal.GetId()})
	if err != nil {
		t.Fatal(err)
	}
	if device.GetFlow() != dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_DEVICE_CODE || device.GetChallenge().GetUserCode() == "" ||
		device.GetChallenge().GetExpects() != dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_NONE || device.GetChallenge().GetExpiresAt() == "" {
		t.Fatalf("device sign-in = %v", device)
	}
	if _, err := client.SubmitProviderLoginInput(ctx, &dieterv1.SubmitProviderLoginInputRequest{LoginId: device.GetLoginId(), Input: &dieterv1.SubmitProviderLoginInputRequest_Code{Code: "FIXT-12345"}}); err != nil {
		var connectErr *connect.Error
		if !errors.As(err, &connectErr) || connectErr.Code() != connect.CodeFailedPrecondition {
			t.Fatalf("a code for a device sign-in: %v", err)
		}
	}
	if phase := lastPhase(watchProviderLogin(t, client, device.GetLoginId())); phase != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_SUCCEEDED {
		t.Fatalf("device sign-in ended %v", phase)
	}

	refreshed, err := client.RefreshProviderUsage(ctx, &dieterv1.RefreshProviderUsageRequest{AccountId: personal.GetId()})
	if err != nil || refreshed.GetUsage().GetResetCreditsAvailable() != 1 || refreshed.GetIdentity().GetWorkspaceId() != "fixture-workspace" {
		t.Fatalf("ChatGPT usage = %v, %v", refreshed, err)
	}
	_, err = client.ConsumeProviderUsageReset(ctx, &dieterv1.ConsumeProviderUsageResetRequest{AccountId: personal.GetId()})
	wantCode(t, err, connect.CodeInvalidArgument, "a reset without an idempotency key")
	_, err = client.ConsumeProviderUsageReset(ctx, &dieterv1.ConsumeProviderUsageResetRequest{AccountId: personal.GetId(), IdempotencyKey: "not-a-uuid"})
	wantCode(t, err, connect.CodeInvalidArgument, "a reset with a malformed key")
	const key = "00000000-0000-4000-8000-000000000001"
	reset, err := client.ConsumeProviderUsageReset(ctx, &dieterv1.ConsumeProviderUsageResetRequest{AccountId: personal.GetId(), IdempotencyKey: key})
	if err != nil || reset.GetOutcome() != "reset" || reset.GetAccount().GetUsage().GetResetCreditsAvailable() != 0 {
		t.Fatalf("reset = %v, %v", reset, err)
	}
	if retried, err := client.ConsumeProviderUsageReset(ctx, &dieterv1.ConsumeProviderUsageResetRequest{AccountId: personal.GetId(), IdempotencyKey: key}); err != nil || retried.GetOutcome() != "alreadyRedeemed" {
		t.Fatalf("retried reset = %v, %v", retried, err)
	}
	// Claude accounts have no reset credits.
	work := createProviderAccount(t, client, dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, "Work", dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_UNSPECIFIED)
	_, err = client.ConsumeProviderUsageReset(ctx, &dieterv1.ConsumeProviderUsageResetRequest{AccountId: work.GetId(), IdempotencyKey: key})
	wantCode(t, err, connect.CodeFailedPrecondition, "a reset of a Claude account that is not signed in")
}

func TestProviderAccountMutationsRefuseAgentTurns(t *testing.T) {
	t.Parallel()
	client, _ := newProviderAccountsClient(t, nil)
	ctx := t.Context()
	work := createProviderAccount(t, client, dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, "Work", dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_UNSPECIFIED)
	login, err := client.StartProviderLogin(ctx, &dieterv1.StartProviderLoginRequest{AccountId: work.GetId()})
	if err != nil {
		t.Fatal(err)
	}
	// Refused by presence: even a token that would not verify never reaches
	// the engine.
	agent := withHeaders(ctx, map[string]string{turnTokenMetadata: "dtt1:c_agent:turn:any"})
	label := "Renamed"
	for name, call := range map[string]func() error{
		"create": func() error {
			_, err := client.CreateProviderAccount(agent, &dieterv1.CreateProviderAccountRequest{Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, Label: "Agent"})
			return err
		},
		"update": func() error {
			_, err := client.UpdateProviderAccount(agent, &dieterv1.UpdateProviderAccountRequest{AccountId: work.GetId(), Label: &label})
			return err
		},
		"delete": func() error {
			_, err := client.DeleteProviderAccount(agent, &dieterv1.DeleteProviderAccountRequest{AccountId: work.GetId()})
			return err
		},
		"default": func() error {
			_, err := client.SetDefaultProviderAccount(agent, &dieterv1.SetDefaultProviderAccountRequest{AccountId: work.GetId()})
			return err
		},
		"start login": func() error {
			_, err := client.StartProviderLogin(agent, &dieterv1.StartProviderLoginRequest{AccountId: work.GetId()})
			return err
		},
		"submit login input": func() error {
			_, err := client.SubmitProviderLoginInput(agent, &dieterv1.SubmitProviderLoginInputRequest{LoginId: login.GetLoginId(), Input: &dieterv1.SubmitProviderLoginInputRequest_Code{Code: accounts.FixtureCode}})
			return err
		},
		"cancel login": func() error {
			_, err := client.CancelProviderLogin(agent, &dieterv1.CancelProviderLoginRequest{LoginId: login.GetLoginId()})
			return err
		},
		"sign out": func() error {
			_, err := client.SignOutProviderAccount(agent, &dieterv1.SignOutProviderAccountRequest{AccountId: work.GetId()})
			return err
		},
		"reset": func() error {
			_, err := client.ConsumeProviderUsageReset(agent, &dieterv1.ConsumeProviderUsageResetRequest{AccountId: work.GetId(), IdempotencyKey: "00000000-0000-4000-8000-000000000001"})
			return err
		},
	} {
		wantCode(t, call(), connect.CodePermissionDenied, name)
	}
	// Nothing changed: the account, its name and the waiting sign-in remain.
	listed, err := client.ListProviderAccounts(agent, &dieterv1.ListProviderAccountsRequest{})
	if err != nil || len(listed.GetAccounts()) != 1 || listed.GetAccounts()[0].GetLabel() != "Work" {
		t.Fatalf("agents read accounts = %v, %v; nothing may have changed", listed, err)
	}
	if submitted, err := client.SubmitProviderLoginInput(ctx, &dieterv1.SubmitProviderLoginInputRequest{LoginId: login.GetLoginId(), Input: &dieterv1.SubmitProviderLoginInputRequest_Code{Code: accounts.FixtureCode}}); err != nil {
		t.Fatalf("the operator's sign-in after the refusals: %v %v", submitted, err)
	}
	if phase := lastPhase(watchProviderLogin(t, client, login.GetLoginId())); phase != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_SUCCEEDED {
		t.Fatalf("operator sign-in ended %v", phase)
	}
	// Agents may verify a login.
	if checked, err := client.CheckProviderLogin(agent, &dieterv1.CheckProviderLoginRequest{AccountId: work.GetId()}); err != nil || machineLogin(checked, providerTestDaemon).GetState() != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN {
		t.Fatalf("agent check = %v, %v", checked, err)
	}
}

func TestProviderTurnTokenServesOnlyALiveTurnOnTheLocalRoute(t *testing.T) {
	t.Parallel()
	runner := vaultTurnRunner{started: make(chan harness.Request, 1), release: make(chan string, 1)}
	client, data := newProviderAccountsClient(t, runner)
	ctx := t.Context()
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Tokens", Path: testkit.CheckoutDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.GetProviderTurnToken(ctx, &dieterv1.GetProviderTurnTokenRequest{})
	wantCode(t, err, connect.CodePermissionDenied, "a token without a turn")
	_, err = client.GetProviderTurnToken(withHeaders(ctx, map[string]string{turnTokenMetadata: "dtt1:c_forged:turn:bad"}), &dieterv1.GetProviderTurnTokenRequest{})
	wantCode(t, err, connect.CodePermissionDenied, "a forged turn token")

	// A live turn on no account has no token to hand out.
	mock, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Mock", Prompt: "Work", Provider: "mock", Model: "mock"})
	if err != nil {
		t.Fatal(err)
	}
	request := startVaultTurn(t, client, runner, mock.ID)
	agent := withHeaders(ctx, map[string]string{turnTokenMetadata: request.Environment["DIETER_TURN_TOKEN"]})
	_, err = client.GetProviderTurnToken(agent, &dieterv1.GetProviderTurnTokenRequest{})
	wantCode(t, err, connect.CodeFailedPrecondition, "a turn without an account")
	runner.release <- "done"
	waitForIdle(t, data, mock.ID)

	// A Sign in with ChatGPT account hands its turn the access token, on the
	// local route only.
	siwc := createProviderAccount(t, client, dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT, "Team", dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_SIWC)
	login, err := client.StartProviderLogin(ctx, &dieterv1.StartProviderLoginRequest{AccountId: siwc.GetId()})
	if err != nil || login.GetChallenge().GetExpects() != dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CALLBACK {
		t.Fatalf("SIWC sign-in = %v, %v", login, err)
	}
	if _, err := client.SubmitProviderLoginInput(ctx, &dieterv1.SubmitProviderLoginInputRequest{LoginId: login.GetLoginId(), Input: &dieterv1.SubmitProviderLoginInputRequest_CallbackUrl{CallbackUrl: "http://127.0.0.1:1456/auth/callback?code=fixture&state=s"}}); err != nil {
		t.Fatal(err)
	}
	if phase := lastPhase(watchProviderLogin(t, client, login.GetLoginId())); phase != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_SUCCEEDED {
		t.Fatalf("SIWC sign-in ended %v", phase)
	}
	codex, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Codex", Prompt: "Work", Provider: "codex", Model: "gpt-5.5", ProviderAccountID: siwc.GetId()})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SendMessage(ctx, &dieterv1.SendMessageRequest{CardId: codex.ID, Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Go"}}}); err != nil {
		t.Fatal(err)
	}
	select {
	case request = <-runner.started:
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("the Codex turn did not start")
	}
	if request.ProviderAccountID != siwc.GetId() {
		t.Fatalf("the turn runs on %q, want %s", request.ProviderAccountID, siwc.GetId())
	}
	token := request.Environment["DIETER_TURN_TOKEN"]
	agent = withHeaders(ctx, map[string]string{turnTokenMetadata: token})
	served, err := client.GetProviderTurnToken(agent, &dieterv1.GetProviderTurnTokenRequest{})
	if err != nil || strings.Count(served.GetToken(), ".") != 2 || served.GetExpiresAt() == "" {
		t.Fatalf("turn token = %v, %v", served, err)
	}
	if expires, err := time.Parse(time.RFC3339, served.GetExpiresAt()); err != nil || !expires.After(time.Now()) {
		t.Fatalf("turn token expiry %q: %v", served.GetExpiresAt(), err)
	}
	remote := withHeaders(ctx, map[string]string{operatorSubjectMetadata: "github:1", deviceIDMetadata: "dv_remote", turnTokenMetadata: token})
	_, err = client.GetProviderTurnToken(remote, &dieterv1.GetProviderTurnTokenRequest{})
	wantCode(t, err, connect.CodePermissionDenied, "a turn token over a remote route")
	runner.release <- "done"
	waitForIdle(t, data, codex.ID)
}

func TestProviderAccountRPCsNeedTheAccountsEngine(t *testing.T) {
	t.Parallel()
	client, _ := newConnectTestClient(t, testkit.Store(t), &testkit.FakeRunner{}, testkit.MockCatalog())
	_, err := client.ListProviderAccounts(t.Context(), &dieterv1.ListProviderAccountsRequest{})
	wantCode(t, err, connect.CodeFailedPrecondition, "accounts without an engine")
}

// providerLoginValue is this machine's login record of an account as it
// replicates.
func providerLoginValue(t *testing.T, data *store.Store, accountID string) string {
	t.Helper()
	var raw []string
	if err := data.KV.EachProviderLogin(accountID+".", false, func(entry kv.ProviderLoginEntry) error {
		value, err := json.Marshal(entry.Record)
		raw = append(raw, string(value))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if len(raw) == 0 {
		t.Fatalf("no login record of %s", accountID)
	}
	return strings.Join(raw, "\n")
}
