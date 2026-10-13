package api

import (
	"context"
	"net/url"
	"os"
	"strings"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/security/vault"
	"github.com/dbpprt/dieter/internal/store/vaults"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
)

// Vault access rules:
//   - Calls carrying an agent turn token act for that conversation and may use
//     items only when it was created with vault access. Agents never change
//     vault membership or keys.
//   - Calls without a token are the operator's: the local CLI, or a remote
//     roster device forwarded by the DirectServer. Every remote carrier
//     (direct TCP, WebRTC, relay tunnel) is TLS end to end between that
//     device and this daemon, so the gateway never sees vault contents.
//
// Agents run unsandboxed as the operator's user, so these rules guard against
// accidental use and leave an audit trail; they are not a hard boundary.

const turnTokenMetadata = "x-dieter-turn-token"

type vaultHeadersKey struct{}

type vaultHeaders struct{ operator, device, token string }

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
	return vaultHeaders{operator: first(operatorSubjectMetadata), device: first(deviceIDMetadata), token: first(turnTokenMetadata)}
}

type vaultCaller struct {
	kind, cardID, route, subject, device string
	access                               bool
}

func (c vaultCaller) actor() string {
	switch c.kind {
	case "agent":
		return "agent:" + c.cardID
	case "remote":
		if c.device != "" {
			return "remote:" + c.subject + "/" + c.device
		}
		return "remote:" + c.subject
	}
	return "operator"
}

func (c vaultCaller) proto() *dieterv1.VaultCaller {
	return &dieterv1.VaultCaller{Kind: c.kind, CardId: c.cardID, VaultAccess: c.access, Route: c.route}
}

type vaultRule int

const vaultOperatorOnly vaultRule = 1

