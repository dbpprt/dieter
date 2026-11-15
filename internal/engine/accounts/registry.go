package accounts

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/kv"
)

// registry is one read of the three namespaces.
type registry struct {
	accounts map[string]kv.ProviderAccountEntry
	defaults map[string]string
	// logins maps account ID → daemon ID → live login record.
	logins map[string]map[string]schema.ProviderLoginRecord
}

func (s *Service) load() (registry, error) {
	r := registry{accounts: map[string]kv.ProviderAccountEntry{}, defaults: map[string]string{}, logins: map[string]map[string]schema.ProviderLoginRecord{}}
	if err := s.store.KV.EachProviderAccount(func(entry kv.ProviderAccountEntry) error {
		r.accounts[entry.ID] = entry
		return nil
	}); err != nil {
		return r, err
	}
	if err := s.store.KV.EachProviderDefault(func(provider string, value schema.ProviderDefaultRecord) error {
		r.defaults[provider] = value.AccountID
		return nil
	}); err != nil {
		return r, err
	}
	var roster map[string]bool
	if s.opts.Roster != nil {
		roster = s.opts.Roster()
	}
	daemon := s.daemonID()
	err := s.store.KV.EachProviderLogin("", false, func(entry kv.ProviderLoginEntry) error {
		// A daemon that left the roster no longer speaks for its logins.
		if roster != nil && !roster[entry.DaemonID] && entry.DaemonID != daemon {
			return nil
		}
		if r.logins[entry.AccountID] == nil {
			r.logins[entry.AccountID] = map[string]schema.ProviderLoginRecord{}
		}
		r.logins[entry.AccountID][entry.DaemonID] = entry.Record
		return nil
	})
	return r, err
}

// live returns a live (not removed) account record.
func (r registry) live(id string) (schema.ProviderAccountRecord, bool) {
	entry, ok := r.accounts[id]
	if !ok || entry.Deleted {
		return schema.ProviderAccountRecord{}, false
	}
	return entry.Record, true
}

// signedIn reports whether daemon has a usable login of account.
func (r registry) signedIn(account, daemon string) bool {
	login, ok := r.logins[account][daemon]
	return ok && login.State == StateSignedIn
}

func (r registry) account(id string) (Account, bool) {
	record, ok := r.live(id)
	if !ok {
		return Account{}, false
	}
	account := Account{
		ID: id, Provider: record.Provider, Label: record.Label, Method: record.Method,
		IncludeInSummary: record.IncludeInSummary, IsDefault: r.defaults[record.Provider] == id,
		CreatedAt: record.CreatedAt, CreatedBy: record.CreatedBy,
	}
	if record.Identity != nil {
		account.Identity = *record.Identity
	}
	daemons := make([]string, 0, len(r.logins[id]))
	for daemon := range r.logins[id] {
		daemons = append(daemons, daemon)
	}
	sort.Strings(daemons)
	var tokens TokenUsage
	for _, daemon := range daemons {
		login := r.logins[id][daemon]
		machine := MachineLogin{DaemonID: daemon, State: login.State, Method: login.Method, VerifiedAt: login.VerifiedAt, Usage: login.Usage, DieterTokens: login.DieterTokens}
		if login.Identity != nil {
			machine.Identity = *login.Identity
		}
		if login.Error != nil {
			machine.ErrorCode, machine.ErrorMessage = login.Error.Code, login.Error.Message
		}
		account.Logins = append(account.Logins, machine)
		if login.Usage != nil && (account.Usage == nil || newer(login.Usage.ObservedAt, account.Usage.ObservedAt)) {
			account.Usage = login.Usage
		}
		if t := login.DieterTokens; t != nil {
			tokens.FiveHour = addTotals(tokens.FiveHour, t.FiveHour)
			tokens.SevenDay = addTotals(tokens.SevenDay, t.SevenDay)
			if newer(t.ObservedAt, tokens.ObservedAt) {
				tokens.ObservedAt = t.ObservedAt
			}
		}
	}
	if tokens.ObservedAt != "" {
		account.DieterTokens = &tokens
	}
	return account, true
}

// List returns accounts in creation order; provider "" lists every provider.
func (s *Service) List(_ context.Context, provider string) ([]Account, error) {
	if provider != "" && !schema.ValidProvider(provider) {
		return nil, fault.Invalidf("unknown provider %q", provider)
	}
	r, err := s.load()
	if err != nil {
		return nil, err
	}
	accounts := make([]Account, 0, len(r.accounts))
	for id := range r.accounts {
		if account, ok := r.account(id); ok && (provider == "" || account.Provider == provider) {
			accounts = append(accounts, account)
		}
	}
	sort.Slice(accounts, func(i, j int) bool {
		if accounts[i].CreatedAt != accounts[j].CreatedAt {
			return accounts[i].CreatedAt < accounts[j].CreatedAt
		}
		return accounts[i].ID < accounts[j].ID
	})
	return accounts, nil
}

