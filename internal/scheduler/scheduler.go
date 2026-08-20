package scheduler

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/nauclio/internal/app"
	"github.com/dbpprt/nauclio/internal/harness"
	"github.com/dbpprt/nauclio/internal/model"
	"github.com/dbpprt/nauclio/internal/store"
	"github.com/robfig/cron/v3"
)

type Manager struct {
	store    *store.Store
	app      *app.Service
	parser   cron.Parser
	now      func() time.Time
	interval time.Duration

	mu         sync.Mutex
	processing map[string]bool
}

func New(data *store.Store, service *app.Service) *Manager {
	return &Manager{
		store: data, app: service,
		parser: cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow),
		now:    time.Now, interval: 2 * time.Second, processing: map[string]bool{},
	}
}

func (m *Manager) Start(ctx context.Context) {
	_ = m.store.RecoverScheduleRuns()
	m.Tick()
	go func() {
		ticker := time.NewTicker(m.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				m.Tick()
			}
		}
	}()
}

func (m *Manager) validate(input store.ScheduleInput) (store.ScheduleInput, error) {
	location, err := time.LoadLocation(strings.TrimSpace(input.Timezone))
	if err != nil {
		return input, fmt.Errorf("invalid timezone: %w", err)
	}
	parsed, err := m.parser.Parse(strings.TrimSpace(input.Cron))
	if err != nil {
		return input, fmt.Errorf("invalid cron expression: %w", err)
	}
	provider := strings.TrimSpace(input.Provider)
	if provider == "" {
		provider = "codex"
	}
	adapter, configuredModel, err := harness.ResolveSelection(provider, input.Model, os.Getenv("NAUCLIO_ENABLE_MOCK_HARNESS") == "1")
	if err != nil {
		return input, err
	}
	input.Provider, input.Model = adapter.ID, configuredModel.ID
	input.Effort, err = harness.ResolveEffort(adapter, configuredModel, input.Effort)
	if err != nil {
		return input, err
	}
	input.ProviderOptions, err = harness.ResolveOptions(adapter, input.ProviderOptions)
	if err != nil {
		return input, err
	}
	if input.Enabled {
		input.NextRunAt = parsed.Next(m.now().In(location)).UTC().Format(time.RFC3339Nano)
	} else {
		input.NextRunAt = ""
	}
	return input, nil
}

func (m *Manager) Create(input store.ScheduleInput) (model.Schedule, error) {
	validated, err := m.validate(input)
	if err != nil {
		return model.Schedule{}, err
	}
	return m.store.CreateSchedule(validated)
}

func (m *Manager) Update(ref string, input store.ScheduleInput) (model.Schedule, error) {
	validated, err := m.validate(input)
	if err != nil {
		return model.Schedule{}, err
	}
	return m.store.UpdateSchedule(ref, validated)
}

func (m *Manager) SetEnabled(ref string, enabled bool) (model.Schedule, error) {
	item, err := m.store.ResolveSchedule(ref)
	if err != nil {
		return model.Schedule{}, err
	}
	next := ""
	if enabled {
		times, previewErr := m.Preview(item.Cron, item.Timezone, 1)
		if previewErr != nil {
			return model.Schedule{}, previewErr
		}
		next = times[0]
	}
	return m.store.SetScheduleEnabled(item.ID, enabled, next)
}

func (m *Manager) List(projectRef string) ([]model.Schedule, error) {
	items, err := m.store.ListSchedules(projectRef)
	if err != nil {
		return nil, err
	}
	for index := range items {
		items[index].NextRuns, _ = m.Preview(items[index].Cron, items[index].Timezone, 5)
	}
	return items, nil
}

func (m *Manager) Preview(expression, timezone string, count int) ([]string, error) {
	location, err := time.LoadLocation(strings.TrimSpace(timezone))
	if err != nil {
		return nil, fmt.Errorf("invalid timezone: %w", err)
	}
	parsed, err := m.parser.Parse(strings.TrimSpace(expression))
	if err != nil {
		return nil, fmt.Errorf("invalid cron expression: %w", err)
	}
	if count < 1 || count > 20 {
		count = 5
	}
	result := make([]string, 0, count)
	cursor := m.now().In(location)
	for range count {
		cursor = parsed.Next(cursor)
		result = append(result, cursor.UTC().Format(time.RFC3339Nano))
	}
	return result, nil
}

func (m *Manager) RunNow(ref string) (model.ScheduleRun, error) {
	schedule, err := m.store.ResolveSchedule(ref)
	if err != nil {
		return model.ScheduleRun{}, err
	}
	scheduledFor := m.now().UTC().Format(time.RFC3339Nano)
	run, err := m.store.ClaimScheduleRun(schedule.ID, scheduledFor, "", true)
	if err != nil {
		return model.ScheduleRun{}, err
	}
	m.processRun(run)
	return m.store.ResolveScheduleRun(run.ID)
}

func (m *Manager) Tick() {
	now := m.now().UTC()
	_, _ = m.store.ArchiveDoneCards(now)
	schedules, err := m.store.ListSchedules("")
	if err == nil {
		for _, schedule := range schedules {
			if !schedule.Enabled || schedule.NextRunAt == "" {
				continue
			}
			due, parseErr := time.Parse(time.RFC3339Nano, schedule.NextRunAt)
			if parseErr != nil || due.After(now) {
				continue
			}
			location, locationErr := time.LoadLocation(schedule.Timezone)
			parsed, cronErr := m.parser.Parse(schedule.Cron)
			if locationErr != nil || cronErr != nil {
				continue
			}
			latest := latestOccurrence(parsed, due.In(location), now.In(location))
			next := parsed.Next(now.In(location)).UTC().Format(time.RFC3339Nano)
			_, _ = m.store.ClaimScheduleRun(schedule.ID, latest.UTC().Format(time.RFC3339Nano), next, false)
		}
	}
	runs, err := m.store.ListScheduleRuns("", 0)
	if err != nil {
		return
	}
	for _, run := range runs {
		if run.Status == model.ScheduleRunPending || run.Status == model.ScheduleRunWaitingForProject {
			m.processRun(run)
		}
	}
}

