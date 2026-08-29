package store

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

type ScheduleInput struct {
	Project, Board, Name, Description, Cron, Timezone, Action string
	TitleTemplate, PromptTemplate, Provider, Model, Effort    string
	OpenCardPolicy, MisfirePolicy, BusyPolicy, NextRunAt      string
	WorkspaceMode                                             string
	LabelIDs                                                  []string
	ProviderOptions                                           map[string]string
	Enabled                                                   bool
}

func normalizeScheduleInput(input ScheduleInput) (ScheduleInput, error) {
	input.Name = strings.TrimSpace(input.Name)
	input.Cron = strings.TrimSpace(input.Cron)
	input.Timezone = strings.TrimSpace(input.Timezone)
	input.Action = strings.TrimSpace(input.Action)
	input.TitleTemplate = strings.TrimSpace(input.TitleTemplate)
	input.PromptTemplate = strings.TrimSpace(input.PromptTemplate)
	input.Provider = strings.TrimSpace(input.Provider)
	input.Model = strings.TrimSpace(input.Model)
	var err error
	input.WorkspaceMode, err = normalizeWorkspaceMode(input.WorkspaceMode)
	if err != nil {
		return input, err
	}
	if input.Name == "" || input.Cron == "" || input.Timezone == "" {
		return input, errors.New("schedule name, cron expression, and timezone are required")
	}
	if input.TitleTemplate == "" || input.PromptTemplate == "" {
		return input, errors.New("card title and prompt templates are required")
	}
	if input.Action == "" {
		input.Action = model.ScheduleActionDraft
	}
	if input.Action != model.ScheduleActionDraft && input.Action != model.ScheduleActionRun {
		return input, errors.New("schedule action must be draft or run")
	}
	if input.OpenCardPolicy == "" {
		input.OpenCardPolicy = "skip_if_open"
	}
	if input.OpenCardPolicy != "skip_if_open" && input.OpenCardPolicy != "always" {
		return input, errors.New("open card policy must be skip_if_open or always")
	}
	if input.MisfirePolicy == "" {
		input.MisfirePolicy = "latest"
	}
	if input.MisfirePolicy != "latest" {
		return input, errors.New("only the latest misfire policy is supported")
	}
	if input.BusyPolicy == "" {
		input.BusyPolicy = "queue"
	}
	if input.BusyPolicy != "queue" && input.BusyPolicy != "skip" {
		return input, errors.New("busy policy must be queue or skip")
	}
	return input, nil
}

func (s *Store) CreateSchedule(input ScheduleInput) (model.Schedule, error) {
	input, err := normalizeScheduleInput(input)
	if err != nil {
		return model.Schedule{}, err
	}
	project, err := s.ResolveProject(input.Project)
	if err != nil {
		return model.Schedule{}, err
	}
	board, err := s.ResolveBoard(project.ID, input.Board)
	if err != nil {
		return model.Schedule{}, err
	}
	labels, err := validateCardLabels(board, input.LabelIDs)
	if err != nil {
		return model.Schedule{}, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Schedule{}, err
	}
	defer release()
	now := timestamp()
	item := model.Schedule{
		ID: newID("sch_"), ProjectID: project.ID, BoardID: board.ID, Name: input.Name, Description: strings.TrimSpace(input.Description),
		Cron: input.Cron, Timezone: input.Timezone, Enabled: input.Enabled, Action: input.Action,
		TitleTemplate: input.TitleTemplate, PromptTemplate: input.PromptTemplate, Provider: input.Provider, Model: input.Model, Effort: strings.TrimSpace(input.Effort), ProviderOptions: cloneStringMap(input.ProviderOptions), LabelIDs: labels,
		WorkspaceMode:  input.WorkspaceMode,
		OpenCardPolicy: input.OpenCardPolicy, MisfirePolicy: input.MisfirePolicy, BusyPolicy: input.BusyPolicy, NextRunAt: input.NextRunAt,
		CreatedAt: now, UpdatedAt: now,
	}
	return item, writeMarkdown(filepath.Join(s.scheduleDir(), item.ID+".md"), item, item.PromptTemplate)
}

