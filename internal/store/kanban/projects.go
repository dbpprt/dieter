package kanban

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/leases"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// Public mutations retain the central Store write lock and journal transaction.
// Unexported projection helpers run within their caller's existing lock boundary.

type CreateProjectInput struct {
	OperationID, InitialBoardName, InitialWorkflow          string
	ID, Name, Path, Summary, Prompt, BaseRemote, BaseBranch string
	ValidationCommands                                      []model.ValidationCommand
}

func (s *Store) CreateProject(input CreateProjectInput) (model.Project, error) {
	if strings.TrimSpace(input.ID) == "" {
		input.ID = home.NewID("p_")
	}
	if !home.ValidFileID(input.ID) {
		return model.Project{}, fault.New(fault.Invalid, "project ID is invalid")
	}
	path, err := normalizePath(input.Path)
	if err != nil {
		return model.Project{}, err
	}
	name := strings.TrimSpace(input.Name)
	if name == "" {
		name = filepath.Base(path)
	}
	if ensure := s.hooks.Ensure; ensure != nil {
		if err := ensure(); err != nil {
			return model.Project{}, err
		}
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	identity, err := s.replica.WriterIdentity()
	if err != nil {
		return model.Project{}, err
	}
	request := input
	request.ID, request.Path = "", path
	fingerprint := crdt.Revision(request)
	receiptPath := ""
	if input.OperationID != "" {
		if !crdt.ValidID(input.OperationID) {
			return model.Project{}, fault.New(fault.Invalid, "invalid operation ID")
		}
		receiptPath = "receipts/project-" + crdt.Revision([]string{identity.Account, input.OperationID}) + ".json"
		var receipt projectReceipt
		if err := home.ReadJSON(filepath.Join(s.home.Root, receiptPath), &receipt); err == nil {
			if receipt.Fingerprint != fingerprint {
				return model.Project{}, fault.New(fault.Invalid, "operation ID reused with a different project request")
			}
			return s.ResolveProjectIncludingArchived(receipt.ProjectID)
		} else if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, home.ErrNotFound) {
			return model.Project{}, err
		}
	}
	projects, err := s.listProjects()
	if err != nil {
		return model.Project{}, err
	}
	for _, candidate := range projects {
		for _, checkout := range candidate.Checkouts {
			if checkout.Path == path && !checkout.Detached {
				if candidate.Archived {
					return s.restoreProjectForCreation(candidate, input, receiptPath, fingerprint)
				}
				return model.Project{}, fault.Invalidf("path is already attached to project %s", candidate.ID)
			}
		}
		if candidate.ID == input.ID {
			return model.Project{}, fault.Invalidf("project already registered as %s", candidate.ID)
		}
	}
	now := home.Timestamp()
	validation, err := normalizeValidationCommands(input.ValidationCommands)
	if err != nil {
		return model.Project{}, err
	}
	project := model.Project{
		ID: input.ID, Name: name, Path: path, Summary: strings.TrimSpace(input.Summary), Prompt: strings.TrimSpace(input.Prompt),
		BaseRemote: strings.TrimSpace(input.BaseRemote), BaseBranch: strings.TrimSpace(input.BaseBranch),
		ValidationCommands: validation, CreatedAt: now, UpdatedAt: now,
	}
	checkout := model.Checkout{ID: home.NewID("co_"), ProjectID: project.ID, DaemonID: identity.DaemonID, Name: filepath.Base(path), Path: path, ValidationCommands: validation}
	data, err := s.replica.OpenPeerView(identity.Account)
	if err != nil {
		return model.Project{}, err
	}
	data.State = replica.ClonePeerState(data.State)
	fields := replica.PickFields(project, "project")
	fields["identity"] = replica.RawValue(map[string]string{"id": project.ID, "createdAt": now})
	if err = replica.ApplyFields(&data, identity, "project", project.ID, nil, fields); err != nil {
		return model.Project{}, err
	}
	if err = replica.ApplyFields(&data, identity, "checkout", checkout.ID, nil, checkoutFields(checkout)); err != nil {
		return model.Project{}, err
	}
	if input.InitialBoardName != "" {
		workflow, err := normalizeWorkflow(input.InitialWorkflow)
		if err != nil {
			return model.Project{}, err
		}
		board := model.Board{ID: initialBoardID(project.ID), ProjectID: project.ID, Name: input.InitialBoardName, Workflow: workflow, DoneArchivePolicy: model.DoneArchiveNever, BaseRemote: project.BaseRemote, RemotePublishMode: model.RemotePublishManual, CreatedAt: now, UpdatedAt: now}
		fields := replica.PickFields(board, "board")
		fields["identity"] = replica.RawValue(map[string]string{"id": board.ID, "projectId": project.ID, "createdAt": now})
		if err = replica.ApplyFields(&data, identity, "board", board.ID, nil, fields); err != nil {
			return model.Project{}, err
		}
	}
	effects := []replica.Effect{{Path: "checkouts/" + checkout.ID + ".json", Value: replica.RawValue(checkout)}}
	if receiptPath != "" {
		effects = append(effects, replica.Effect{Path: receiptPath, Value: replica.RawValue(projectReceipt{project.ID, fingerprint})})
	}
	if err = s.replica.WritePeerState(identity.Account, data, effects...); err != nil {
		return model.Project{}, err
	}
	return s.ResolveProject(project.ID)
}

