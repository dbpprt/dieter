package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Public mutations retain the central Store write lock and journal transaction.
// Unexported projection helpers run within their caller's existing lock boundary.

type CreateProjectInput struct {
	OperationID, InitialBoardName, InitialWorkflow          string
	ID, Name, Path, Summary, Prompt, BaseRemote, BaseBranch string
	ValidationCommands                                      []model.ValidationCommand
}

func validFileID(id string) bool {
	id = strings.TrimSpace(id)
	return id != "" && id != "." && id != ".." && !strings.ContainsAny(id, `/\\`)
}

func (s *Store) CreateProject(input CreateProjectInput) (model.Project, error) {
	if strings.TrimSpace(input.ID) == "" {
		input.ID = newID("p_")
	}
	if !validFileID(input.ID) {
		return model.Project{}, errors.New("project ID is invalid")
	}
	path, err := normalizePath(input.Path)
	if err != nil {
		return model.Project{}, err
	}
	name := strings.TrimSpace(input.Name)
	if name == "" {
		name = filepath.Base(path)
	}
	if err := s.Ensure(); err != nil {
		return model.Project{}, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	identity, err := s.sharedIdentity()
	if err != nil {
		return model.Project{}, err
	}
	request := input
	request.ID, request.Path = "", path
	fingerprint := peerstore.Revision(request)
	receiptPath := ""
	if input.OperationID != "" {
		if !peerstore.ValidID(input.OperationID) {
			return model.Project{}, errors.New("invalid operation ID")
		}
		receiptPath = "receipts/project-" + peerstore.Revision([]string{identity.Account, input.OperationID}) + ".json"
		var receipt projectReceipt
		if err := readJSON(filepath.Join(s.Root, receiptPath), &receipt); err == nil {
			if receipt.Fingerprint != fingerprint {
				return model.Project{}, errors.New("operation ID reused with a different project request")
			}
			return s.ResolveProjectIncludingArchived(receipt.ProjectID)
		} else if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, ErrNotFound) {
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
				return model.Project{}, fmt.Errorf("path is already attached to project %s", candidate.ID)
			}
		}
		if candidate.ID == input.ID {
			return model.Project{}, fmt.Errorf("project already registered as %s", candidate.ID)
		}
	}
	now := timestamp()
	validation, err := normalizeValidationCommands(input.ValidationCommands)
	if err != nil {
		return model.Project{}, err
	}
	project := model.Project{
		ID: input.ID, Name: name, Path: path, Summary: strings.TrimSpace(input.Summary), Prompt: strings.TrimSpace(input.Prompt),
		BaseRemote: strings.TrimSpace(input.BaseRemote), BaseBranch: strings.TrimSpace(input.BaseBranch),
		ValidationCommands: validation, CreatedAt: now, UpdatedAt: now,
	}
	checkout := model.Checkout{ID: newID("co_"), ProjectID: project.ID, DaemonID: identity.DaemonID, Name: filepath.Base(path), Path: path, ValidationCommands: validation}
	data, err := s.openPeerView(identity.Account)
	if err != nil {
		return model.Project{}, err
	}
	data.State = clonePeerState(data.State)
	fields := pickFields(project, "project")
	fields["identity"] = rawValue(map[string]string{"id": project.ID, "createdAt": now})
	if err = applyFields(&data, identity, "project", project.ID, nil, fields); err != nil {
		return model.Project{}, err
	}
	if err = applyFields(&data, identity, "checkout", checkout.ID, nil, checkoutFields(checkout)); err != nil {
		return model.Project{}, err
	}
	if input.InitialBoardName != "" {
		workflow, err := normalizeWorkflow(input.InitialWorkflow)
		if err != nil {
			return model.Project{}, err
		}
		board := model.Board{ID: initialBoardID(project.ID), ProjectID: project.ID, Name: input.InitialBoardName, Workflow: workflow, DoneArchivePolicy: model.DoneArchiveNever, BaseRemote: project.BaseRemote, RemotePublishMode: model.RemotePublishManual, CreatedAt: now, UpdatedAt: now}
		fields := pickFields(board, "board")
		fields["identity"] = rawValue(map[string]string{"id": board.ID, "projectId": project.ID, "createdAt": now})
		if err = applyFields(&data, identity, "board", board.ID, nil, fields); err != nil {
			return model.Project{}, err
		}
	}
	effects := []localEffect{{Path: "checkouts/" + checkout.ID + ".json", Value: rawValue(checkout)}}
	if receiptPath != "" {
		effects = append(effects, localEffect{Path: receiptPath, Value: rawValue(projectReceipt{project.ID, fingerprint})})
	}
	if err = s.writePeerState(identity.Account, data, effects...); err != nil {
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
		now := timestamp()
		initialBoard = &model.Board{
			ID: initialBoardID(project.ID), ProjectID: project.ID,
			Name: strings.TrimSpace(input.InitialBoardName), Workflow: workflow,
			DoneArchivePolicy: model.DoneArchiveNever, BaseRemote: project.BaseRemote,
			RemotePublishMode: model.RemotePublishManual, CreatedAt: now, UpdatedAt: now,
		}
	}

	identity, err := s.sharedIdentity()
	if err != nil {
		return model.Project{}, err
	}
	data, err := s.openPeerView(identity.Account)
	if err != nil {
		return model.Project{}, err
	}
	data.State = clonePeerState(data.State)
	project.Archived = false
	project.UpdatedAt = timestamp()
	if err = applyFields(&data, identity, "project", project.ID, project.SharedBase, map[string]json.RawMessage{
		"archived":  rawValue(false),
		"updatedAt": rawValue(project.UpdatedAt),
	}); err != nil {
		return model.Project{}, err
	}
	if initialBoard != nil {
		fields := pickFields(*initialBoard, "board")
		fields["identity"] = rawValue(map[string]string{
			"id": initialBoard.ID, "projectId": project.ID, "createdAt": initialBoard.CreatedAt,
		})
		if err = applyFields(&data, identity, "board", initialBoard.ID, nil, fields); err != nil {
			return model.Project{}, err
		}
	}
	effects := []localEffect{}
	if receiptPath != "" {
		effects = append(effects, localEffect{
			Path: receiptPath, Value: rawValue(projectReceipt{project.ID, fingerprint}),
		})
	}
	if err = s.writePeerState(identity.Account, data, effects...); err != nil {
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
	cards, cardErr := s.listCards(false)
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
	return resolveProject(filterProjectsByArchived(projects, false), s.canonicalProjectRef(ref))
}

