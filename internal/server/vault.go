package server

import (
	"context"
	"errors"
	"net/url"
	"os"
	"strings"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/vault"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// Vault access rules:
//   - Calls carrying an agent turn token act for that conversation and may use
//     items only when it was created with vault access. Agents never change
//     vault membership or keys.
//   - Calls without a token are the operator's: local CLI, or a remote client
//     forwarded over direct TLS/WebRTC.
//   - Decrypted content never crosses the gateway relay, where the gateway
//     sees request and response payloads.
//
// Agents run unsandboxed as the operator's user, so these rules guard against
// accidental use and leave an audit trail; they are not a hard boundary.

const (
	routeMetadata     = "x-dieter-route"
	turnTokenMetadata = "x-dieter-turn-token"
)

type vaultHeadersKey struct{}

type vaultHeaders struct{ route, operator, token string }

func vaultContext[T any](ctx context.Context, r *connect.Request[T]) context.Context {
	return context.WithValue(ctx, vaultHeadersKey{}, vaultHeaders{
		route: r.Header().Get(routeMetadata), operator: r.Header().Get(operatorSubjectMetadata), token: r.Header().Get(turnTokenMetadata),
	})
}

func vaultHeadersFrom(ctx context.Context) vaultHeaders {
	if value, ok := ctx.Value(vaultHeadersKey{}).(vaultHeaders); ok {
		return value
	}
	values, _ := metadata.FromIncomingContext(ctx)
	first := func(name string) string {
		if items := values.Get(name); len(items) == 1 {
			return items[0]
		}
		return ""
	}
	return vaultHeaders{route: first(routeMetadata), operator: first(operatorSubjectMetadata), token: first(turnTokenMetadata)}
}

type vaultCaller struct {
	kind, cardID, route, subject string
	access                       bool
}

func (c vaultCaller) actor() string {
	switch c.kind {
	case "agent":
		return "agent:" + c.cardID
	case "remote":
		return "remote:" + c.subject
	}
	return "operator"
}

func (c vaultCaller) proto() *dieterv1.VaultCaller {
	return &dieterv1.VaultCaller{Kind: c.kind, CardId: c.cardID, VaultAccess: c.access, Route: c.route}
}

func (api *grpcAPI) vaultCaller(ctx context.Context) (vaultCaller, error) {
	headers := vaultHeadersFrom(ctx)
	caller := vaultCaller{kind: "operator", route: "local", access: true}
	switch {
	case headers.route == "relay":
		caller.route = "relay"
	case headers.operator != "":
		caller.route = "direct"
	}
	if headers.operator != "" {
		caller.kind, caller.subject = "remote", headers.operator
	}
	// Remote metadata is never forwarded, so a turn token can only come from
	// a local process.
	if headers.token == "" || caller.route != "local" {
		return caller, nil
	}
	cardID, err := api.server.app.VerifyTurnToken(headers.token)
	if err != nil {
		return caller, status.Error(codes.PermissionDenied, err.Error())
	}
	card, err := api.server.store.ResolveCard(cardID)
	if err != nil {
		return caller, grpcFailure(err)
	}
	return vaultCaller{kind: "agent", cardID: cardID, route: caller.route, access: card.VaultAccess}, nil
}

type vaultRule int

const (
	vaultAllowRelay vaultRule = 1 << iota
	vaultOperatorOnly
)

// vaultAdmit classifies the caller and enforces the access rules.
func (api *grpcAPI) vaultAdmit(ctx context.Context, action string, rules vaultRule) (vaultCaller, error) {
	caller, err := api.vaultCaller(ctx)
	if err != nil {
		return caller, err
	}
	deny := func(code codes.Code, message string) (vaultCaller, error) {
		api.vaultAudit(caller, store.VaultAuditEntry{Action: action, Outcome: "denied", Detail: message})
		return caller, status.Error(code, message)
	}
	if !caller.access {
		return deny(codes.PermissionDenied, "this conversation was created without vault access; create a card, chat or schedule with vault access")
	}
	if rules&vaultOperatorOnly != 0 && caller.kind == "agent" {
		return deny(codes.PermissionDenied, "agents cannot change vault membership or keys; ask the operator")
	}
	if rules&vaultAllowRelay == 0 && caller.route == "relay" {
		return deny(codes.FailedPrecondition, "vault contents never cross the gateway relay; use a direct or WebRTC route, or run the command on that machine")
	}
	return caller, nil
}

func (api *grpcAPI) vaultAudit(caller vaultCaller, entry store.VaultAuditEntry) {
	entry.Caller, entry.CardID, entry.Route = caller.actor(), caller.cardID, caller.route
	if err := api.server.store.AppendVaultAudit(entry); err != nil {
		api.server.log.Warn("vault audit write failed", "action", entry.Action, "error", err)
	}
}

func vaultFailure(err error) error {
	switch {
	case errors.Is(err, vault.ErrNoVault), errors.Is(err, vault.ErrLocked):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, vault.ErrWrongRecovery):
		return status.Error(codes.PermissionDenied, err.Error())
	case errors.Is(err, vault.ErrTampered):
		return status.Error(codes.DataLoss, err.Error())
	}
	if _, ok := status.FromError(err); ok && status.Code(err) != codes.Unknown {
		return err
	}
	if errors.Is(err, store.ErrNotFound) {
		return grpcFailure(err)
	}
	return status.Error(codes.InvalidArgument, err.Error())
}

