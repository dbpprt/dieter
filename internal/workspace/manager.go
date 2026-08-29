package workspace

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/gitexec"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

var branchUnsafe = regexp.MustCompile(`[^a-zA-Z0-9._-]+`)

type Manager struct {
	Store *store.Store
	Git   gitexec.Runner
	Log   *slog.Logger
}

func New(data *store.Store, logger *slog.Logger) *Manager {
	if logger == nil {
		logger = slog.Default()
	}
	manager := &Manager{Store: data, Git: gitexec.ExecRunner{}, Log: logger}
	return manager
}

func (m *Manager) SetGitRunner(runner gitexec.Runner) {
	if runner != nil {
		m.Git = runner
	}
}

func validMode(value string) bool {
	switch value {
	case model.WorkspaceModeProject, model.WorkspaceModeWorktree:
		return true
	default:
		return false
	}
}

func selectedMode(card model.Card) (string, error) {
	if strings.TrimSpace(card.WorkspaceMode) == "" {
		return model.WorkspaceModeProject, nil
	}
	mode, ok := model.CanonicalWorkspaceMode(card.WorkspaceMode)
	if !ok || !validMode(mode) {
		return "", errors.New("workspace mode must be project or worktree")
	}
	return mode, nil
}

func (m *Manager) Ensure(ctx context.Context, cardRef string) (model.Workspace, error) {
	if existing, err := m.Store.Workspace(cardRef); err == nil {
		if existing.State == model.WorkspaceStateReady || existing.State == model.WorkspaceStateConflicted {
			return m.Refresh(ctx, existing.CardID, false)
		} else if existing.State == model.WorkspaceStateCleanupPending || existing.State == model.WorkspaceStateRecoveryRequired {
			return m.Refresh(ctx, existing.CardID, false)
		}
	} else if !errors.Is(err, store.ErrNotFound) {
		return model.Workspace{}, err
	}
	detail, err := m.Store.CardDetail(cardRef)
	if err != nil {
		return model.Workspace{}, err
	}
	if workspaces, listErr := m.Store.ListWorkspaces(detail.Project.ID); listErr == nil {
		for _, candidate := range workspaces {
			for _, previousID := range candidate.PreviousCardIDs {
				if previousID == detail.Card.ID {
					return model.Workspace{}, fmt.Errorf("workspace was adopted by conversation %s", candidate.CardID)
				}
			}
		}
	}
	mode, err := selectedMode(detail.Card)
	if err != nil {
		return model.Workspace{}, err
	}
	release, err := m.lock(ctx, "workspace-"+detail.Card.ID)
	if err != nil {
		return model.Workspace{}, err
	}
	defer release()
	if existing, err := m.Store.WorkspaceByCardID(detail.Card.ID); err == nil && (existing.State == model.WorkspaceStateReady || existing.State == model.WorkspaceStateConflicted) {
		return m.Refresh(ctx, detail.Card.ID, false)
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	value := model.Workspace{
		CardID: detail.Card.ID, ProjectID: detail.Project.ID, Mode: mode, State: model.WorkspaceStateProvisioning,
		BaseRemote: strings.TrimSpace(detail.Project.BaseRemote), BaseBranch: strings.TrimSpace(detail.Card.WorkspaceBaseBranch),
		Branch: strings.TrimSpace(detail.Card.WorkspaceBranch), CreatedAt: now, UpdatedAt: now, LastActivityAt: now,
	}
	if value.BaseBranch == "" {
		value.BaseBranch = strings.TrimSpace(detail.Project.BaseBranch)
	}
	if _, err := m.Store.SaveWorkspace(value); err != nil {
		return model.Workspace{}, err
	}
	value, err = m.provision(ctx, detail, value)
	if err != nil {
		value.State = model.WorkspaceStateFailed
		_, _ = m.Store.SaveWorkspace(value)
		return model.Workspace{}, err
	}
	value.State = model.WorkspaceStateReady
	if _, err := m.Store.SaveWorkspace(value); err != nil {
		return model.Workspace{}, err
	}
	return m.Refresh(ctx, value.CardID, false)
}

func (m *Manager) provision(ctx context.Context, detail model.CardDetail, value model.Workspace) (model.Workspace, error) {
	projectPath := detail.Project.Path
	currentBranch, _ := m.output(ctx, projectPath, "symbolic-ref", "--quiet", "--short", "HEAD")
	if value.BaseBranch == "" {
		value.BaseBranch = currentBranch
	}
	if value.BaseRemote == "" {
		if _, err := m.Git.Run(ctx, projectPath, "remote", "get-url", "origin"); err == nil {
			value.BaseRemote = "origin"
		}
	}
	baseRef := value.BaseBranch
	if baseRef == "" {
		baseRef = "HEAD"
	}
	baseSHA, baseErr := m.output(ctx, projectPath, "rev-parse", "--verify", baseRef+"^{commit}")
	if baseErr != nil && value.Mode == model.WorkspaceModeWorktree {
		return value, fmt.Errorf("resolve base branch %q: %w", baseRef, baseErr)
	}
	value.BaseSHA = baseSHA
	value.CurrentBaseSHA = baseSHA
	switch value.Mode {
	case model.WorkspaceModeProject:
		value.Path = projectPath
		value.Branch = currentBranch
		value.ManagedBranch = false
		value.LegacyUnmanaged = detail.Card.InitialPromptSentAt != ""
		return value, nil
	case model.WorkspaceModeWorktree:
		if value.Branch == "" {
			value.Branch = branchName(detail.Card)
			value.ManagedBranch = true
		}
		value.Path = filepath.Join(m.Store.WorktreeRoot(), detail.Project.ID, detail.Card.ID)
		release, err := m.lock(ctx, "repository-"+detail.Project.ID)
		if err != nil {
			return value, err
		}
		defer release()
		if info, statErr := os.Stat(value.Path); statErr == nil && info.IsDir() {
			if _, verifyErr := m.Git.Run(ctx, value.Path, "rev-parse", "--is-inside-work-tree"); verifyErr == nil {
				return value, nil
			}
			return value, errors.New("workspace path exists but is not a Git worktree")
		} else if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
			return value, statErr
		}
		if err := os.MkdirAll(filepath.Dir(value.Path), 0o755); err != nil {
			return value, err
		}
		args := []string{"worktree", "add"}
		if _, err := m.Git.Run(ctx, projectPath, "show-ref", "--verify", "--quiet", "refs/heads/"+value.Branch); err == nil {
			args = append(args, value.Path, value.Branch)
		} else {
			args = append(args, "-b", value.Branch, value.Path, baseRef)
		}
		if _, err := m.Git.Run(ctx, projectPath, args...); err != nil {
			return value, fmt.Errorf("create Git worktree: %w", err)
		}
		return value, nil
	default:
		return value, errors.New("unsupported workspace mode")
	}
}