func (s *Store) ResolveProjectIncludingArchived(ref string) (model.Project, error) {
	projects, err := s.listProjects()
	if err != nil {
		return model.Project{}, err
	}
	return resolveProject(projects, s.canonicalProjectRef(ref))
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
		return model.Project{}, errors.New("project is required; pass --project or run inside a registered project")
	}
	for _, project := range projects {
		if matchRef(ref, project.ID, project.Name) || project.Path == ref {
			return project, nil
		}
	}
	return model.Project{}, fmt.Errorf("project %q: %w", ref, ErrNotFound)
}

func (s *Store) ArchiveProject(ref string, archived bool) (model.Project, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	project, err := s.ResolveProjectIncludingArchived(ref)
	if err != nil {
		return model.Project{}, err
	}
	if archived {
		leases, leaseErr := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
		if leaseErr != nil {
			return model.Project{}, leaseErr
		}
		for _, lease := range leases {
			if lease.ProjectID == project.ID {
				return model.Project{}, fmt.Errorf("%w on card %s", ErrCardActive, lease.CardID)
			}
		}
	}
	project.Archived = archived
	project.UpdatedAt = timestamp()
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
	release, err := s.beginWrite()
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
				return model.Project{}, fmt.Errorf("project path is already registered as %s", candidate.ID)
			}
		}
		checkout, err := s.localCheckout(project.ID, "")
		if err != nil {
			return model.Project{}, err
		}
		checkout.Path = path
		if err = writeJSON(filepath.Join(s.Root, "checkouts", checkout.ID+".json"), checkout); err != nil {
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
	project.UpdatedAt = timestamp()
	return s.saveProject(project)
}

func (s *Store) UpdateProjectPromptTemplate(ref, template string) (model.Project, error) {
	template = strings.TrimSpace(template)
	if template != "" {
		if err := dieterprompt.ValidateContextTemplate(template); err != nil {
			return model.Project{}, err
		}
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	project, err := s.ResolveProject(ref)
	if err != nil {
		return model.Project{}, err
	}
	project.PromptTemplate, project.UpdatedAt = template, timestamp()
	return s.saveProject(project)
}

func (s *Store) UpdateProjectWorkspaceSettings(ref, baseRemote, baseBranch string, validation []model.ValidationCommand, checkoutIDs ...string) (model.Project, error) {
	updateValidation := validation != nil
	validation, err := normalizeValidationCommands(validation)
	if err != nil {
		return model.Project{}, err
	}
	release, err := s.beginWrite()
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
	var effects []localEffect
	if updateValidation {
		selected := ""
		if len(checkoutIDs) > 0 {
			selected = checkoutIDs[0]
		}
		checkout, err := s.localCheckout(project.ID, selected)
		if err != nil {
			return model.Project{}, err
		}
		checkout.ValidationCommands = validation
		effects = append(effects, localEffect{Path: "checkouts/" + checkout.ID + ".json", Value: rawValue(checkout)})
		project.ValidationCommands = append([]model.ValidationCommand(nil), validation...)
	}
	project.UpdatedAt = timestamp()
	return s.saveProject(project, effects...)
}

func normalizeValidationCommands(values []model.ValidationCommand) ([]model.ValidationCommand, error) {
	result := make([]model.ValidationCommand, 0, len(values))
	for index, value := range values {
		value.Name = strings.TrimSpace(value.Name)
		value.Executable = strings.TrimSpace(value.Executable)
		value.WorkingDirectory = strings.TrimSpace(value.WorkingDirectory)
		if value.Executable == "" || strings.ContainsRune(value.Executable, '\x00') {
			return nil, fmt.Errorf("validation command %d requires a valid executable", index+1)
		}
		if value.TimeoutSeconds < 0 || value.TimeoutSeconds > 3600 {
			return nil, fmt.Errorf("validation command %d timeout must be between 0 and 3600 seconds", index+1)
		}
		if value.WorkingDirectory != "" {
			clean := filepath.Clean(value.WorkingDirectory)
			if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
				return nil, fmt.Errorf("validation command %d working directory must stay inside the workspace", index+1)
			}
			value.WorkingDirectory = clean
		}
		value.Arguments = append([]string(nil), value.Arguments...)
		for _, argument := range value.Arguments {
			if strings.ContainsRune(argument, '\x00') {
				return nil, fmt.Errorf("validation command %d has an invalid argument", index+1)
			}
		}
		environment := make(map[string]string, len(value.Environment))
		for key, item := range value.Environment {
			if key == "" || strings.ContainsAny(key, "=\x00") || strings.ContainsRune(item, '\x00') {
				return nil, fmt.Errorf("validation command %d has an invalid environment entry", index+1)
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
