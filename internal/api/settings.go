package api

import (
	"context"
	"errors"
	"path/filepath"
	"strings"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *settingsAPI) GetHarnesses(ctx context.Context, _ *emptypb.Empty) (*dieterv1.HarnessCatalog, error) {
	return protoHarnessCatalog(api.server.availableHarnesses(ctx)), nil
}

func (api *settingsAPI) GetSettings(context.Context, *emptypb.Empty) (*dieterv1.Settings, error) {
	value, err := api.server.store.Settings()
	if err != nil {
		return nil, err
	}
	return protoSettings(value), nil
}

func (api *settingsAPI) GetSettingsOptions(ctx context.Context, _ *emptypb.Empty) (*dieterv1.SettingsOptions, error) {
	projects, err := api.server.store.ListProjects()
	if err != nil {
		return nil, err
	}
	boards, err := api.server.store.ListBoards("")
	if err != nil {
		return nil, err
	}
	result := &dieterv1.SettingsOptions{Agents: protoHarnessCatalog(api.server.availableHarnesses(ctx))}
	for _, value := range projects {
		result.Projects = append(result.Projects, protoProject(value))
	}
	for _, value := range boards {
		result.Boards = append(result.Boards, protoBoard(value))
	}
	return result, nil
}

func (api *settingsAPI) UpdateSettings(_ context.Context, request *dieterv1.UpdateSettingsRequest) (*dieterv1.Settings, error) {
	value, err := api.server.store.UpdateSettings(modelSettings(request.GetSettings()))
	if err != nil {
		return nil, err
	}
	return protoSettings(value), nil
}

func (api *settingsAPI) GetPromptSettings(context.Context, *emptypb.Empty) (*dieterv1.PromptSettings, error) {
	value, err := api.server.store.Settings()
	if err != nil {
		return nil, err
	}
	return protoPromptSettings(value), nil
}

func (api *settingsAPI) UpdatePromptSettings(_ context.Context, request *dieterv1.UpdatePromptSettingsRequest) (*dieterv1.PromptSettings, error) {
	value, err := api.server.store.UpdatePromptSettings(request.GetPromptTemplate(), request.GetBoardSkillTemplate(), request.GetChatSkillTemplate())
	if err != nil {
		return nil, err
	}
	return protoPromptSettings(value), nil
}

func (api *settingsAPI) SetProjectPromptTemplate(_ context.Context, request *dieterv1.SetScopedPromptTemplateRequest) (*dieterv1.Project, error) {
	template := request.GetPromptTemplate()
	if request.GetInherit() {
		template = ""
	}
	value, err := api.server.store.UpdateProjectPromptTemplate(request.GetScopeId(), template)
	if err != nil {
		return nil, err
	}
	return protoProject(value), nil
}

func (api *settingsAPI) SetBoardPromptTemplate(_ context.Context, request *dieterv1.SetScopedPromptTemplateRequest) (*dieterv1.Board, error) {
	template := request.GetPromptTemplate()
	if request.GetInherit() {
		template = ""
	}
	value, err := api.server.store.UpdateBoardPromptTemplate(request.GetScopeId(), template)
	if err != nil {
		return nil, err
	}
	return protoBoard(value), nil
}

func (api *settingsAPI) PreviewPrompt(ctx context.Context, request *dieterv1.PreviewPromptRequest) (*dieterv1.PromptPreview, error) {
	var detail model.CardDetail
	var err error
	if request.GetCardId() != "" {
		detail, err = api.server.store.CardDetail(request.GetCardId())
	} else {
		detail.Project, err = api.server.store.ResolveProject(request.GetProjectId())
		if err == nil && request.GetBoardId() != "" {
			detail.Board, err = api.server.store.ResolveBoard(detail.Project.ID, request.GetBoardId())
		}
		detail.Card = model.Card{ID: "preview", Scope: request.GetScope(), ProjectID: detail.Project.ID, BoardID: detail.Board.ID, Lane: model.LaneTodo, Title: "Prompt preview", LabelIDs: request.GetLabelIds()}
		if detail.Card.Scope == "" {
			if detail.Board.ID != "" {
				detail.Card.Scope = model.ConversationScopeBoard
			} else {
				detail.Card.Scope = model.ConversationScopeChat
			}
		}
	}
	if err != nil {
		return nil, err
	}
	labelIDs := request.GetLabelIds()
	if request.GetCardId() != "" && len(labelIDs) == 0 {
		labelIDs = detail.Card.LabelIDs
	}
	settings, err := api.server.store.Settings()
	if err != nil {
		return nil, err
	}
	workspaceValue := model.Workspace{
		Mode: model.WorkspaceModeProject, Path: detail.Project.Path, Branch: detail.Project.BaseBranch,
		BaseBranch: detail.Project.BaseBranch,
	}
	if detail.Card.WorkspaceMode != "" {
		workspaceValue.Mode = detail.Card.WorkspaceMode
	}
	if detail.Card.WorkspaceBranch != "" {
		workspaceValue.Branch = detail.Card.WorkspaceBranch
	}
	if detail.Card.WorkspaceBaseBranch != "" {
		workspaceValue.BaseBranch = detail.Card.WorkspaceBaseBranch
	}
	if workspaceValue.Mode == model.WorkspaceModeProject {
		if result, gitErr := api.server.workspaces.Git.Run(ctx, detail.Project.Path, "symbolic-ref", "--quiet", "--short", "HEAD"); gitErr == nil {
			workspaceValue.Branch = strings.TrimSpace(string(result.Output))
		}
	}
	if workspaceValue.Mode == model.WorkspaceModeWorktree && detail.Card.ID != "" && detail.Card.ID != "preview" {
		workspaceValue.Path = filepath.Join(api.server.store.WorktreeRoot(), detail.Project.ID, detail.Card.ID)
	}
	if request.GetCardId() != "" {
		storedWorkspace, workspaceErr := api.server.store.WorkspaceByCardID(detail.Card.ID)
		if workspaceErr == nil {
			workspaceValue = storedWorkspace
		} else if !errors.Is(workspaceErr, store.ErrNotFound) {
			return nil, workspaceErr
		}
	}
	resolved, err := dieterprompt.ResolveForWorkspace(settings, detail, labelIDs, workspaceValue)
	if err != nil {
		return nil, err
	}
	result := &dieterv1.PromptPreview{
		Source: resolved.Source, PromptTemplate: resolved.Template, Context: resolved.Context,
		Skill: resolved.Skill, Instructions: resolved.Instructions,
		Characters: int32(len(resolved.Instructions)), EstimatedTokens: int32((len(resolved.Instructions) + 3) / 4),
	}
	for _, label := range resolved.AppliedLabels {
		result.AppliedLabels = append(result.AppliedLabels, &dieterv1.Label{Id: label.ID, Name: label.Name, Color: label.Color, Instructions: label.Instructions})
	}
	return result, nil
}
