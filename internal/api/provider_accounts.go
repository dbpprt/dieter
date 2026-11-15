package api

import (
	"context"
	"strings"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/dbpprt/dieter/internal/engine/accounts"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
)

// Provider account rules:
//   - Agent turns may read accounts and their usage, and verify a login, but
//     never add, rename, remove, sign in, sign out or spend a reset credit: a
//     call carrying a turn token is refused for every mutation.
//   - Account-wide calls (create, update, delete, default) run on any daemon
//     and replicate; sign-in, sign-out, check, usage and reset act on the
//     daemon that serves the call.
//   - GetProviderTurnToken serves only the calling turn's own account, on the
//     local route, with a live turn token.

func (api *providerAccountsAPI) service() (*accounts.Service, error) {
	if api.server.accounts == nil {
		return nil, fault.New(fault.FailedPrecondition, "provider accounts are unavailable on this machine")
	}
	return api.server.accounts, nil
}

// operator refuses agent turns the account mutations.
func (api *providerAccountsAPI) operator(ctx context.Context) (*accounts.Service, error) {
	if requestHeader(ctx, turnTokenMetadata) != "" {
		return nil, fault.New(fault.PermissionDenied, "agents cannot manage provider accounts")
	}
	return api.service()
}

func (api *providerAccountsAPI) ListProviderAccounts(ctx context.Context, r *dieterv1.ListProviderAccountsRequest) (*dieterv1.ListProviderAccountsResponse, error) {
	service, err := api.service()
	if err != nil {
		return nil, err
	}
	values, err := service.List(ctx, providerName(r.GetProvider()))
	if err != nil {
		return nil, err
	}
	response := &dieterv1.ListProviderAccountsResponse{Accounts: make([]*dieterv1.ProviderAccount, 0, len(values))}
	for _, value := range values {
		response.Accounts = append(response.Accounts, protoProviderAccount(value))
	}
	return response, nil
}

func (api *providerAccountsAPI) CreateProviderAccount(ctx context.Context, r *dieterv1.CreateProviderAccountRequest) (*dieterv1.ProviderAccount, error) {
	service, err := api.operator(ctx)
	if err != nil {
		return nil, err
	}
	if r.GetProvider() == dieterv1.ProviderKind_PROVIDER_KIND_UNSPECIFIED {
		return nil, fault.New(fault.Invalid, "provider is required: claude or chatgpt")
	}
	value, err := service.Create(ctx, accounts.CreateInput{
		Provider: providerName(r.GetProvider()), Label: r.GetLabel(),
		Method: loginMethodName(r.GetMethod()), AccountID: strings.TrimSpace(r.GetAccountId()),
	})
	if err != nil {
		return nil, err
	}
	return protoProviderAccount(value), nil
}

func (api *providerAccountsAPI) UpdateProviderAccount(ctx context.Context, r *dieterv1.UpdateProviderAccountRequest) (*dieterv1.ProviderAccount, error) {
	service, err := api.operator(ctx)
	if err != nil {
		return nil, err
	}
	value, err := service.Update(ctx, r.GetAccountId(), r.Label, r.IncludeInSummary)
	if err != nil {
		return nil, err
	}
	return protoProviderAccount(value), nil
}

func (api *providerAccountsAPI) DeleteProviderAccount(ctx context.Context, r *dieterv1.DeleteProviderAccountRequest) (*emptypb.Empty, error) {
	service, err := api.operator(ctx)
	if err != nil {
		return nil, err
	}
	if err := service.Delete(ctx, r.GetAccountId()); err != nil {
		return nil, err
	}
	return &emptypb.Empty{}, nil
}

func (api *providerAccountsAPI) SetDefaultProviderAccount(ctx context.Context, r *dieterv1.SetDefaultProviderAccountRequest) (*dieterv1.ProviderAccount, error) {
	service, err := api.operator(ctx)
	if err != nil {
		return nil, err
	}
	value, err := service.SetDefault(ctx, r.GetAccountId())
	if err != nil {
		return nil, err
	}
	return protoProviderAccount(value), nil
}

func (api *providerAccountsAPI) StartProviderLogin(ctx context.Context, r *dieterv1.StartProviderLoginRequest) (*dieterv1.ProviderLogin, error) {
	service, err := api.operator(ctx)
	if err != nil {
		return nil, err
	}
	value, err := service.StartLogin(ctx, r.GetAccountId(), loginFlowName(r.GetFlow()))
	if err != nil {
		return nil, err
	}
	return protoProviderLogin(value), nil
}