// restoreProjectForCreation makes reopening a previously removed path behave
// like project creation from the clients' point of view. Archived projects are
// intentionally absent from the normal project directory, so returning an
// opaque duplicate-path error would otherwise leave users with no visible
// project to recover. Preserve the durable project identity and history, and
// only synthesize the requested initial board when the project is boardless.
// The caller holds the central write lock.
func (s *Store) restoreProjectForCreation(
	project model.Project,
	input CreateProjectInput,
	receiptPath, fingerprint string,
) (model.Project, error) {
	boards, err := s.listBoards()
	if err != nil {
		return model.Project{}, err
	}
	hasBoard := false
	for _, board := range boards {
		if board.ProjectID == project.ID {
			hasBoard = true
			break
		}
	}

	var initialBoard *model.Board
	if !hasBoard && strings.TrimSpace(input.InitialBoardName) != "" {
		workflow, normalizeErr := normalizeWorkflow(input.InitialWorkflow)
		if normalizeErr != nil {
			return model.Project{}, normalizeErr
		}
		now := home.Timestamp()
		initialBoard = &model.Board{
			ID: initialBoardID(project.ID), ProjectID: project.ID,
			Name: strings.TrimSpace(input.InitialBoardName), Workflow: workflow,
			DoneArchivePolicy: model.DoneArchiveNever, BaseRemote: project.BaseRemote,
			RemotePublishMode: model.RemotePublishManual, CreatedAt: now, UpdatedAt: now,
		}
	}

	identity, err := s.replica.WriterIdentity()
	if err != nil {
		return model.Project{}, err
	}
	data, err := s.replica.OpenPeerView(identity.Account)
	if err != nil {
		return model.Project{}, err
	}
	data.State = replica.ClonePeerState(data.State)
	project.Archived = false
	project.UpdatedAt = home.Timestamp()
	if err = replica.ApplyFields(&data, identity, "project", project.ID, project.SharedBase, map[string]json.RawMessage{
		"archived":  replica.RawValue(false),
		"updatedAt": replica.RawValue(project.UpdatedAt),
	}); err != nil {
		return model.Project{}, err
	}
	if initialBoard != nil {
		fields := replica.PickFields(*initialBoard, "board")
		fields["identity"] = replica.RawValue(map[string]string{
			"id": initialBoard.ID, "projectId": project.ID, "createdAt": initialBoard.CreatedAt,
		})
		if err = replica.ApplyFields(&data, identity, "board", initialBoard.ID, nil, fields); err != nil {
			return model.Project{}, err
		}
	}
	effects := []replica.Effect{}
	if receiptPath != "" {
		effects = append(effects, replica.Effect{
			Path: receiptPath, Value: replica.RawValue(projectReceipt{project.ID, fingerprint}),
		})
	}
	if err = s.replica.WritePeerState(identity.Account, data, effects...); err != nil {
		return model.Project{}, err
	}
	return s.ResolveProject(project.ID)
}

func (s *Store) listProjects() ([]model.Project, error) { return s.sharedProjects() }

func (s *Store) ListProjects() ([]model.Project, error) {
	projects, err := s.listProjects()
	if err != nil {
		return nil, err
	}
	projects = filterProjectsByArchived(projects, false)
	return s.enrichProjects(projects)
}

func (s *Store) ListArchivedProjects() ([]model.Project, error) {
	projects, err := s.listProjects()
	if err != nil {
		return nil, err
	}
	projects = filterProjectsByArchived(projects, true)
	return s.enrichProjects(projects)
}