func (s *Store) readSchedule(path string) (model.Schedule, error) {
	var item model.Schedule
	body, err := readMarkdown(path, &item)
	if err != nil {
		return model.Schedule{}, err
	}
	item.PromptTemplate = body
	item.WorkspaceMode, err = normalizeWorkspaceMode(item.WorkspaceMode)
	if err != nil {
		return model.Schedule{}, err
	}
	return item, nil
}

func (s *Store) listSchedules() ([]model.Schedule, error) {
	paths, err := listMarkdown(s.scheduleDir())
	if err != nil {
		return nil, err
	}
	result := make([]model.Schedule, 0, len(paths))
	for _, path := range paths {
		item, readErr := s.readSchedule(path)
		if readErr != nil {
			return nil, readErr
		}
		result = append(result, item)
	}
	sort.Slice(result, func(i, j int) bool { return strings.ToLower(result[i].Name) < strings.ToLower(result[j].Name) })
	return result, nil
}

func (s *Store) ListSchedules(projectRef string) ([]model.Schedule, error) {
	projectID := ""
	activeProjects := map[string]bool{}
	if strings.TrimSpace(projectRef) != "" {
		project, err := s.ResolveProject(projectRef)
		if err != nil {
			return nil, err
		}
		projectID = project.ID
	} else {
		projects, err := s.listProjects()
		if err != nil {
			return nil, err
		}
		for _, project := range projects {
			if !project.Archived {
				activeProjects[project.ID] = true
			}
		}
	}
	items, err := s.listSchedules()
	if err != nil {
		return nil, err
	}
	result := make([]model.Schedule, 0, len(items))
	for _, item := range items {
		if projectID != "" && item.ProjectID != projectID {
			continue
		}
		if projectID == "" && !activeProjects[item.ProjectID] {
			continue
		}
		result = append(result, item)
	}
	return result, nil
}

func resolveSchedule(items []model.Schedule, ref string) (model.Schedule, error) {
	for _, item := range items {
		if matchRef(strings.TrimSpace(ref), item.ID, item.Name) {
			return item, nil
		}
	}
	return model.Schedule{}, fmt.Errorf("schedule %q: %w", ref, ErrNotFound)
}

func (s *Store) ResolveSchedule(ref string) (model.Schedule, error) {
	items, err := s.ListSchedules("")
	if err != nil {
		return model.Schedule{}, err
	}
	return resolveSchedule(items, ref)
}

func (s *Store) ResolveScheduleIncludingArchived(ref string) (model.Schedule, error) {
	items, err := s.listSchedules()
	if err != nil {
		return model.Schedule{}, err
	}
	return resolveSchedule(items, ref)
}

func (s *Store) UpdateSchedule(ref string, input ScheduleInput) (model.Schedule, error) {
	input, err := normalizeScheduleInput(input)
	if err != nil {
		return model.Schedule{}, err
	}
	current, err := s.ResolveSchedule(ref)
	if err != nil {
		return model.Schedule{}, err
	}
	project, err := s.ResolveProject(input.Project)
	if err != nil {
		return model.Schedule{}, err
	}
	if project.ID != current.ProjectID {
		return model.Schedule{}, errors.New("a schedule cannot be moved to another project")
	}
	board, err := s.ResolveBoard(project.ID, input.Board)
	if err != nil {
		return model.Schedule{}, err
	}
	labels, err := validateCardLabels(board, input.LabelIDs)
	if err != nil {
		return model.Schedule{}, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Schedule{}, err
	}
	defer release()
	current.BoardID, current.Name, current.Description = board.ID, input.Name, strings.TrimSpace(input.Description)
	current.Cron, current.Timezone, current.Enabled, current.Action = input.Cron, input.Timezone, input.Enabled, input.Action
	current.TitleTemplate, current.PromptTemplate = input.TitleTemplate, input.PromptTemplate
	current.Provider, current.Model, current.Effort, current.LabelIDs = input.Provider, input.Model, strings.TrimSpace(input.Effort), labels
	current.ProviderOptions = cloneStringMap(input.ProviderOptions)
	current.OpenCardPolicy, current.MisfirePolicy, current.BusyPolicy, current.NextRunAt = input.OpenCardPolicy, input.MisfirePolicy, input.BusyPolicy, input.NextRunAt
	current.UpdatedAt = timestamp()
	return current, writeMarkdown(filepath.Join(s.scheduleDir(), current.ID+".md"), current, current.PromptTemplate)
}