// maxProviderLoginWatches bounds concurrent sign-in streams per daemon.
const maxProviderLoginWatches = 16

func (api *providerAccountsAPI) WatchProviderLogin(ctx context.Context, r *dieterv1.WatchProviderLoginRequest, stream *connect.ServerStream[dieterv1.ProviderLogin]) error {
	service, err := api.service()
	if err != nil {
		return err
	}
	if api.server.providerLoginWatches.Add(1) > maxProviderLoginWatches {
		api.server.providerLoginWatches.Add(-1)
		return fault.New(fault.ResourceExhausted, "too many sign-in streams on this machine")
	}
	defer api.server.providerLoginWatches.Add(-1)
	heartbeat := time.Duration(r.GetHeartbeatSeconds()) * time.Second
	if heartbeat <= 0 {
		heartbeat = 15 * time.Second
	}
	if heartbeat < time.Second {
		heartbeat = time.Second
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	updates := make(chan accounts.Login, 4)
	watchErr := make(chan error, 1)
	go func() {
		watchErr <- service.WatchLogin(ctx, r.GetLoginId(), func(login accounts.Login) error {
			select {
			case updates <- login:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()
	var last *dieterv1.ProviderLogin
	ticker := time.NewTicker(heartbeat)
	defer ticker.Stop()
	for {
		select {
		case login := <-updates:
			last = protoProviderLogin(login)
			if err := stream.Send(last); err != nil {
				return err
			}
		case <-ticker.C:
			if last != nil {
				if err := stream.Send(last); err != nil {
					return err
				}
			}
		case err := <-watchErr:
			// Deliver what the watch emitted before it ended.
			for {
				select {
				case login := <-updates:
					if sendErr := stream.Send(protoProviderLogin(login)); sendErr != nil {
						return sendErr
					}
					continue
				default:
				}
				break
			}
			if err != nil && ctx.Err() == nil {
				return err
			}
			return nil
		case <-ctx.Done():
			return nil
		}
	}
}

func (api *providerAccountsAPI) SubmitProviderLoginInput(ctx context.Context, r *dieterv1.SubmitProviderLoginInputRequest) (*dieterv1.ProviderLogin, error) {
	service, err := api.operator(ctx)
	if err != nil {
		return nil, err
	}
	value, err := service.SubmitLoginInput(ctx, r.GetLoginId(), r.GetCode(), r.GetCallbackUrl())
	if err != nil {
		return nil, err
	}
	return protoProviderLogin(value), nil
}

func (api *providerAccountsAPI) CancelProviderLogin(ctx context.Context, r *dieterv1.CancelProviderLoginRequest) (*dieterv1.ProviderLogin, error) {
	service, err := api.operator(ctx)
	if err != nil {
		return nil, err
	}
	value, err := service.CancelLogin(ctx, r.GetLoginId())
	if err != nil {
		return nil, err
	}
	return protoProviderLogin(value), nil
}

func (api *providerAccountsAPI) SignOutProviderAccount(ctx context.Context, r *dieterv1.SignOutProviderAccountRequest) (*dieterv1.ProviderAccount, error) {
	service, err := api.operator(ctx)
	if err != nil {
		return nil, err
	}
	value, err := service.SignOut(ctx, r.GetAccountId())
	if err != nil {
		return nil, err
	}
	return protoProviderAccount(value), nil
}

func (api *providerAccountsAPI) CheckProviderLogin(ctx context.Context, r *dieterv1.CheckProviderLoginRequest) (*dieterv1.ProviderAccount, error) {
	service, err := api.service()
	if err != nil {
		return nil, err
	}
	value, err := service.Check(ctx, r.GetAccountId())
	if err != nil {
		return nil, err
	}
	return protoProviderAccount(value), nil
}

func (api *providerAccountsAPI) RefreshProviderUsage(ctx context.Context, r *dieterv1.RefreshProviderUsageRequest) (*dieterv1.ProviderAccount, error) {
	service, err := api.service()
	if err != nil {
		return nil, err
	}
	value, err := service.RefreshUsage(ctx, r.GetAccountId())
	if err != nil {
		return nil, err
	}
	return protoProviderAccount(value), nil
}

func (api *providerAccountsAPI) ConsumeProviderUsageReset(ctx context.Context, r *dieterv1.ConsumeProviderUsageResetRequest) (*dieterv1.ConsumeProviderUsageResetResponse, error) {
	service, err := api.operator(ctx)
	if err != nil {
		return nil, err
	}
	key := strings.TrimSpace(r.GetIdempotencyKey())
	if key == "" {
		return nil, fault.New(fault.Invalid, "idempotency_key is required")
	}
	outcome, value, err := service.ConsumeReset(ctx, r.GetAccountId(), key, strings.TrimSpace(r.GetCreditId()))
	if err != nil {
		return nil, err
	}
	return &dieterv1.ConsumeProviderUsageResetResponse{Outcome: outcome, Account: protoProviderAccount(value)}, nil
}

func (api *providerAccountsAPI) GetProviderTurnToken(ctx context.Context, _ *dieterv1.GetProviderTurnTokenRequest) (*dieterv1.ProviderTurnToken, error) {
	service, err := api.service()
	if err != nil {
		return nil, err
	}
	if requestHeader(ctx, operatorSubjectMetadata) != "" {
		return nil, fault.New(fault.PermissionDenied, "a turn's provider token is served only on the local route")
	}
	card, _, agent, err := api.server.turnCaller(ctx)
	if err != nil {
		return nil, err
	}
	if !agent {
		return nil, fault.New(fault.PermissionDenied, "a live turn token is required")
	}
	if card.ProviderAccountID == "" {
		return nil, fault.New(fault.FailedPrecondition, "this turn runs on no provider account")
	}
	token, expires, err := service.TurnToken(ctx, card.ProviderAccountID)
	if err != nil {
		return nil, err
	}
	return &dieterv1.ProviderTurnToken{Token: token, ExpiresAt: expires.UTC().Format(time.RFC3339)}, nil
}

func providerName(kind dieterv1.ProviderKind) string {
	switch kind {
	case dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE:
		return accounts.ProviderClaude
	case dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT:
		return accounts.ProviderChatGPT
	}
	return ""
}

func providerKind(name string) dieterv1.ProviderKind {
	switch name {
	case accounts.ProviderClaude:
		return dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE
	case accounts.ProviderChatGPT:
		return dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT
	}
	return dieterv1.ProviderKind_PROVIDER_KIND_UNSPECIFIED
}

var loginMethods = map[string]dieterv1.ProviderLoginMethod{
	accounts.MethodClaudeCode:  dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CLAUDE_CODE,
	accounts.MethodCodex:       dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CODEX,
	accounts.MethodSIWC:        dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_SIWC,
	accounts.MethodHost:        dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_HOST,
	accounts.MethodEnvironment: dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_ENVIRONMENT,
}

func loginMethodName(method dieterv1.ProviderLoginMethod) string {
	for name, value := range loginMethods {
		if value == method {
			return name
		}
	}
	return ""
}

func loginStateKind(state string) dieterv1.ProviderLoginState {
	switch state {
	case accounts.StateSignedIn:
		return dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN
	case accounts.StateSignedOut:
		return dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_OUT
	case accounts.StateExpired:
		return dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_EXPIRED
	case accounts.StateFailed:
		return dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_FAILED
	}
	return dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_UNSPECIFIED
}

func loginFlowName(flow dieterv1.ProviderLoginFlow) string {
	switch flow {
	case dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_PASTE_CODE:
		return accounts.FlowPasteCode
	case dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_DEVICE_CODE:
		return accounts.FlowDeviceCode
	case dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_BROWSER:
		return accounts.FlowBrowser
	}
	return ""
}

func loginFlowKind(flow string) dieterv1.ProviderLoginFlow {
	switch flow {
	case accounts.FlowPasteCode:
		return dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_PASTE_CODE
	case accounts.FlowDeviceCode:
		return dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_DEVICE_CODE
	case accounts.FlowBrowser:
		return dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_BROWSER
	}
	return dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_UNSPECIFIED
}

func loginPhaseKind(phase string) dieterv1.ProviderLoginPhase {
	switch phase {
	case accounts.PhaseStarting:
		return dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_STARTING
	case accounts.PhaseWaiting:
		return dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_WAITING
	case accounts.PhaseCompleting:
		return dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_COMPLETING
	case accounts.PhaseSucceeded:
		return dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_SUCCEEDED
	case accounts.PhaseFailed:
		return dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_FAILED
	case accounts.PhaseCanceled:
		return dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_CANCELED
	}
	return dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_UNSPECIFIED
}

func loginInputKind(expects string) dieterv1.ProviderLoginInput {
	switch expects {
	case accounts.ExpectsCode:
		return dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE
	case accounts.ExpectsNone:
		return dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_NONE
	case accounts.ExpectsCallback:
		return dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CALLBACK
	}
	return dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_UNSPECIFIED
}

func protoProviderIdentity(value accounts.Identity) *dieterv1.ProviderIdentity {
	if value.Empty() {
		return nil
	}
	return &dieterv1.ProviderIdentity{
		Email: value.Email, Organization: value.Organization, OrganizationId: value.OrganizationID,
		WorkspaceId: value.WorkspaceID, Subject: value.Subject, Plan: value.Plan,
	}
}

func protoProviderUsage(value *accounts.Usage) *dieterv1.ProviderUsage {
	if value == nil {
		return nil
	}
	result := &dieterv1.ProviderUsage{Plan: value.Plan, ObservedAt: value.ObservedAt, Source: value.Source, Unavailable: value.Unavailable}
	for _, window := range value.Windows {
		result.Windows = append(result.Windows, &dieterv1.ProviderUsageWindow{
			Kind: window.Kind, Label: window.Label, UsedPercent: window.UsedPercent,
			ResetsAt: window.ResetsAt, DurationMinutes: int32(window.DurationMinutes),
		})
	}
	if value.Credits != nil {
		result.CreditsBalance, result.CreditsUnlimited = value.Credits.Balance, value.Credits.Unlimited
	}
	if value.Spend != nil {
		result.SpendUsed, result.SpendLimit, result.SpendCurrency = value.Spend.Used, value.Spend.Limit, value.Spend.Currency
	}
	if value.ResetCredits != nil {
		result.ResetCreditsAvailable = int32(value.ResetCredits.Available)
	}
	return result
}

func protoProviderTokens(value *accounts.TokenUsage) *dieterv1.ProviderTokenUsage {
	if value == nil {
		return nil
	}
	totals := func(t accounts.TokenTotals) *dieterv1.ProviderTokenTotals {
		return &dieterv1.ProviderTokenTotals{InputTokens: t.Input, OutputTokens: t.Output, TotalTokens: t.Total}
	}
	return &dieterv1.ProviderTokenUsage{FiveHour: totals(value.FiveHour), SevenDay: totals(value.SevenDay), ObservedAt: value.ObservedAt}
}

func protoProviderAccount(value accounts.Account) *dieterv1.ProviderAccount {
	result := &dieterv1.ProviderAccount{
		Id: value.ID, Provider: providerKind(value.Provider), Label: value.Label, Method: loginMethods[value.Method],
		Identity: protoProviderIdentity(value.Identity), IncludeInSummary: value.IncludeInSummary, IsDefault: value.IsDefault,
		Usage: protoProviderUsage(value.Usage), DieterTokens: protoProviderTokens(value.DieterTokens),
		CreatedAt: value.CreatedAt, CreatedBy: value.CreatedBy,
	}
	for _, login := range value.Logins {
		result.Logins = append(result.Logins, &dieterv1.ProviderMachineLogin{
			DaemonId: login.DaemonID, State: loginStateKind(login.State), Method: loginMethods[login.Method],
			Identity: protoProviderIdentity(login.Identity), VerifiedAt: login.VerifiedAt,
			ErrorCode: login.ErrorCode, ErrorMessage: login.ErrorMessage,
			Usage: protoProviderUsage(login.Usage), DieterTokens: protoProviderTokens(login.DieterTokens),
		})
	}
	return result
}

func protoProviderLogin(value accounts.Login) *dieterv1.ProviderLogin {
	return &dieterv1.ProviderLogin{
		LoginId: value.ID, AccountId: value.AccountID, DaemonId: value.DaemonID,
		Flow: loginFlowKind(value.Flow), Phase: loginPhaseKind(value.Phase),
		Challenge: &dieterv1.ProviderLoginChallenge{
			OpenUrl: value.Challenge.OpenURL, LocalUrl: value.Challenge.LocalURL, CallbackPort: int32(value.Challenge.CallbackPort),
			UserCode: value.Challenge.UserCode, ExpiresAt: value.Challenge.ExpiresAt, Expects: loginInputKind(value.Challenge.Expects),
		},
		Identity: protoProviderIdentity(value.Identity), ErrorCode: value.ErrorCode, ErrorMessage: value.ErrorMessage,
		UpdatedAt: value.UpdatedAt,
	}
}