func filterProjectsByArchived(projects []model.Project, archived bool) []model.Project {
	result := make([]model.Project, 0, len(projects))
	for _, project := range projects {
		if project.Archived == archived {
			result = append(result, project)
		}
	}
	return result
}

func (s *Store) enrichProjects(projects []model.Project) ([]model.Project, error) {
	boards, boardErr := s.listBoards()
	if boardErr != nil {
		return nil, boardErr
	}
	cards, cardErr := s.ListAllCards(false)
	if cardErr != nil {
		return nil, cardErr
	}
	for i := range projects {
		for _, board := range boards {
			if board.ProjectID == projects[i].ID {
				projects[i].BoardCount++
			}
		}
		for _, card := range cards {
			if card.ProjectID == projects[i].ID && !card.Archived {
				if card.Scope == model.ConversationScopeChat {
					projects[i].ChatCount++
				} else {
					projects[i].CardCount++
				}
			}
		}
	}
	return projects, nil
}

func (s *Store) ResolveProject(ref string) (model.Project, error) {
	projects, err := s.listProjects()
	if err != nil {
		return model.Project{}, err
	}
	return resolveProject(filterProjectsByArchived(projects, false), s.CanonicalProjectRef(ref))
}

func (s *Store) ResolveProjectIncludingArchived(ref string) (model.Project, error) {
	projects, err := s.listProjects()
	if err != nil {
		return model.Project{}, err
	}
	return resolveProject(projects, s.CanonicalProjectRef(ref))
}

func resolveProject(projects []model.Project, ref string) (model.Project, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		cwd, _ := os.Getwd()
		var matches []model.Project
		for _, project := range projects {
			if project.Path == "" {
				continue
			}
			rel, relErr := filepath.Rel(project.Path, cwd)
			if relErr == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				matches = append(matches, project)
			}
		}
		if len(matches) > 0 {
			sort.Slice(matches, func(i, j int) bool { return len(matches[i].Path) > len(matches[j].Path) })
			return matches[0], nil
		}
		if len(projects) == 1 {
			return projects[0], nil
		}
		return model.Project{}, fault.New(fault.Invalid, "project is required; pass --project or run inside a registered project")
	}
	for _, project := range projects {
		if home.MatchRef(ref, project.ID, project.Name) || project.Path == ref {
			return project, nil
		}
	}
	return model.Project{}, fmt.Errorf("project %q: %w", ref, home.ErrNotFound)
}

func (s *Store) ArchiveProject(ref string, archived bool) (model.Project, error) {
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	project, err := s.ResolveProjectIncludingArchived(ref)
	if err != nil {
		return model.Project{}, err
	}
	if archived {
		activeLeases, leaseErr := s.leases.Active()
		if leaseErr != nil {
			return model.Project{}, leaseErr
		}
		for _, lease := range activeLeases {
			if lease.ProjectID == project.ID {
				return model.Project{}, fmt.Errorf("%w on card %s", leases.ErrCardActive, lease.CardID)
			}
		}
	}
	project.Archived = archived
	project.UpdatedAt = home.Timestamp()
	return s.saveProject(project)
}

func (s *Store) UpdateProject(ref string, name, summary, prompt *string, paths ...*string) (model.Project, error) {
	var path *string
	if len(paths) > 0 {
		path = paths[0]
	}
	return s.UpdateProjectWithHostnames(ref, name, summary, prompt, path, nil)
}

func (s *Store) UpdateProjectWithHostnames(ref string, name, summary, prompt, path *string, hostnames *[]string) (model.Project, error) {
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	project, err := s.ResolveProject(ref)
	if err != nil {
		return model.Project{}, err
	}
	if name != nil && strings.TrimSpace(*name) != "" {
		project.Name = strings.TrimSpace(*name)
	}
	if summary != nil {
		project.Summary = strings.TrimSpace(*summary)
	}
	if prompt != nil {
		project.Prompt = strings.TrimSpace(*prompt)
	}
	if path != nil {
		path, normalizeErr := normalizePath(*path)
		if normalizeErr != nil {
			return model.Project{}, normalizeErr
		}
		projects, listErr := s.listProjects()
		if listErr != nil {
			return model.Project{}, listErr
		}
		for _, candidate := range projects {
			if candidate.ID != project.ID && candidate.Path == path {
				return model.Project{}, fault.Invalidf("project path is already registered as %s", candidate.ID)
			}
		}
		checkout, err := s.LocalCheckout(project.ID, "")
		if err != nil {
			return model.Project{}, err
		}
		checkout.Path = path
		if err = home.WriteJSON(filepath.Join(s.home.Root, "checkouts", checkout.ID+".json"), checkout); err != nil {
			return model.Project{}, err
		}
		project.Path = path
	}
	if hostnames != nil {
		normalized, err := normalizeProjectHostnames(*hostnames)
		if err != nil {
			return model.Project{}, err
		}
		project.Hostnames = normalized
	}
	project.UpdatedAt = home.Timestamp()
	return s.saveProject(project)
}