func branchName(card model.Card) string {
	title := strings.ToLower(strings.TrimSpace(card.Title))
	title = branchUnsafe.ReplaceAllString(title, "-")
	title = strings.Trim(title, "-._")
	if len(title) > 36 {
		title = strings.Trim(title[:36], "-._")
	}
	shortID := strings.TrimPrefix(card.ID, "c_")
	if len(shortID) > 12 {
		shortID = shortID[:12]
	}
	if title == "" {
		return "dieter/" + shortID
	}
	return "dieter/" + shortID + "-" + title
}

func (m *Manager) Refresh(ctx context.Context, cardRef string, includeSize bool) (model.Workspace, error) {
	value, err := m.Store.Workspace(cardRef)
	if err != nil {
		return model.Workspace{}, err
	}
	if _, err := os.Stat(value.Path); err != nil {
		value.State = model.WorkspaceStateOrphaned
		return m.Store.UpdateWorkspaceGitState(value, includeSize)
	}
	currentBranch, _ := m.output(ctx, value.Path, "symbolic-ref", "--quiet", "--short", "HEAD")
	head, headErr := m.output(ctx, value.Path, "rev-parse", "--verify", "HEAD^{commit}")
	if headErr == nil {
		value.HeadSHA = head
	}
	if currentBranch != "" || value.Mode == model.WorkspaceModeProject {
		value.Branch = currentBranch
	}
	status, statusErr := m.Git.Run(ctx, value.Path, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if statusErr == nil {
		value.Dirty = len(status.Output) > 0
	}
	baseRef := value.BaseBranch
	if baseRef != "" {
		if value.BaseRemote != "" {
			remoteRef := value.BaseRemote + "/" + value.BaseBranch
			if _, remoteErr := m.Git.Run(ctx, value.Path, "rev-parse", "--verify", remoteRef+"^{commit}"); remoteErr == nil {
				baseRef = remoteRef
			}
		}
		base, _ := m.output(ctx, value.Path, "rev-parse", "--verify", baseRef+"^{commit}")
		if base != "" {
			value.CurrentBaseSHA = base
			counts, countErr := m.output(ctx, value.Path, "rev-list", "--left-right", "--count", base+"...HEAD")
			if countErr == nil {
				fields := strings.Fields(counts)
				if len(fields) == 2 {
					value.Behind, _ = strconv.Atoi(fields[0])
					value.Ahead, _ = strconv.Atoi(fields[1])
				}
			}
		}
	}
	if includeSize {
		value.SizeBytes = directorySize(value.Path)
	}
	hash := sha256.New()
	_, _ = hash.Write([]byte(value.BaseSHA))
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write([]byte(value.CurrentBaseSHA))
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write([]byte(value.HeadSHA))
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write(status.Output)
	if diff, diffErr := m.Git.Run(ctx, value.Path, "diff", "--no-ext-diff", "--binary", "HEAD", "--"); diffErr == nil {
		_, _ = hash.Write(diff.Output)
	}
	if untracked, untrackedErr := m.Git.Run(ctx, value.Path, "ls-files", "--others", "--exclude-standard", "-z"); untrackedErr == nil {
		for _, relative := range bytesZeroFields(untracked.Output) {
			_, _ = hash.Write([]byte(relative))
			if raw, readErr := os.ReadFile(filepath.Join(value.Path, filepath.FromSlash(relative))); readErr == nil {
				_, _ = hash.Write(raw)
			}
		}
	}
	value.Revision = hex.EncodeToString(hash.Sum(nil)[:16])
	if value.State != model.WorkspaceStateConflicted && value.State != model.WorkspaceStateRecoveryRequired && value.State != model.WorkspaceStateCleanupPending {
		value.State = model.WorkspaceStateReady
	}
	value.LastActivityAt = time.Now().UTC().Format(time.RFC3339Nano)
	return m.Store.UpdateWorkspaceGitState(value, includeSize)
}

func bytesZeroFields(raw []byte) []string {
	parts := strings.Split(string(raw), "\x00")
	result := parts[:0]
	for _, part := range parts {
		if part != "" {
			result = append(result, part)
		}
	}
	return result
}

func (m *Manager) ResolvePath(ctx context.Context, cardRef string) (model.Workspace, error) {
	return m.Ensure(ctx, cardRef)
}

func (m *Manager) LockWorkspace(ctx context.Context, cardID string) (func(), error) {
	return m.lock(ctx, "workspace-"+cardID)
}

func (m *Manager) LockRepository(ctx context.Context, projectID string) (func(), error) {
	return m.lock(ctx, "repository-"+projectID)
}

func (m *Manager) LockCheckout(ctx context.Context, projectID string) (func(), error) {
	return m.lock(ctx, "checkout-"+projectID)
}

func (m *Manager) List(ctx context.Context, projectRef string, refresh, includeSize bool) ([]model.Workspace, error) {
	items, err := m.Store.ListWorkspaces(projectRef)
	if err != nil || !refresh {
		return items, err
	}
	for index := range items {
		if refreshed, refreshErr := m.Refresh(ctx, items[index].CardID, includeSize); refreshErr == nil {
			items[index] = refreshed
		}
	}
	return items, nil
}

func (m *Manager) output(ctx context.Context, directory string, args ...string) (string, error) {
	result, err := m.Git.Run(ctx, directory, args...)
	return gitexec.Output(result), err
}

func (m *Manager) clean(ctx context.Context, directory string) (bool, error) {
	result, err := m.Git.Run(ctx, directory, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	return len(result.Output) == 0, err
}

func directorySize(root string) int64 {
	var total int64
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() && entry.Name() == ".git" {
			return filepath.SkipDir
		}
		if !entry.IsDir() {
			if info, infoErr := entry.Info(); infoErr == nil {
				total += info.Size()
			}
		}
		return nil
	})
	return total
}

func (m *Manager) lock(ctx context.Context, name string) (func(), error) {
	name = branchUnsafe.ReplaceAllString(name, "-")
	dir := filepath.Join(m.Store.RuntimeDir(), "git-locks")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, name)
	for {
		err := os.Mkdir(path, 0o700)
		if err == nil {
			_ = os.WriteFile(filepath.Join(path, "pid"), []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600)
			stop := make(chan struct{})
			go func() {
				ticker := time.NewTicker(15 * time.Second)
				defer ticker.Stop()
				for {
					select {
					case <-stop:
						return
					case now := <-ticker.C:
						_ = os.Chtimes(path, now, now)
					}
				}
			}()
			var once sync.Once
			return func() {
				once.Do(func() {
					close(stop)
					_ = os.RemoveAll(path)
				})
			}, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		if info, statErr := os.Stat(path); statErr == nil && time.Since(info.ModTime()) > 2*time.Minute {
			_ = os.RemoveAll(path)
			continue
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(25 * time.Millisecond):
		}
	}
}