func protoVaultStatus(value store.VaultStatus, caller vaultCaller) *dieterv1.VaultStatus {
	result := &dieterv1.VaultStatus{
		State: value.State, VaultId: value.VaultID, MemberId: value.MemberID, JoinCode: value.JoinCode,
		ItemCount: int32(value.Items), ConflictItemIds: value.Conflicts, CurrentKeyId: value.CurrentKey,
		CreatedAt: value.CreatedAt, Caller: caller.proto(),
	}
	for _, member := range value.Members {
		result.Members = append(result.Members, &dieterv1.VaultMember{
			Id: member.ID, Name: member.Name, DaemonId: member.DaemonID, Recovery: member.Recovery, Pending: member.Pending,
			Self: member.Self, JoinCode: member.Code, RequestedAt: member.RequestedAt, ApprovedAt: member.ApprovedAt, ApprovedBy: member.ApprovedBy,
		})
	}
	return result
}

func protoVaultItem(value store.VaultItem) *dieterv1.VaultItem {
	item := value.Item
	return &dieterv1.VaultItem{
		Id: value.ID, Name: item.Name, Urls: append([]string(nil), item.URLs...), Username: item.Username,
		HasPassword: item.Password != "", HasTotp: item.TOTP != "", HasNotes: item.Notes != "",
		CreatedAt: item.CreatedAt, UpdatedAt: item.UpdatedAt, UpdatedBy: item.UpdatedBy,
		Conflict: value.Conflict, Error: value.Error,
	}
}

func (api *grpcAPI) vaultStatus(caller vaultCaller) (*dieterv1.VaultStatus, error) {
	value, err := api.server.store.VaultStatus()
	if err != nil {
		return nil, vaultFailure(err)
	}
	return protoVaultStatus(value, caller), nil
}

func (api *grpcAPI) memberIdentity() (string, string) {
	name, _ := os.Hostname()
	if identity, err := api.server.store.PeerIdentity(); err == nil {
		return name, identity.DaemonID
	}
	return name, ""
}

func (api *grpcAPI) GetVaultStatus(ctx context.Context, _ *emptypb.Empty) (*dieterv1.VaultStatus, error) {
	caller, err := api.vaultCaller(ctx)
	if err != nil {
		return nil, err
	}
	if !caller.access {
		// An agent without access learns only that it has none.
		return &dieterv1.VaultStatus{Caller: caller.proto()}, nil
	}
	return api.vaultStatus(caller)
}

func (api *grpcAPI) InitVault(ctx context.Context, request *dieterv1.InitVaultRequest) (*dieterv1.InitVaultResponse, error) {
	caller, err := api.vaultAdmit(ctx, "init", vaultOperatorOnly)
	if err != nil {
		return nil, err
	}
	name, daemonID := api.memberIdentity()
	if value := strings.TrimSpace(request.GetName()); value != "" {
		name = value
	}
	recoveryKey, err := api.server.store.InitVault(name, daemonID)
	if err != nil {
		return nil, vaultFailure(err)
	}
	api.vaultAudit(caller, store.VaultAuditEntry{Action: "init", Outcome: "allowed"})
	value, err := api.vaultStatus(caller)
	if err != nil {
		return nil, err
	}
	return &dieterv1.InitVaultResponse{Status: value, RecoveryKey: recoveryKey}, nil
}