func (s *Store) UpdateProjectPromptTemplate(ref, template string) (model.Project, error) {
	template = strings.TrimSpace(template)
	if template != "" {
		if err := dieterprompt.ValidateContextTemplate(template); err != nil {
			return model.Project{}, err
		}
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	project, err := s.ResolveProject(ref)
	if err != nil {
		return model.Project{}, err
	}
	project.PromptTemplate, project.UpdatedAt = template, home.Timestamp()
	return s.saveProject(project)
}

func (s *Store) UpdateProjectWorkspaceSettings(ref, baseRemote, baseBranch string, validation []model.ValidationCommand, checkoutIDs ...string) (model.Project, error) {
	updateValidation := validation != nil
	validation, err := normalizeValidationCommands(validation)
	if err != nil {
		return model.Project{}, err
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	project, err := s.ResolveProject(ref)
	if err != nil {
		return model.Project{}, err
	}
	project.BaseRemote = strings.TrimSpace(baseRemote)
	project.BaseBranch = strings.TrimSpace(baseBranch)
	var effects []replica.Effect
	if updateValidation {
		selected := ""
		if len(checkoutIDs) > 0 {
			selected = checkoutIDs[0]
		}
		checkout, err := s.LocalCheckout(project.ID, selected)
		if err != nil {
			return model.Project{}, err
		}
		checkout.ValidationCommands = validation
		effects = append(effects, replica.Effect{Path: "checkouts/" + checkout.ID + ".json", Value: replica.RawValue(checkout)})
		project.ValidationCommands = append([]model.ValidationCommand(nil), validation...)
	}
	project.UpdatedAt = home.Timestamp()
	return s.saveProject(project, effects...)
}

func normalizeValidationCommands(values []model.ValidationCommand) ([]model.ValidationCommand, error) {
	result := make([]model.ValidationCommand, 0, len(values))
	for index, value := range values {
		value.Name = strings.TrimSpace(value.Name)
		value.Executable = strings.TrimSpace(value.Executable)
		value.WorkingDirectory = strings.TrimSpace(value.WorkingDirectory)
		if value.Executable == "" || strings.ContainsRune(value.Executable, '\x00') {
			return nil, fault.Invalidf("validation command %d requires a valid executable", index+1)
		}
		if value.TimeoutSeconds < 0 || value.TimeoutSeconds > 3600 {
			return nil, fault.Invalidf("validation command %d timeout must be between 0 and 3600 seconds", index+1)
		}
		if value.WorkingDirectory != "" {
			clean := filepath.Clean(value.WorkingDirectory)
			if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
				return nil, fault.Invalidf("validation command %d working directory must stay inside the workspace", index+1)
			}
			value.WorkingDirectory = clean
		}
		value.Arguments = append([]string(nil), value.Arguments...)
		for _, argument := range value.Arguments {
			if strings.ContainsRune(argument, '\x00') {
				return nil, fault.Invalidf("validation command %d has an invalid argument", index+1)
			}
		}
		environment := make(map[string]string, len(value.Environment))
		for key, item := range value.Environment {
			if key == "" || strings.ContainsAny(key, "=\x00") || strings.ContainsRune(item, '\x00') {
				return nil, fault.Invalidf("validation command %d has an invalid environment entry", index+1)
			}
			environment[key] = item
		}
		if len(environment) == 0 {
			environment = nil
		}
		value.Environment = environment
		result = append(result, value)
	}
	return result, nil
}

func hasGitDirectory(path string) bool {
	info, err := os.Stat(filepath.Join(path, ".git"))
	return err == nil && (info.IsDir() || info.Mode().IsRegular())
}

func normalizePath(path string) (string, error) {
	if path == "" {
		return "", fault.New(fault.Invalid, "project path is required")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err == nil {
		abs = resolved
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", fmt.Errorf("project path: %w", err)
	}
	if !info.IsDir() {
		return "", fault.New(fault.Invalid, "project path must be a directory")
	}
	if !hasGitDirectory(abs) {
		return "", fault.New(fault.Invalid, "project path must be a Git working tree (missing .git)")
	}
	return abs, nil
}
