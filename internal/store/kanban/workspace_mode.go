package kanban

import (
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
)

func validWorkspaceMode(value string) bool {
	switch value {
	case model.WorkspaceModeProject, model.WorkspaceModeWorktree:
		return true
	default:
		return false
	}
}

func NormalizeWorkspaceMode(value string) (string, error) {
	if strings.TrimSpace(value) == "" {
		return model.WorkspaceModeProject, nil
	}
	value, ok := model.CanonicalWorkspaceMode(value)
	if !ok || !validWorkspaceMode(value) {
		return "", fault.New(fault.Invalid, "workspace mode must be project or worktree")
	}
	return value, nil
}