func (s *Store) SetScheduleEnabled(ref string, enabled bool, nextRunAt string) (model.Schedule, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Schedule{}, err
	}
	defer release()
	item, err := s.ResolveSchedule(ref)
	if err != nil {
		return model.Schedule{}, err
	}
	item.Enabled, item.NextRunAt, item.UpdatedAt = enabled, nextRunAt, timestamp()
	return item, writeMarkdown(filepath.Join(s.scheduleDir(), item.ID+".md"), item, item.PromptTemplate)
}

func (s *Store) DeleteSchedule(ref string) error {
	release, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer release()
	item, err := s.ResolveSchedule(ref)
	if err != nil {
		return err
	}
	return os.Remove(filepath.Join(s.scheduleDir(), item.ID+".md"))
}

func occurrenceIDs(scheduleID, scheduledFor string) (string, string) {
	digest := sha256.Sum256([]byte(scheduleID + "\x00" + scheduledFor))
	suffix := fmt.Sprintf("%x", digest[:12])
	return "sr_" + suffix, "c_sched_" + suffix
}

// ClaimScheduleRun atomically establishes the durable occurrence identity.
// For clock-driven runs it also advances the schedule cursor. If a crash
// occurs between the run and schedule writes, a repeat claim repairs the
// cursor and returns the original run instead of creating another card.
func (s *Store) ClaimScheduleRun(scheduleID, scheduledFor, nextRunAt string, manual bool) (model.ScheduleRun, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	defer release()
	schedule, err := s.ResolveSchedule(scheduleID)
	if err != nil {
		return model.ScheduleRun{}, err
	}
	if !manual {
		cursor, cursorErr := time.Parse(time.RFC3339Nano, schedule.NextRunAt)
		occurrence, occurrenceErr := time.Parse(time.RFC3339Nano, scheduledFor)
		if !schedule.Enabled || cursorErr != nil || occurrenceErr != nil || cursor.After(occurrence) {
			return model.ScheduleRun{}, errors.New("schedule occurrence is no longer due")
		}
	}
	runID, cardID := occurrenceIDs(schedule.ID, scheduledFor)
	path := filepath.Join(s.scheduleRunDir(), runID+".md")
	if existing, readErr := s.readScheduleRun(path); readErr == nil {
		if !manual {
			schedule.NextRunAt, schedule.LastRunAt, schedule.UpdatedAt = nextRunAt, scheduledFor, timestamp()
			if writeErr := writeMarkdown(filepath.Join(s.scheduleDir(), schedule.ID+".md"), schedule, schedule.PromptTemplate); writeErr != nil {
				return model.ScheduleRun{}, writeErr
			}
		}
		return existing, nil
	} else if !errors.Is(readErr, ErrNotFound) {
		return model.ScheduleRun{}, readErr
	}
	now := timestamp()
	run := model.ScheduleRun{ID: runID, ScheduleID: schedule.ID, ProjectID: schedule.ProjectID, BoardID: schedule.BoardID, CardID: cardID, ScheduledFor: scheduledFor, Manual: manual, Action: schedule.Action, Status: model.ScheduleRunPending, CreatedAt: now, UpdatedAt: now}
	if err := writeMarkdown(path, run, run.Message); err != nil {
		return model.ScheduleRun{}, err
	}
	if !manual {
		schedule.NextRunAt = nextRunAt
	}
	schedule.LastRunAt, schedule.UpdatedAt = scheduledFor, now
	if err := writeMarkdown(filepath.Join(s.scheduleDir(), schedule.ID+".md"), schedule, schedule.PromptTemplate); err != nil {
		return model.ScheduleRun{}, err
	}
	return run, nil
}