func (api *grpcAPI) JoinVault(ctx context.Context, request *dieterv1.JoinVaultRequest) (*dieterv1.JoinVaultResponse, error) {
	caller, err := api.vaultAdmit(ctx, "join", vaultOperatorOnly)
	if err != nil {
		return nil, err
	}
	name, daemonID := api.memberIdentity()
	if value := strings.TrimSpace(request.GetName()); value != "" {
		name = value
	}
	response := &dieterv1.JoinVaultResponse{}
	if strings.TrimSpace(request.GetRecoveryKey()) != "" {
		err = api.server.store.JoinVaultWithRecovery(request.GetRecoveryKey(), name, daemonID)
		api.vaultAudit(caller, store.VaultAuditEntry{Action: "join-recovery", Outcome: outcome(err)})
	} else {
		response.JoinCode, err = api.server.store.RequestVaultJoin(name, daemonID)
		api.vaultAudit(caller, store.VaultAuditEntry{Action: "join-request", Outcome: outcome(err)})
	}
	if err != nil {
		return nil, vaultFailure(err)
	}
	if response.Status, err = api.vaultStatus(caller); err != nil {
		return nil, err
	}
	return response, nil
}

func outcome(err error) string {
	if err != nil {
		return "failed"
	}
	return "allowed"
}

func (api *grpcAPI) ApproveVaultMember(ctx context.Context, request *dieterv1.ApproveVaultMemberRequest) (*dieterv1.VaultStatus, error) {
	caller, err := api.vaultAdmit(ctx, "approve-member", vaultOperatorOnly|vaultAllowRelay)
	if err != nil {
		return nil, err
	}
	err = api.server.store.ApproveVaultMember(strings.TrimSpace(request.GetMemberId()), request.GetJoinCode())
	api.vaultAudit(caller, store.VaultAuditEntry{Action: "approve-member", Detail: request.GetMemberId(), Outcome: outcome(err)})
	if err != nil {
		return nil, vaultFailure(err)
	}
	return api.vaultStatus(caller)
}

func (api *grpcAPI) RemoveVaultMember(ctx context.Context, request *dieterv1.VaultMemberRef) (*dieterv1.VaultStatus, error) {
	caller, err := api.vaultAdmit(ctx, "remove-member", vaultOperatorOnly|vaultAllowRelay)
	if err != nil {
		return nil, err
	}
	err = api.server.store.RemoveVaultMember(strings.TrimSpace(request.GetMemberId()))
	api.vaultAudit(caller, store.VaultAuditEntry{Action: "remove-member", Detail: request.GetMemberId(), Outcome: outcome(err)})
	if err != nil {
		return nil, vaultFailure(err)
	}
	return api.vaultStatus(caller)
}

func (api *grpcAPI) RotateVault(ctx context.Context, request *dieterv1.RotateVaultRequest) (*dieterv1.RotateVaultResponse, error) {
	caller, err := api.vaultAdmit(ctx, "rotate", vaultOperatorOnly)
	if err != nil {
		return nil, err
	}
	recoveryKey, err := api.server.store.RotateVault(request.GetNewRecoveryKey())
	api.vaultAudit(caller, store.VaultAuditEntry{Action: "rotate", Outcome: outcome(err)})
	if err != nil {
		return nil, vaultFailure(err)
	}
	value, err := api.vaultStatus(caller)
	if err != nil {
		return nil, err
	}
	return &dieterv1.RotateVaultResponse{Status: value, RecoveryKey: recoveryKey}, nil
}

func hostOf(value string) string {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.Hostname() == "" {
		parsed, err = url.Parse("https://" + strings.TrimSpace(value))
		if err != nil {
			return ""
		}
	}
	return strings.ToLower(parsed.Hostname())
}