// get returns one live account.
func (s *Service) get(id string) (Account, error) {
	r, err := s.load()
	if err != nil {
		return Account{}, err
	}
	account, ok := r.account(id)
	if !ok {
		return Account{}, fault.NotFoundf("provider account %s not found", id)
	}
	return account, nil
}

// Create adds an account. Accounts with host or environment logins come only
// from adoption.
func (s *Service) Create(_ context.Context, in CreateInput) (Account, error) {
	method := in.Method
	if method == "" {
		method = MethodClaudeCode
		if in.Provider == ProviderChatGPT {
			method = MethodCodex
		}
	}
	if !schema.ValidProvider(in.Provider) {
		return Account{}, fault.Invalidf("unknown provider %q", in.Provider)
	}
	if method == MethodHost || method == MethodEnvironment {
		return Account{}, fault.New(fault.Invalid, "accounts that use this machine's own login or an API key are added automatically")
	}
	if !schema.ProviderMethodAllowed(in.Provider, method) {
		return Account{}, fault.Invalidf("%s accounts cannot use the %s login", providerName(in.Provider), method)
	}
	id := in.AccountID
	if id == "" {
		id = newAccountID()
	} else if !schema.ValidProviderAccountID(id) {
		return Account{}, fault.New(fault.Invalid, "an account ID is pa_ followed by 26 lowercase base32 characters")
	}
	if err := s.createAccount(id, in.Provider, strings.TrimSpace(in.Label), method, nil); err != nil {
		return Account{}, err
	}
	return s.get(id)
}

// createAccount writes a new account record; an identical existing one is
// an idempotent retry. The provider's first account becomes its default.
func (s *Service) createAccount(id, provider, label, method string, identity *Identity) error {
	daemon, err := s.writerDaemon()
	if err != nil {
		return err
	}
	if !schema.ValidProviderLabel(label) {
		return fault.New(fault.Invalid, "an account label is 1 to 60 characters on one line")
	}
	if identity != nil {
		identity = identityPointer(*identity)
	}
	record := schema.ProviderAccountRecord{
		Provider: provider, Label: label, Method: method, Identity: identity,
		IncludeInSummary: true, CreatedAt: s.timestamp(), CreatedBy: daemon,
	}
	_, err = s.store.KV.PutProviderAccount(id, func(current *schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
		if current != nil {
			if current.Provider == provider && current.Method == method && current.Label == label {
				return nil, nil
			}
			return nil, fault.New(fault.AlreadyExists, "a different provider account already has this ID")
		}
		return &record, nil
	})
	if err != nil {
		return err
	}
	r, err := s.load()
	if err != nil {
		return err
	}
	if _, ok := r.live(r.defaults[provider]); !ok {
		return s.store.KV.PutProviderDefault(provider, id)
	}
	return nil
}

// Update renames an account or changes whether it counts in summaries.
func (s *Service) Update(_ context.Context, id string, label *string, includeInSummary *bool) (Account, error) {
	if _, err := s.writerDaemon(); err != nil {
		return Account{}, err
	}
	var trimmed string
	if label != nil {
		trimmed = strings.TrimSpace(*label)
		if !schema.ValidProviderLabel(trimmed) {
			return Account{}, fault.New(fault.Invalid, "an account label is 1 to 60 characters on one line")
		}
	}
	_, err := s.store.KV.PutProviderAccount(id, func(current *schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
		if current == nil {
			return nil, fault.NotFoundf("provider account %s not found", id)
		}
		next := *current
		if label != nil {
			next.Label = trimmed
		}
		if includeInSummary != nil {
			next.IncludeInSummary = *includeInSummary
		}
		return &next, nil
	})
	if errors.Is(err, kv.ErrProviderAccountRemoved) {
		return Account{}, fault.NotFoundf("provider account %s not found", id)
	}
	if err != nil {
		return Account{}, err
	}
	return s.get(id)
}

// Delete removes an account everywhere. Every machine signs its managed
// login out and deletes the account's files when it sees the tombstone.
func (s *Service) Delete(_ context.Context, id string) error {
	if _, err := s.writerDaemon(); err != nil {
		return err
	}
	r, err := s.load()
	if err != nil {
		return err
	}
	record, ok := r.live(id)
	if !ok {
		return fault.NotFoundf("provider account %s not found", id)
	}
	if err := s.store.KV.DeleteProviderAccount(id); err != nil {
		return err
	}
	if r.defaults[record.Provider] == id {
		if err := s.store.KV.DeleteProviderDefault(record.Provider); err != nil {
			return err
		}
	}
	s.requestBackground()
	return nil
}

// SetDefault makes an account its provider's default.
func (s *Service) SetDefault(_ context.Context, id string) (Account, error) {
	if _, err := s.writerDaemon(); err != nil {
		return Account{}, err
	}
	account, err := s.get(id)
	if err != nil {
		return Account{}, err
	}
	if err := s.store.KV.PutProviderDefault(account.Provider, id); err != nil {
		return Account{}, err
	}
	return s.get(id)
}