func (s *Store) readScheduleRun(path string) (model.ScheduleRun, error) {
	var item model.ScheduleRun
	body, err := readMarkdown(path, &item)
	if err != nil {
		return model.ScheduleRun{}, err
	}
	item.Message = body
	return item, nil
}

func (s *Store) ResolveScheduleRun(ref string) (model.ScheduleRun, error) {
	paths, err := listMarkdown(s.scheduleRunDir())
	if err != nil {
		return model.ScheduleRun{}, err
	}
	for _, path := range paths {
		item, readErr := s.readScheduleRun(path)
		if readErr != nil {
			return model.ScheduleRun{}, readErr
		}
		if item.ID == ref {
			return item, nil
		}
	}
	return model.ScheduleRun{}, fmt.Errorf("schedule run %q: %w", ref, ErrNotFound)
}

func (s *Store) ListScheduleRuns(scheduleRef string, limit int) ([]model.ScheduleRun, error) {
	scheduleID := ""
	if scheduleRef != "" {
		schedule, err := s.ResolveSchedule(scheduleRef)
		if err != nil {
			return nil, err
		}
		scheduleID = schedule.ID
	}
	paths, err := listMarkdown(s.scheduleRunDir())
	if err != nil {
		return nil, err
	}
	items := make([]model.ScheduleRun, 0, len(paths))
	for _, path := range paths {
		item, readErr := s.readScheduleRun(path)
		if readErr != nil {
			return nil, readErr
		}
		if scheduleID == "" || item.ScheduleID == scheduleID {
			items = append(items, item)
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].ScheduledFor > items[j].ScheduledFor })
	if limit > 0 && len(items) > limit {
		items = items[:limit]
	}
	return items, nil
}

func (s *Store) UpdateScheduleRun(ref, status, message string) (model.ScheduleRun, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	defer release()
	item, err := s.ResolveScheduleRun(ref)
	if err != nil {
		return model.ScheduleRun{}, err
	}
	now := timestamp()
	item.Status, item.Message, item.UpdatedAt = status, strings.TrimSpace(message), now
	if status == model.ScheduleRunStarting {
		item.Attempt++
	}
	if status == model.ScheduleRunRunning && item.StartedAt == "" {
		item.StartedAt = now
	}
	if status == model.ScheduleRunCompleted || status == model.ScheduleRunInterrupted || status == model.ScheduleRunFailed || status == model.ScheduleRunSkipped || status == model.ScheduleRunCancelled {
		item.FinishedAt = now
	}
	return item, writeMarkdown(filepath.Join(s.scheduleRunDir(), item.ID+".md"), item, item.Message)
}

func (s *Store) SetScheduleRunCard(ref, cardID string) (model.ScheduleRun, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	defer release()
	item, err := s.ResolveScheduleRun(ref)
	if err != nil {
		return model.ScheduleRun{}, err
	}
	item.CardID, item.UpdatedAt = cardID, timestamp()
	return item, writeMarkdown(filepath.Join(s.scheduleRunDir(), item.ID+".md"), item, item.Message)
}

func (s *Store) RecoverScheduleRuns() error {
	runs, err := s.ListScheduleRuns("", 0)
	if err != nil {
		return err
	}
	for _, run := range runs {
		if run.Status == model.ScheduleRunStarting || run.Status == model.ScheduleRunRunning {
			_, _ = s.UpdateScheduleRun(run.ID, model.ScheduleRunFailed, "Dieter stopped after this agent turn was dispatched; it was not replayed automatically")
		}
	}
	return nil
}