// vaultURLMatches matches a host or any of its subdomains.
func vaultURLMatches(item store.VaultItem, target string) bool {
	host := hostOf(target)
	if host == "" {
		return false
	}
	for _, value := range item.Item.URLs {
		candidate := hostOf(value)
		if candidate != "" && (host == candidate || strings.HasSuffix(host, "."+candidate) || strings.HasSuffix(candidate, "."+host)) {
			return true
		}
	}
	return false
}

func (api *grpcAPI) ListVaultItems(ctx context.Context, request *dieterv1.ListVaultItemsRequest) (*dieterv1.VaultItemsResponse, error) {
	if _, err := api.vaultAdmit(ctx, "list", 0); err != nil {
		return nil, err
	}
	items, err := api.server.store.ListVaultItems()
	if err != nil {
		return nil, vaultFailure(err)
	}
	query := strings.ToLower(strings.TrimSpace(request.GetQuery()))
	response := &dieterv1.VaultItemsResponse{}
	for _, item := range items {
		if query != "" && !strings.Contains(strings.ToLower(item.Item.Name+"\x00"+item.Item.Username+"\x00"+strings.Join(item.Item.URLs, "\x00")), query) {
			continue
		}
		if request.GetUrl() != "" && !vaultURLMatches(item, request.GetUrl()) {
			continue
		}
		response.Items = append(response.Items, protoVaultItem(item))
	}
	return response, nil
}

func (api *grpcAPI) GetVaultItem(ctx context.Context, request *dieterv1.VaultItemRef) (*dieterv1.VaultItem, error) {
	if _, err := api.vaultAdmit(ctx, "show", 0); err != nil {
		return nil, err
	}
	item, err := api.server.store.VaultItem(request.GetItem())
	if err != nil {
		return nil, vaultFailure(err)
	}
	return protoVaultItem(item), nil
}

func (api *grpcAPI) RevealVaultItem(ctx context.Context, request *dieterv1.RevealVaultItemRequest) (*dieterv1.RevealVaultItemResponse, error) {
	purpose := request.GetPurpose()
	switch purpose {
	case "":
		purpose = "get"
	case "get", "totp", "exec":
	default:
		return nil, status.Error(codes.InvalidArgument, "purpose must be get, totp or exec")
	}
	fields := request.GetFields()
	if len(fields) == 0 {
		fields = []string{"password"}
	}
	if len(fields) > len(vault.Fields) {
		return nil, status.Error(codes.InvalidArgument, "too many fields")
	}
	caller, err := api.vaultAdmit(ctx, purpose, 0)
	if err != nil {
		return nil, err
	}
	item, err := api.server.store.VaultItem(request.GetItem())
	if err != nil {
		api.vaultAudit(caller, store.VaultAuditEntry{Action: purpose, Detail: request.GetItem(), Outcome: "failed"})
		return nil, vaultFailure(err)
	}
	now := time.Now()
	response := &dieterv1.RevealVaultItemResponse{Item: protoVaultItem(item), Values: map[string]string{}}
	for _, field := range fields {
		value, err := item.Item.Field(field, now)
		if err != nil {
			return nil, status.Error(codes.InvalidArgument, err.Error())
		}
		response.Values[field] = value
		if field == "totp" {
			config, _ := vault.ParseTOTP(item.Item.TOTP)
			_, remaining := config.Code(now)
			response.TotpRemainingSeconds = int32(remaining.Round(time.Second) / time.Second)
		}
	}
	if caller.kind == "agent" {
		api.server.app.RegisterVaultSecrets(caller.cardID, response.Values["password"], response.Values["notes"])
	}
	api.vaultAudit(caller, store.VaultAuditEntry{Action: purpose, ItemID: item.ID, ItemName: item.Item.Name, Fields: strings.Join(fields, ","), Outcome: "allowed"})
	return response, nil
}

func vaultPassword(given string, generate bool, length int32, withoutSymbols bool) (string, error) {
	if !generate {
		return given, nil
	}
	if given != "" {
		return "", errors.New("pass either a password or generate one, not both")
	}
	if length == 0 {
		length = 24
	}
	return vault.GeneratePassword(int(length), !withoutSymbols)
}