func (m *Manager) processRun(run model.ScheduleRun) {
	m.mu.Lock()
	if m.processing[run.ID] {
		m.mu.Unlock()
		return
	}
	m.processing[run.ID] = true
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		delete(m.processing, run.ID)
		m.mu.Unlock()
	}()

	schedule, err := m.store.ResolveScheduleIncludingArchived(run.ScheduleID)
	if err != nil {
		_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunCancelled, "schedule was deleted before the occurrence started")
		return
	}
	if _, err := m.store.ResolveProject(schedule.ProjectID); err != nil {
		_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunCancelled, "the schedule project was removed from Board")
		return
	}
	if schedule.OpenCardPolicy == "skip_if_open" && m.hasOpenCard(schedule.ID, run.CardID) {
		_, _ = m.store.SetScheduleRunCard(run.ID, "")
		_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunSkipped, "an earlier card from this schedule is still open")
		return
	}
	card, err := m.store.ResolveCard(run.CardID)
	if errors.Is(err, store.ErrNotFound) {
		project, projectErr := m.store.ResolveProject(schedule.ProjectID)
		board, boardErr := m.store.ResolveBoard(schedule.ProjectID, schedule.BoardID)
		if projectErr != nil || boardErr != nil {
			_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunFailed, "the schedule project or board no longer exists")
			return
		}
		variables := map[string]string{
			"date": scheduledDate(run.ScheduledFor, schedule.Timezone), "scheduled_at": run.ScheduledFor,
			"project": project.Name, "board": board.Name, "schedule": schedule.Name,
		}
		origin := &model.CardOrigin{Kind: "schedule", ScheduleID: schedule.ID, ScheduleRunID: run.ID, ScheduledFor: run.ScheduledFor}
		card, err = m.app.CreateCard(context.Background(), app.CardInput{
			ID: run.CardID, Project: schedule.ProjectID, Board: schedule.BoardID, Lane: model.LaneTodo,
			Title: render(schedule.TitleTemplate, variables), Prompt: render(schedule.PromptTemplate, variables),
			Provider: schedule.Provider, Model: schedule.Model, Effort: schedule.Effort, ProviderOptions: schedule.ProviderOptions, LabelIDs: schedule.LabelIDs, Origin: origin, DeferStart: true,
		})
	}
	if err != nil {
		_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunFailed, err.Error())
		return
	}
	if run.Action == model.ScheduleActionDraft {
		_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunCompleted, "draft card created")
		return
	}
	updates, err := m.app.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
	if errors.Is(err, store.ErrCapacity) || strings.Contains(errString(err), "project already has an active turn") {
		if schedule.BusyPolicy == "skip" {
			_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunSkipped, err.Error())
		} else {
			_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunWaitingForProject, err.Error())
		}
		return
	}
	if err != nil {
		_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunFailed, err.Error())
		return
	}
	_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunStarting, "agent turn admitted")
	_, _ = m.store.UpdateScheduleRun(run.ID, model.ScheduleRunRunning, "agent turn started")
	go m.observe(run.ID, updates)
}

func latestOccurrence(schedule cron.Schedule, first, now time.Time) time.Time {
	start := first
	if now.Sub(first) > 32*24*time.Hour {
		for _, window := range []time.Duration{32 * 24 * time.Hour, 370 * 24 * time.Hour, 5 * 366 * 24 * time.Hour, 20 * 366 * 24 * time.Hour} {
			candidate := schedule.Next(now.Add(-window))
			if !candidate.After(now) {
				start = candidate
				break
			}
		}
	}
	latest := start
	for next := schedule.Next(latest); !next.After(now); next = schedule.Next(next) {
		latest = next
	}
	return latest
}

func (m *Manager) observe(runID string, updates <-chan app.TurnUpdate) {
	failed, interrupted, message := false, false, ""
	for update := range updates {
		if update.Err != nil {
			failed, message = true, update.Err.Error()
		}
		if len(update.Chunk) > 0 {
			var chunk struct{ Type, ErrorText string }
			if json.Unmarshal(update.Chunk, &chunk) == nil {
				if chunk.Type == "abort" {
					interrupted = true
				}
				if chunk.Type == "error" && message == "" {
					failed, message = true, chunk.ErrorText
				}
			}
		}
	}
	status := model.ScheduleRunCompleted
	if interrupted {
		status, message = model.ScheduleRunInterrupted, "agent turn was interrupted"
	} else if failed {
		status = model.ScheduleRunFailed
	}
	_, _ = m.store.UpdateScheduleRun(runID, status, message)
}

func (m *Manager) hasOpenCard(scheduleID, excludeCardID string) bool {
	cards, err := m.store.ListCards(store.CardFilter{})
	if err != nil {
		return false
	}
	for _, card := range cards {
		if card.ID != excludeCardID && !card.Archived && card.Lane != model.LaneDone && card.Origin != nil && card.Origin.ScheduleID == scheduleID {
			return true
		}
	}
	return false
}

func scheduledDate(value, timezone string) string {
	parsed, err := time.Parse(time.RFC3339Nano, value)
	location, locationErr := time.LoadLocation(timezone)
	if err != nil || locationErr != nil {
		return value
	}
	return parsed.In(location).Format("2006-01-02")
}

func render(template string, variables map[string]string) string {
	result := template
	for key, value := range variables {
		result = strings.ReplaceAll(result, "{{"+key+"}}", value)
	}
	return result
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