func protoVaultStatus(value vaults.Status, caller vaultCaller) *dieterv1.VaultStatus {
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

func protoVaultItem(value vaults.Item) *dieterv1.VaultItem {
	item := value.Item
	return &dieterv1.VaultItem{
		Id: value.ID, Name: item.Name, Urls: append([]string(nil), item.URLs...), Username: item.Username,
		HasPassword: item.Password != "", HasTotp: item.TOTP != "", HasNotes: item.Notes != "",
		CreatedAt: item.CreatedAt, UpdatedAt: item.UpdatedAt, UpdatedBy: item.UpdatedBy,
		Conflict: value.Conflict, Error: value.Error,
	}
}

func outcome(err error) string {
	if err != nil {
		return "failed"
	}
	return "allowed"
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
func vaultURLMatches(item vaults.Item, target string) bool {
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

func vaultPassword(given string, generate bool, length int32, withoutSymbols bool) (string, error) {
	if !generate {
		return given, nil
	}
	if given != "" {
		return "", fault.New(fault.Invalid, "pass either a password or generate one, not both")
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

func (s *Server) vaultCaller(ctx context.Context) (vaultCaller, error) {
	headers := vaultHeadersFrom(ctx)
	caller := vaultCaller{kind: "operator", route: "local", access: true}
	if headers.operator != "" {
		caller.kind, caller.route, caller.subject, caller.device = "remote", "remote", headers.operator, headers.device
	}
	// Remote metadata is never forwarded, so a turn token can only come from
	// a local process.
	if headers.token == "" || caller.route != "local" {
		return caller, nil
	}
	cardID, err := s.app.VerifyTurnToken(headers.token)
	if err != nil {
		return caller, fault.New(fault.PermissionDenied, err.Error())
	}
	card, err := s.store.Kanban.ResolveCard(cardID)
	if err != nil {
		return caller, err
	}
	return vaultCaller{kind: "agent", cardID: cardID, route: caller.route, access: card.VaultAccess}, nil
}

// vaultAdmit classifies the caller and enforces the access rules.
func (s *Server) vaultAdmit(ctx context.Context, action string, rules vaultRule) (vaultCaller, error) {
	caller, err := s.vaultCaller(ctx)
	if err != nil {
		return caller, err
	}
	deny := func(kind fault.Kind, message string) (vaultCaller, error) {
		s.vaultAudit(caller, vaults.AuditEntry{Action: action, Outcome: "denied", Detail: message})
		return caller, fault.New(kind, message)
	}
	if !caller.access {
		return deny(fault.PermissionDenied, "this conversation was created without vault access; create a card, chat or schedule with vault access")
	}
	if rules&vaultOperatorOnly != 0 && caller.kind == "agent" {
		return deny(fault.PermissionDenied, "agents cannot change vault membership or keys; ask the operator")
	}
	return caller, nil
}

func (s *Server) vaultAudit(caller vaultCaller, entry vaults.AuditEntry) {
	entry.Caller, entry.CardID, entry.Route = caller.actor(), caller.cardID, caller.route
	if err := s.vaults.AppendAudit(entry); err != nil {
		s.log.Warn("vault audit write failed", "action", entry.Action, "error", err)
	}
}

func (s *Server) vaultStatus(caller vaultCaller) (*dieterv1.VaultStatus, error) {
	value, err := s.vaults.Status()
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoVaultStatus(value, caller), nil
}

func (s *Server) memberIdentity() (string, string) {
	name, _ := os.Hostname()
	if identity, err := s.store.Replica.PeerIdentity(); err == nil {
		return name, identity.DaemonID
	}
	return name, ""
}

func (api *vaultAPI) GetVaultStatus(ctx context.Context, _ *emptypb.Empty) (*dieterv1.VaultStatus, error) {
	ctx = vaultContext(ctx)
	caller, err := api.server.vaultCaller(ctx)
	if err != nil {
		return nil, err
	}
	if !caller.access {
		// An agent without access learns only that it has none.
		return &dieterv1.VaultStatus{Caller: caller.proto()}, nil
	}
	return api.server.vaultStatus(caller)
}

func (api *vaultAPI) InitVault(ctx context.Context, request *dieterv1.InitVaultRequest) (*dieterv1.InitVaultResponse, error) {
	ctx = vaultContext(ctx)
	caller, err := api.server.vaultAdmit(ctx, "init", vaultOperatorOnly)
	if err != nil {
		return nil, err
	}
	name, daemonID := api.server.memberIdentity()
	if value := strings.TrimSpace(request.GetName()); value != "" {
		name = value
	}
	recoveryKey, err := api.server.vaults.Init(name, daemonID)
	if err != nil {
		return nil, domainFailure(err)
	}
	api.server.vaultAudit(caller, vaults.AuditEntry{Action: "init", Outcome: "allowed"})
	value, err := api.server.vaultStatus(caller)
	if err != nil {
		return nil, err
	}
	return &dieterv1.InitVaultResponse{Status: value, RecoveryKey: recoveryKey}, nil
}

func (api *vaultAPI) JoinVault(ctx context.Context, request *dieterv1.JoinVaultRequest) (*dieterv1.JoinVaultResponse, error) {
	ctx = vaultContext(ctx)
	caller, err := api.server.vaultAdmit(ctx, "join", vaultOperatorOnly)
	if err != nil {
		return nil, err
	}
	name, daemonID := api.server.memberIdentity()
	if value := strings.TrimSpace(request.GetName()); value != "" {
		name = value
	}
	response := &dieterv1.JoinVaultResponse{}
	if strings.TrimSpace(request.GetRecoveryKey()) != "" {
		err = api.server.vaults.JoinWithRecovery(request.GetRecoveryKey(), name, daemonID)
		api.server.vaultAudit(caller, vaults.AuditEntry{Action: "join-recovery", Outcome: outcome(err)})
	} else {
		response.JoinCode, err = api.server.vaults.RequestJoin(name, daemonID)
		api.server.vaultAudit(caller, vaults.AuditEntry{Action: "join-request", Outcome: outcome(err)})
	}
	if err != nil {
		return nil, domainFailure(err)
	}
	if response.Status, err = api.server.vaultStatus(caller); err != nil {
		return nil, err
	}
	return response, nil
}

func (api *vaultAPI) ApproveVaultMember(ctx context.Context, request *dieterv1.ApproveVaultMemberRequest) (*dieterv1.VaultStatus, error) {
	ctx = vaultContext(ctx)
	caller, err := api.server.vaultAdmit(ctx, "approve-member", vaultOperatorOnly)
	if err != nil {
		return nil, err
	}
	err = api.server.vaults.ApproveMember(strings.TrimSpace(request.GetMemberId()), request.GetJoinCode())
	api.server.vaultAudit(caller, vaults.AuditEntry{Action: "approve-member", Detail: request.GetMemberId(), Outcome: outcome(err)})
	if err != nil {
		return nil, domainFailure(err)
	}
	return api.server.vaultStatus(caller)
}

func (api *vaultAPI) RemoveVaultMember(ctx context.Context, request *dieterv1.VaultMemberRef) (*dieterv1.VaultStatus, error) {
	ctx = vaultContext(ctx)
	caller, err := api.server.vaultAdmit(ctx, "remove-member", vaultOperatorOnly)
	if err != nil {
		return nil, err
	}
	err = api.server.vaults.RemoveMember(strings.TrimSpace(request.GetMemberId()))
	api.server.vaultAudit(caller, vaults.AuditEntry{Action: "remove-member", Detail: request.GetMemberId(), Outcome: outcome(err)})
	if err != nil {
		return nil, domainFailure(err)
	}
	return api.server.vaultStatus(caller)
}

func (api *vaultAPI) RotateVault(ctx context.Context, request *dieterv1.RotateVaultRequest) (*dieterv1.RotateVaultResponse, error) {
	ctx = vaultContext(ctx)
	caller, err := api.server.vaultAdmit(ctx, "rotate", vaultOperatorOnly)
	if err != nil {
		return nil, err
	}
	recoveryKey, err := api.server.vaults.Rotate(request.GetNewRecoveryKey())
	api.server.vaultAudit(caller, vaults.AuditEntry{Action: "rotate", Outcome: outcome(err)})
	if err != nil {
		return nil, domainFailure(err)
	}
	value, err := api.server.vaultStatus(caller)
	if err != nil {
		return nil, err
	}
	return &dieterv1.RotateVaultResponse{Status: value, RecoveryKey: recoveryKey}, nil
}

func (api *vaultAPI) ListVaultItems(ctx context.Context, request *dieterv1.ListVaultItemsRequest) (*dieterv1.VaultItemsResponse, error) {
	ctx = vaultContext(ctx)
	if _, err := api.server.vaultAdmit(ctx, "list", 0); err != nil {
		return nil, err
	}
	items, err := api.server.vaults.ListItems()
	if err != nil {
		return nil, domainFailure(err)
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

func (api *vaultAPI) GetVaultItem(ctx context.Context, request *dieterv1.VaultItemRef) (*dieterv1.VaultItem, error) {
	ctx = vaultContext(ctx)
	if _, err := api.server.vaultAdmit(ctx, "show", 0); err != nil {
		return nil, err
	}
	item, err := api.server.vaults.Item(request.GetItem())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoVaultItem(item), nil
}

func (api *vaultAPI) RevealVaultItem(ctx context.Context, request *dieterv1.RevealVaultItemRequest) (*dieterv1.RevealVaultItemResponse, error) {
	ctx = vaultContext(ctx)
	purpose := request.GetPurpose()
	switch purpose {
	case "":
		purpose = "get"
	case "get", "totp", "exec":
	default:
		return nil, fault.New(fault.Invalid, "purpose must be get, totp or exec")
	}
	fields := request.GetFields()
	if len(fields) == 0 {
		fields = []string{"password"}
	}
	if len(fields) > len(vault.Fields) {
		return nil, fault.New(fault.Invalid, "too many fields")
	}
	caller, err := api.server.vaultAdmit(ctx, purpose, 0)
	if err != nil {
		return nil, err
	}
	item, err := api.server.vaults.Item(request.GetItem())
	if err != nil {
		api.server.vaultAudit(caller, vaults.AuditEntry{Action: purpose, Detail: request.GetItem(), Outcome: "failed"})
		return nil, domainFailure(err)
	}
	now := time.Now()
	response := &dieterv1.RevealVaultItemResponse{Item: protoVaultItem(item), Values: map[string]string{}}
	for _, field := range fields {
		value, err := item.Item.Field(field, now)
		if err != nil {
			return nil, fault.New(fault.Invalid, err.Error())
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
	api.server.vaultAudit(caller, vaults.AuditEntry{Action: purpose, ItemID: item.ID, ItemName: item.Item.Name, Fields: strings.Join(fields, ","), Outcome: "allowed"})
	return response, nil
}

func (api *vaultAPI) CreateVaultItem(ctx context.Context, request *dieterv1.CreateVaultItemRequest) (*dieterv1.VaultItem, error) {
	ctx = vaultContext(ctx)
	caller, err := api.server.vaultAdmit(ctx, "create", 0)
	if err != nil {
		return nil, err
	}
	password, err := vaultPassword(request.GetPassword(), request.GetGeneratePassword(), request.GetPasswordLength(), request.GetPasswordWithoutSymbols())
	if err != nil {
		return nil, fault.New(fault.Invalid, err.Error())
	}
	totp, err := canonicalTOTP(request.GetTotp())
	if err != nil {
		return nil, fault.New(fault.Invalid, err.Error())
	}
	item := vault.Item{Name: strings.TrimSpace(request.GetName()), URLs: request.GetUrls(), Username: request.GetUsername(), Password: password, TOTP: totp, Notes: request.GetNotes()}
	created, err := api.server.vaults.CreateItem(item, caller.actor())
	if err != nil {
		return nil, domainFailure(err)
	}
	api.server.vaultAudit(caller, vaults.AuditEntry{Action: "create", ItemID: created.ID, ItemName: created.Item.Name, Outcome: "allowed"})
	return protoVaultItem(created), nil
}

func (api *vaultAPI) UpdateVaultItem(ctx context.Context, request *dieterv1.UpdateVaultItemRequest) (*dieterv1.VaultItem, error) {
	ctx = vaultContext(ctx)
	caller, err := api.server.vaultAdmit(ctx, "update", 0)
	if err != nil {
		return nil, err
	}
	var password *string
	if request.Password != nil || request.GetGeneratePassword() {
		value, err := vaultPassword(request.GetPassword(), request.GetGeneratePassword(), request.GetPasswordLength(), request.GetPasswordWithoutSymbols())
		if err != nil {
			return nil, fault.New(fault.Invalid, err.Error())
		}
		password = &value
	}
	var totp *string
	if request.Totp != nil {
		value, err := canonicalTOTP(request.GetTotp())
		if err != nil {
			return nil, fault.New(fault.Invalid, err.Error())
		}
		totp = &value
	}
	var changed []string
	updated, err := api.server.vaults.UpdateItem(request.GetItem(), func(item *vault.Item) error {
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
			return fault.New(fault.Invalid, "nothing to update")
		}
		return item.Validate()
	}, caller.actor())
	if err != nil {
		return nil, domainFailure(err)
	}
	api.server.vaultAudit(caller, vaults.AuditEntry{Action: "update", ItemID: updated.ID, ItemName: updated.Item.Name, Fields: strings.Join(changed, ","), Outcome: "allowed"})
	return protoVaultItem(updated), nil
}

func (api *vaultAPI) DeleteVaultItem(ctx context.Context, request *dieterv1.VaultItemRef) (*dieterv1.VaultItem, error) {
	ctx = vaultContext(ctx)
	caller, err := api.server.vaultAdmit(ctx, "delete", 0)
	if err != nil {
		return nil, err
	}
	deleted, err := api.server.vaults.DeleteItem(request.GetItem())
	if err != nil {
		return nil, domainFailure(err)
	}
	api.server.vaultAudit(caller, vaults.AuditEntry{Action: "delete", ItemID: deleted.ID, ItemName: deleted.Item.Name, Outcome: "allowed"})
	return protoVaultItem(deleted), nil
}

func (api *vaultAPI) ListVaultAudit(ctx context.Context, request *dieterv1.ListVaultAuditRequest) (*dieterv1.VaultAuditResponse, error) {
	ctx = vaultContext(ctx)
	if _, err := api.server.vaultAdmit(ctx, "audit", vaultOperatorOnly); err != nil {
		return nil, err
	}
	itemID := strings.TrimSpace(request.GetItem())
	if itemID != "" && !strings.HasPrefix(itemID, "vi_") {
		item, err := api.server.vaults.Item(itemID)
		if err != nil {
			return nil, domainFailure(err)
		}
		itemID = item.ID
	}
	entries, err := api.server.vaults.Audit(int(request.GetLimit()), itemID, strings.TrimSpace(request.GetCardId()))
	if err != nil {
		return nil, err
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