func canonicalTOTP(value string) (string, error) {
	if strings.TrimSpace(value) == "" {
		return "", nil
	}
	config, err := vault.ParseTOTP(value)
	if err != nil {
		return "", err
	}
	return config.URI(), nil
}

func (api *grpcAPI) CreateVaultItem(ctx context.Context, request *dieterv1.CreateVaultItemRequest) (*dieterv1.VaultItem, error) {
	caller, err := api.vaultAdmit(ctx, "create", 0)
	if err != nil {
		return nil, err
	}
	password, err := vaultPassword(request.GetPassword(), request.GetGeneratePassword(), request.GetPasswordLength(), request.GetPasswordWithoutSymbols())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	totp, err := canonicalTOTP(request.GetTotp())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	item := vault.Item{Name: strings.TrimSpace(request.GetName()), URLs: request.GetUrls(), Username: request.GetUsername(), Password: password, TOTP: totp, Notes: request.GetNotes()}
	created, err := api.server.store.CreateVaultItem(item, caller.actor())
	if err != nil {
		return nil, vaultFailure(err)
	}
	api.vaultAudit(caller, store.VaultAuditEntry{Action: "create", ItemID: created.ID, ItemName: created.Item.Name, Outcome: "allowed"})
	return protoVaultItem(created), nil
}

func (api *grpcAPI) UpdateVaultItem(ctx context.Context, request *dieterv1.UpdateVaultItemRequest) (*dieterv1.VaultItem, error) {
	caller, err := api.vaultAdmit(ctx, "update", 0)
	if err != nil {
		return nil, err
	}
	var password *string
	if request.Password != nil || request.GetGeneratePassword() {
		value, err := vaultPassword(request.GetPassword(), request.GetGeneratePassword(), request.GetPasswordLength(), request.GetPasswordWithoutSymbols())
		if err != nil {
			return nil, status.Error(codes.InvalidArgument, err.Error())
		}
		password = &value
	}
	var totp *string
	if request.Totp != nil {
		value, err := canonicalTOTP(request.GetTotp())
		if err != nil {
			return nil, status.Error(codes.InvalidArgument, err.Error())
		}
		totp = &value
	}
	var changed []string
	updated, err := api.server.store.UpdateVaultItem(request.GetItem(), func(item *vault.Item) error {
		if request.Name != nil {
			item.Name, changed = strings.TrimSpace(request.GetName()), append(changed, "name")
		}
		if request.GetReplaceUrls() {
			item.URLs, changed = append([]string(nil), request.GetUrls()...), append(changed, "url")
		} else if len(request.GetUrls()) > 0 {
			for _, value := range request.GetUrls() {
				present := false
				for _, existing := range item.URLs {
					present = present || existing == value
				}
				if !present {
					item.URLs = append(item.URLs, value)
				}
			}
			changed = append(changed, "url")
		}
		if request.Username != nil {
			item.Username, changed = request.GetUsername(), append(changed, "username")
		}
		if password != nil {
			item.Password, changed = *password, append(changed, "password")
		}
		if totp != nil {
			item.TOTP, changed = *totp, append(changed, "totp")
		}
		if request.Notes != nil {
			item.Notes, changed = request.GetNotes(), append(changed, "notes")
		}
		if len(changed) == 0 {
			return errors.New("nothing to update")
		}
		return item.Validate()
	}, caller.actor())
	if err != nil {
		return nil, vaultFailure(err)
	}
	api.vaultAudit(caller, store.VaultAuditEntry{Action: "update", ItemID: updated.ID, ItemName: updated.Item.Name, Fields: strings.Join(changed, ","), Outcome: "allowed"})
	return protoVaultItem(updated), nil
}

func (api *grpcAPI) DeleteVaultItem(ctx context.Context, request *dieterv1.VaultItemRef) (*dieterv1.VaultItem, error) {
	caller, err := api.vaultAdmit(ctx, "delete", 0)
	if err != nil {
		return nil, err
	}
	deleted, err := api.server.store.DeleteVaultItem(request.GetItem())
	if err != nil {
		return nil, vaultFailure(err)
	}
	api.vaultAudit(caller, store.VaultAuditEntry{Action: "delete", ItemID: deleted.ID, ItemName: deleted.Item.Name, Outcome: "allowed"})
	return protoVaultItem(deleted), nil
}