// identityKey is the stable identity of a login: Claude organization and
// email, the ChatGPT account, or the Sign in with ChatGPT subject and
// workspace. "" means unknown.
func identityKey(provider, method string, identity Identity) string {
	switch {
	case method == MethodEnvironment:
		return identity.Subject
	case method == MethodSIWC:
		if identity.Subject == "" {
			return ""
		}
		return "siwc:" + identity.Subject + "/" + identity.WorkspaceID
	case provider == ProviderClaude:
		if identity.Email == "" && identity.OrganizationID == "" {
			return ""
		}
		return "claude:" + identity.OrganizationID + "/" + strings.ToLower(strings.TrimSpace(identity.Email))
	case provider == ProviderChatGPT:
		if identity.WorkspaceID != "" {
			return "chatgpt:" + identity.WorkspaceID
		}
		if identity.Email != "" {
			return "chatgpt-email:" + strings.ToLower(strings.TrimSpace(identity.Email))
		}
	}
	return ""
}

// mismatchError describes a sign-in as someone else.
type mismatchError struct{ got, want Identity }

func (e *mismatchError) Error() string {
	return fmt.Sprintf("signed in as %s, this account is %s", describeIdentity(e.got), describeIdentity(e.want))
}

func describeIdentity(identity Identity) string {
	for _, value := range []string{identity.Email, identity.Subject, identity.WorkspaceID, identity.OrganizationID} {
		if value != "" {
			return value
		}
	}
	return "an unknown account"
}

// bindIdentity binds verified to the account if it has no identity yet
// (compare-and-set: the first verified sign-in wins) and fails with a
// mismatchError when the account belongs to someone else.
func (s *Service) bindIdentity(id string, verified Identity) (Identity, error) {
	verified = cleanIdentity(verified)
	var bound Identity
	_, err := s.store.KV.PutProviderAccount(id, func(current *schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error) {
		if current == nil {
			return nil, fault.NotFoundf("provider account %s not found", id)
		}
		key := identityKey(current.Provider, current.Method, verified)
		if key == "" {
			return nil, fault.New(fault.FailedPrecondition, "the provider did not report who signed in")
		}
		if current.Identity != nil && identityKey(current.Provider, current.Method, *current.Identity) != "" {
			if identityKey(current.Provider, current.Method, *current.Identity) != key {
				return nil, &mismatchError{got: verified, want: *current.Identity}
			}
			bound = *current.Identity
			return nil, nil
		}
		next := *current
		identity := verified
		next.Identity = &identity
		bound = identity
		return &next, nil
	})
	if errors.Is(err, kv.ErrProviderAccountRemoved) {
		return Identity{}, fault.NotFoundf("provider account %s not found", id)
	}
	return bound, err
}

// updateLogin changes this machine's login record of an account. change
// receives a copy of the current record (zero with exists false when absent)
// and reports whether to write it.
func (s *Service) updateLogin(accountID string, change func(record *schema.ProviderLoginRecord, exists bool) bool) error {
	daemon, err := s.writerDaemon()
	if err != nil {
		return err
	}
	s.loginMu.Lock()
	defer s.loginMu.Unlock()
	var current schema.ProviderLoginRecord
	exists := false
	if err := s.store.KV.EachProviderLogin(schema.ProviderLoginKey(accountID, daemon), false, func(entry kv.ProviderLoginEntry) error {
		if entry.AccountID == accountID && entry.DaemonID == daemon {
			current, exists = entry.Record, true
		}
		return nil
	}); err != nil {
		return err
	}
	if !change(&current, exists) {
		return nil
	}
	return s.store.KV.PutProviderLogin(accountID, daemon, current)
}

// ownLogin is this machine's login record of an account.
func (r registry) ownLogin(accountID, daemon string) (schema.ProviderLoginRecord, bool) {
	login, ok := r.logins[accountID][daemon]
	return login, ok
}

func identityPointer(identity Identity) *Identity {
	identity = cleanIdentity(identity)
	if identity.Empty() {
		return nil
	}
	return &identity
}

// cleanIdentity bounds provider-reported identity fields to the record
// schema.
func cleanIdentity(identity Identity) Identity {
	return Identity{
		Email: singleLine(identity.Email, 256), Organization: singleLine(identity.Organization, 256),
		OrganizationID: singleLine(identity.OrganizationID, 256), WorkspaceID: singleLine(identity.WorkspaceID, 256),
		Subject: singleLine(identity.Subject, 256), Plan: singleLine(identity.Plan, 64),
	}
}

// newer reports whether timestamp a is later than b; "" is the oldest.
func newer(a, b string) bool {
	if b == "" {
		return a != ""
	}
	at, aErr := time.Parse(time.RFC3339Nano, a)
	bt, bErr := time.Parse(time.RFC3339Nano, b)
	if aErr != nil || bErr != nil {
		return a > b
	}
	return at.After(bt)
}

func addTotals(a, b TokenTotals) TokenTotals {
	return TokenTotals{Input: a.Input + b.Input, Output: a.Output + b.Output, Total: a.Total + b.Total}
}
