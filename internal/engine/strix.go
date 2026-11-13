package engine

import (
	"strings"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/vaults"
)

// Strix conversations run an autonomous pentesting agent against their
// worktree and any targets a person configured. They follow extra rules:
//   - only a worktree workspace, because Strix's agents can edit the files
//     they test (the checkout is mounted writable into its sandbox);
//   - the model credentials come from a vault item and reach only the Strix
//     process environment;
//   - agent channel messages neither steer nor wake them, and agent turns
//     cannot start or continue them (see the API's requireHumanForStrix).
const strixAdapter = "strix"

// strixNoteSettings are the Strix settings a credentials item's notes may set
// as KEY=VALUE lines. The harness runtime forwards exactly these to Strix.
var strixNoteSettings = map[string]bool{
	"STRIX_LLM":                            true,
	"STRIX_API_TYPE":                       true,
	"STRIX_LLM_INPUT_COST_PER_MTOK":        true,
	"STRIX_LLM_OUTPUT_COST_PER_MTOK":       true,
	"STRIX_LLM_CACHED_INPUT_COST_PER_MTOK": true,
	"LLM_API_BASE":                         true,
	"LLM_EXTRA_HEADERS":                    true,
	"LLM_EXTRA_BODY":                       true,
	"PERPLEXITY_API_KEY":                   true,
	"EXA_API_KEY":                          true,
	"STRIX_WEB_SEARCH_PROVIDER":            true,
	"STRIX_EXA_SEARCH_TYPE":                true,
	"STRIX_EXA_NUM_RESULTS":                true,
	"POSTMAN_API_KEY":                      true,
}

// strixNoteSecrets are the note settings whose values the transcript redacts.
var strixNoteSecrets = map[string]bool{
	"LLM_EXTRA_HEADERS":  true,
	"PERPLEXITY_API_KEY": true,
	"EXA_API_KEY":        true,
	"POSTMAN_API_KEY":    true,
}

// IsStrixProvider reports whether provider is a harness backed by Strix.
func (s *Service) IsStrixProvider(provider string) bool {
	if s.Catalog == nil || strings.TrimSpace(provider) == "" {
		return false
	}
	adapter, ok := s.Catalog.ResolveAdapter(provider)
	return ok && adapter.Runtime == strixAdapter
}

// requireStrixWorktree refuses a Strix conversation in a shared checkout.
func requireStrixWorktree(mode string) error {
	if normalized, err := kanban.NormalizeWorkspaceMode(mode); err != nil || normalized != model.WorkspaceModeWorktree {
		return fault.New(fault.FailedPrecondition, "Strix conversations need a worktree workspace: Strix's agents can edit the files they test")
	}
	return nil
}

// strixCredentials reads the conversation's credentials vault item into the
// environment Strix reads: the password is LLM_API_KEY, the first URL is
// LLM_API_BASE, and notes may set the settings in strixNoteSettings. It
// returns the secret values for transcript redaction.
func (s *Service) strixCredentials(cardID string, options map[string]string) (map[string]string, []string, error) {
	ref := strings.TrimSpace(options["credentials"])
	if ref == "" {
		return nil, nil, fault.New(fault.Invalid, "Strix needs a credentials vault item; set the credentials option")
	}
	store := vaults.New(s.Store)
	audit := vaults.AuditEntry{Action: "strix", Caller: "strix", CardID: cardID, Detail: ref}
	item, err := store.Item(ref)
	if err != nil {
		audit.Outcome = "failed"
		_ = store.AppendAudit(audit)
		return nil, nil, fault.FailedPreconditionf("Strix credentials %q: %v; the vault item's password must be the model API key", ref, err)
	}
	environment := map[string]string{}
	var secrets []string
	if password := strings.TrimSpace(item.Item.Password); password != "" {
		environment["LLM_API_KEY"] = password
		secrets = append(secrets, password)
	}
	if len(item.Item.URLs) > 0 && strings.TrimSpace(item.Item.URLs[0]) != "" {
		environment["LLM_API_BASE"] = strings.TrimSpace(item.Item.URLs[0])
	}
	for _, line := range strings.Split(item.Item.Notes, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		if !ok || !strixNoteSettings[key] || value == "" {
			continue
		}
		environment[key] = value
		if strixNoteSecrets[key] {
			secrets = append(secrets, value)
		}
	}
	audit.ItemID, audit.ItemName, audit.Fields, audit.Outcome = item.ID, item.Item.Name, "password,url,notes", "allowed"
	_ = store.AppendAudit(audit)
	return environment, secrets, nil
}

// strixTurn is what a Strix turn adds to its harness request: the
// credentials environment and the secret values to redact.
type strixTurn struct {
	environment map[string]string
	secrets     []string
}

// prepareStrixTurn checks a Strix turn before admission and resolves its
// credentials, so a missing vault item fails before any turn state exists.
func (s *Service) prepareStrixTurn(card model.Card, runtimeModel string, options map[string]string) (strixTurn, error) {
	if err := requireStrixWorktree(card.WorkspaceMode); err != nil {
		return strixTurn{}, err
	}
	environment, secrets, err := s.strixCredentials(card.ID, options)
	if err != nil {
		return strixTurn{}, err
	}
	if runtimeModel == "" && environment["STRIX_LLM"] == "" {
		return strixTurn{}, fault.New(fault.Invalid, "choose a Strix model, or set STRIX_LLM in the credentials vault item's notes")
	}
	return strixTurn{environment: environment, secrets: secrets}, nil
}

// apply adds the credentials to request once its turn is active, and records
// the secrets so the turn's transcript never stores them. A changes-only scan
// covers the worktree's commits since it left its base branch: Strix diffs
// against merge-base(DiffBase, HEAD), so the base branch's current tip stays
// correct after a rebase.
func (t strixTurn) apply(s *Service, cardID string, workspace model.Workspace, request *harness.Request) {
	for _, base := range []string{workspace.CurrentBaseSHA, workspace.BaseSHA, workspace.BaseBranch} {
		if base != "" {
			request.DiffBase = base
			break
		}
	}
	if request.Environment == nil {
		request.Environment = map[string]string{}
	}
	for key, value := range t.environment {
		request.Environment[key] = value
	}
	s.RegisterVaultSecrets(cardID, t.secrets...)
}

func (s *Service) hasQueuedMessages(cardID string) bool {
	conversation, err := s.Store.Conversations.Get(cardID)
	return err == nil && len(conversation.Queue) > 0
}

// moveFinishedScanToReview does for a finished Strix scan what a coding agent
// does when its task is done: it moves the board card from Running to Review,
// where its findings wait for a person.
func (s *Service) moveFinishedScanToReview(cardID string) {
	detail, err := s.Store.Kanban.CardDetail(cardID)
	if err != nil || detail.Card.Scope != model.ConversationScopeBoard || detail.Card.Lane != model.LaneRunning ||
		detail.Card.Runtime != "idle" || detail.Board.Workflow != model.WorkflowReview {
		return
	}
	_, _ = s.Store.Kanban.MoveCard(cardID, model.LaneReview, nil)
}