func (api *grpcAPI) ListVaultAudit(ctx context.Context, request *dieterv1.ListVaultAuditRequest) (*dieterv1.VaultAuditResponse, error) {
	if _, err := api.vaultAdmit(ctx, "audit", vaultOperatorOnly); err != nil {
		return nil, err
	}
	itemID := strings.TrimSpace(request.GetItem())
	if itemID != "" && !strings.HasPrefix(itemID, "vi_") {
		item, err := api.server.store.VaultItem(itemID)
		if err != nil {
			return nil, vaultFailure(err)
		}
		itemID = item.ID
	}
	entries, err := api.server.store.VaultAudit(int(request.GetLimit()), itemID, strings.TrimSpace(request.GetCardId()))
	if err != nil {
		return nil, grpcFailure(err)
	}
	response := &dieterv1.VaultAuditResponse{}
	for _, entry := range entries {
		response.Entries = append(response.Entries, &dieterv1.VaultAuditEntry{
			Time: entry.Time, Action: entry.Action, ItemId: entry.ItemID, ItemName: entry.ItemName, Fields: entry.Fields,
			Caller: entry.Caller, CardId: entry.CardID, Route: entry.Route, Outcome: entry.Outcome, Detail: entry.Detail,
		})
	}
	return response, nil
}

func (api *connectAPI) GetVaultStatus(ctx context.Context, r *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.VaultStatus], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.GetVaultStatus)
}
func (api *connectAPI) InitVault(ctx context.Context, r *connect.Request[dieterv1.InitVaultRequest]) (*connect.Response[dieterv1.InitVaultResponse], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.InitVault)
}
func (api *connectAPI) JoinVault(ctx context.Context, r *connect.Request[dieterv1.JoinVaultRequest]) (*connect.Response[dieterv1.JoinVaultResponse], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.JoinVault)
}
func (api *connectAPI) ApproveVaultMember(ctx context.Context, r *connect.Request[dieterv1.ApproveVaultMemberRequest]) (*connect.Response[dieterv1.VaultStatus], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.ApproveVaultMember)
}
func (api *connectAPI) RemoveVaultMember(ctx context.Context, r *connect.Request[dieterv1.VaultMemberRef]) (*connect.Response[dieterv1.VaultStatus], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.RemoveVaultMember)
}
func (api *connectAPI) RotateVault(ctx context.Context, r *connect.Request[dieterv1.RotateVaultRequest]) (*connect.Response[dieterv1.RotateVaultResponse], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.RotateVault)
}
func (api *connectAPI) ListVaultItems(ctx context.Context, r *connect.Request[dieterv1.ListVaultItemsRequest]) (*connect.Response[dieterv1.VaultItemsResponse], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.ListVaultItems)
}
func (api *connectAPI) GetVaultItem(ctx context.Context, r *connect.Request[dieterv1.VaultItemRef]) (*connect.Response[dieterv1.VaultItem], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.GetVaultItem)
}
func (api *connectAPI) RevealVaultItem(ctx context.Context, r *connect.Request[dieterv1.RevealVaultItemRequest]) (*connect.Response[dieterv1.RevealVaultItemResponse], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.RevealVaultItem)
}
func (api *connectAPI) CreateVaultItem(ctx context.Context, r *connect.Request[dieterv1.CreateVaultItemRequest]) (*connect.Response[dieterv1.VaultItem], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.CreateVaultItem)
}
func (api *connectAPI) UpdateVaultItem(ctx context.Context, r *connect.Request[dieterv1.UpdateVaultItemRequest]) (*connect.Response[dieterv1.VaultItem], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.UpdateVaultItem)
}
func (api *connectAPI) DeleteVaultItem(ctx context.Context, r *connect.Request[dieterv1.VaultItemRef]) (*connect.Response[dieterv1.VaultItem], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.DeleteVaultItem)
}
func (api *connectAPI) ListVaultAudit(ctx context.Context, r *connect.Request[dieterv1.ListVaultAuditRequest]) (*connect.Response[dieterv1.VaultAuditResponse], error) {
	return connectUnary(vaultContext(ctx, r), r, api.core.ListVaultAudit)
}
