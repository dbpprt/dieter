package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	_ "modernc.org/sqlite"
)

const (
	schedulePageDefault       = 50
	schedulePageMaximum       = 100
	scheduleRunnableBatchSize = 100
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

type SchedulePage struct {
	Items         []model.Schedule
	NextPageToken string
	TotalCount    int
}

type ScheduleRunPage struct {
	Items         []model.ScheduleRun
	NextPageToken string
}

type schedulePageCursor struct {
	ProjectID string `json:"projectId"`
	Name      string `json:"name"`
	ID        string `json:"id"`
}

type scheduleRunPageCursor struct {
	ScheduleID       string `json:"scheduleId"`
	ScheduledForNano int64  `json:"scheduledForNano"`
	ID               string `json:"id"`
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

func boundedSchedulePageSize(value int) int {
	if value <= 0 {
		return schedulePageDefault
	}
	if value > schedulePageMaximum {
		return schedulePageMaximum
	}
	return value
}

func encodeScheduleCursor(value any) (string, error) {
	raw, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func decodeScheduleCursor(token string, value any) error {
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(token))
	if err != nil {
		return errors.New("invalid schedule page token")
	}
	if err := json.Unmarshal(raw, value); err != nil {
		return errors.New("invalid schedule page token")
	}
	return nil
}

func indexedScheduleTime(value string) int64 {
	parsed, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(value))
	if err != nil {
		return 0
	}
	return parsed.UnixNano()
}

func (s *Store) scheduleDatabase() (*sql.DB, error) {
	s.scheduleDBMu.Lock()
	defer s.scheduleDBMu.Unlock()
	if s.scheduleDB != nil {
		return s.scheduleDB, nil
	}
	if err := os.MkdirAll(s.Root, 0o755); err != nil {
		return nil, err
	}
	database, err := sql.Open("sqlite", s.scheduleDatabasePath())
	if err != nil {
		return nil, err
	}
	database.SetMaxOpenConns(1)
	database.SetMaxIdleConns(1)
	if _, err = database.Exec(`
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=10000;
PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS schedule_metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS schedules (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  board_id TEXT NOT NULL,
  name TEXT NOT NULL,
  enabled INTEGER NOT NULL,
  next_run_at TEXT NOT NULL,
  next_run_at_ns INTEGER NOT NULL,
  last_run_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  document BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS schedules_project_name ON schedules(project_id, name COLLATE NOCASE, id);
CREATE INDEX IF NOT EXISTS schedules_due_time ON schedules(enabled, next_run_at_ns, id);
CREATE TABLE IF NOT EXISTS schedule_runs (
  id TEXT PRIMARY KEY,
  schedule_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  board_id TEXT NOT NULL,
  card_id TEXT NOT NULL,
  scheduled_for TEXT NOT NULL,
  scheduled_for_ns INTEGER NOT NULL,
  status TEXT NOT NULL,
  next_attempt_at TEXT NOT NULL DEFAULT '',
  next_attempt_at_ns INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  document BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS schedule_runs_history_time ON schedule_runs(schedule_id, scheduled_for_ns DESC, id DESC);
CREATE INDEX IF NOT EXISTS schedule_runs_project_history_time ON schedule_runs(project_id, scheduled_for_ns DESC, id DESC);
CREATE INDEX IF NOT EXISTS schedule_runs_runnable_time ON schedule_runs(status, next_attempt_at_ns, scheduled_for_ns, id);
CREATE INDEX IF NOT EXISTS schedule_runs_card ON schedule_runs(card_id);
`); err != nil {
		_ = database.Close()
		return nil, err
	}
	if err = s.migrateLegacySchedules(database); err != nil {
		_ = database.Close()
		return nil, err
	}
	s.scheduleDB = database
	return database, nil
}

func (s *Store) migrateLegacySchedules(database *sql.DB) error {
	var marker string
	err := database.QueryRow(`SELECT value FROM schedule_metadata WHERE key = 'legacy_markdown_v1'`).Scan(&marker)
	if err == nil {
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	tx, err := database.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	schedulePaths, err := listMarkdown(s.scheduleDir())
	if err != nil {
		return err
	}
	for _, path := range schedulePaths {
		var item model.Schedule
		body, readErr := readMarkdown(path, &item)
		if readErr != nil {
			return readErr
		}
		item.PromptTemplate = body
		item.WorkspaceMode, readErr = normalizeWorkspaceMode(item.WorkspaceMode)
		if readErr != nil {
			return readErr
		}
		if err := insertScheduleDocument(tx, item); err != nil {
			return err
		}
	}
	runPaths, err := listMarkdown(s.scheduleRunDir())
	if err != nil {
		return err
	}
	for _, path := range runPaths {
		var item model.ScheduleRun
		body, readErr := readMarkdown(path, &item)
		if readErr != nil {
			return readErr
		}
		item.Message = body
		if err := insertScheduleRunDocument(tx, item, ""); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`INSERT OR IGNORE INTO schedule_metadata(key, value) VALUES('legacy_markdown_v1', ?)`, timestamp()); err != nil {
		return err
	}
	return tx.Commit()
}

type sqlExecutor interface {
	Exec(query string, args ...any) (sql.Result, error)
}

func insertScheduleDocument(executor sqlExecutor, item model.Schedule) error {
	raw, err := json.Marshal(item)
	if err != nil {
		return err
	}
	_, err = executor.Exec(`
INSERT OR IGNORE INTO schedules(id, project_id, board_id, name, enabled, next_run_at, next_run_at_ns, last_run_at, created_at, updated_at, document)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, item.ID, item.ProjectID, item.BoardID, item.Name, item.Enabled,
		item.NextRunAt, indexedScheduleTime(item.NextRunAt), item.LastRunAt, item.CreatedAt, item.UpdatedAt, raw)
	return err
}

func upsertScheduleDocument(executor sqlExecutor, item model.Schedule) error {
	raw, err := json.Marshal(item)
	if err != nil {
		return err
	}
	_, err = executor.Exec(`
INSERT INTO schedules(id, project_id, board_id, name, enabled, next_run_at, next_run_at_ns, last_run_at, created_at, updated_at, document)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id, board_id=excluded.board_id, name=excluded.name,
 enabled=excluded.enabled, next_run_at=excluded.next_run_at, next_run_at_ns=excluded.next_run_at_ns, last_run_at=excluded.last_run_at,
 created_at=excluded.created_at, updated_at=excluded.updated_at, document=excluded.document`, item.ID, item.ProjectID,
		item.BoardID, item.Name, item.Enabled, item.NextRunAt, indexedScheduleTime(item.NextRunAt), item.LastRunAt, item.CreatedAt, item.UpdatedAt, raw)
	return err
}

func insertScheduleRunDocument(executor sqlExecutor, item model.ScheduleRun, nextAttemptAt string) error {
	raw, err := json.Marshal(item)
	if err != nil {
		return err
	}
	_, err = executor.Exec(`
INSERT OR IGNORE INTO schedule_runs(id, schedule_id, project_id, board_id, card_id, scheduled_for, scheduled_for_ns, status, next_attempt_at, next_attempt_at_ns, created_at, updated_at, document)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, item.ID, item.ScheduleID, item.ProjectID, item.BoardID, item.CardID,
		item.ScheduledFor, indexedScheduleTime(item.ScheduledFor), item.Status, nextAttemptAt, indexedScheduleTime(nextAttemptAt), item.CreatedAt, item.UpdatedAt, raw)
	return err
}

func upsertScheduleRunDocument(executor sqlExecutor, item model.ScheduleRun, nextAttemptAt string) error {
	raw, err := json.Marshal(item)
	if err != nil {
		return err
	}
	_, err = executor.Exec(`
INSERT INTO schedule_runs(id, schedule_id, project_id, board_id, card_id, scheduled_for, scheduled_for_ns, status, next_attempt_at, next_attempt_at_ns, created_at, updated_at, document)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET schedule_id=excluded.schedule_id, project_id=excluded.project_id,
 board_id=excluded.board_id, card_id=excluded.card_id, scheduled_for=excluded.scheduled_for, scheduled_for_ns=excluded.scheduled_for_ns, status=excluded.status,
 next_attempt_at=excluded.next_attempt_at, next_attempt_at_ns=excluded.next_attempt_at_ns, created_at=excluded.created_at, updated_at=excluded.updated_at,
 document=excluded.document`, item.ID, item.ScheduleID, item.ProjectID, item.BoardID, item.CardID, item.ScheduledFor,
		indexedScheduleTime(item.ScheduledFor), item.Status, nextAttemptAt, indexedScheduleTime(nextAttemptAt), item.CreatedAt, item.UpdatedAt, raw)
	return err
}

func decodeScheduleDocument(raw []byte) (model.Schedule, error) {
	var item model.Schedule
	if err := json.Unmarshal(raw, &item); err != nil {
		return model.Schedule{}, err
	}
	return item, nil
}

func decodeScheduleRunDocument(raw []byte) (model.ScheduleRun, error) {
	var item model.ScheduleRun
	if err := json.Unmarshal(raw, &item); err != nil {
		return model.ScheduleRun{}, err
	}
	return item, nil
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
	database, err := s.scheduleDatabase()
	if err != nil {
		return model.Schedule{}, err
	}
	now := timestamp()
	item := model.Schedule{
		ID: newID("sch_"), ProjectID: project.ID, BoardID: board.ID, Name: input.Name,
		Description: strings.TrimSpace(input.Description), Cron: input.Cron, Timezone: input.Timezone,
		Enabled: input.Enabled, Action: input.Action, TitleTemplate: input.TitleTemplate,
		PromptTemplate: input.PromptTemplate, Provider: input.Provider, Model: input.Model,
		Effort: strings.TrimSpace(input.Effort), ProviderOptions: cloneStringMap(input.ProviderOptions),
		LabelIDs: labels, WorkspaceMode: input.WorkspaceMode, OpenCardPolicy: input.OpenCardPolicy,
		MisfirePolicy: input.MisfirePolicy, BusyPolicy: input.BusyPolicy, NextRunAt: input.NextRunAt,
		CreatedAt: now, UpdatedAt: now,
	}
	return item, insertScheduleDocument(database, item)
}

func (s *Store) scheduleByID(id string) (model.Schedule, error) {
	database, err := s.scheduleDatabase()
	if err != nil {
		return model.Schedule{}, err
	}
	var raw []byte
	if err := database.QueryRow(`SELECT document FROM schedules WHERE id = ?`, strings.TrimSpace(id)).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return model.Schedule{}, ErrNotFound
		}
		return model.Schedule{}, err
	}
	return decodeScheduleDocument(raw)
}

func (s *Store) listSchedules() ([]model.Schedule, error) {
	database, err := s.scheduleDatabase()
	if err != nil {
		return nil, err
	}
	rows, err := database.Query(`SELECT document FROM schedules ORDER BY name COLLATE NOCASE, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanScheduleRows(rows)
}

func scanScheduleRows(rows *sql.Rows) ([]model.Schedule, error) {
	result := make([]model.Schedule, 0)
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		item, err := decodeScheduleDocument(raw)
		if err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
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
		projects, err := s.ListProjects()
		if err != nil {
			return nil, err
		}
		for _, project := range projects {
			activeProjects[project.ID] = true
		}
	}
	database, err := s.scheduleDatabase()
	if err != nil {
		return nil, err
	}
	query := `SELECT document FROM schedules`
	args := []any{}
	if projectID != "" {
		query += ` WHERE project_id = ?`
		args = append(args, projectID)
	}
	query += ` ORDER BY name COLLATE NOCASE, id`
	rows, err := database.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items, err := scanScheduleRows(rows)
	if err != nil || projectID != "" {
		return items, err
	}
	result := items[:0]
	for _, item := range items {
		if activeProjects[item.ProjectID] {
			result = append(result, item)
		}
	}
	return result, nil
}

func (s *Store) ListSchedulesPage(projectRef string, pageSize int, pageToken string) (SchedulePage, error) {
	projectID := ""
	where := ""
	filterArgs := []any{}
	if strings.TrimSpace(projectRef) != "" {
		project, err := s.ResolveProject(projectRef)
		if err != nil {
			return SchedulePage{}, err
		}
		projectID = project.ID
		where = `project_id = ?`
		filterArgs = append(filterArgs, projectID)
	} else {
		projects, err := s.ListProjects()
		if err != nil {
			return SchedulePage{}, err
		}
		if len(projects) == 0 {
			return SchedulePage{}, nil
		}
		placeholders := make([]string, len(projects))
		for index, project := range projects {
			placeholders[index] = "?"
			filterArgs = append(filterArgs, project.ID)
		}
		where = `project_id IN (` + strings.Join(placeholders, ",") + `)`
	}
	pageSize = boundedSchedulePageSize(pageSize)
	cursor := schedulePageCursor{ProjectID: projectID}
	if strings.TrimSpace(pageToken) != "" {
		if err := decodeScheduleCursor(pageToken, &cursor); err != nil || cursor.ProjectID != projectID || cursor.ID == "" {
			return SchedulePage{}, errors.New("invalid schedule page token")
		}
	}
	database, err := s.scheduleDatabase()
	if err != nil {
		return SchedulePage{}, err
	}
	var total int
	if err := database.QueryRow(`SELECT COUNT(*) FROM schedules WHERE `+where, filterArgs...).Scan(&total); err != nil {
		return SchedulePage{}, err
	}
	query := `SELECT document FROM schedules WHERE ` + where
	args := append([]any(nil), filterArgs...)
	if cursor.ID != "" {
		query += ` AND (name COLLATE NOCASE > ? OR (name = ? COLLATE NOCASE AND id > ?))`
		args = append(args, cursor.Name, cursor.Name, cursor.ID)
	}
	query += ` ORDER BY name COLLATE NOCASE, id LIMIT ?`
	args = append(args, pageSize+1)
	rows, err := database.Query(query, args...)
	if err != nil {
		return SchedulePage{}, err
	}
	defer rows.Close()
	items, err := scanScheduleRows(rows)
	if err != nil {
		return SchedulePage{}, err
	}
	result := SchedulePage{Items: items, TotalCount: total}
	if len(items) > pageSize {
		result.Items = items[:pageSize]
		last := result.Items[len(result.Items)-1]
		result.NextPageToken, err = encodeScheduleCursor(schedulePageCursor{ProjectID: projectID, Name: last.Name, ID: last.ID})
	}
	return result, err
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
	if item, err := s.scheduleByID(ref); err == nil {
		if _, projectErr := s.ResolveProject(item.ProjectID); projectErr == nil {
			return item, nil
		}
	} else if !errors.Is(err, ErrNotFound) {
		return model.Schedule{}, err
	}
	items, err := s.ListSchedules("")
	if err != nil {
		return model.Schedule{}, err
	}
	return resolveSchedule(items, ref)
}

func (s *Store) ResolveScheduleIncludingArchived(ref string) (model.Schedule, error) {
	if item, err := s.scheduleByID(ref); err == nil {
		return item, nil
	} else if !errors.Is(err, ErrNotFound) {
		return model.Schedule{}, err
	}
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
	current.WorkspaceMode = input.WorkspaceMode
	current.OpenCardPolicy, current.MisfirePolicy, current.BusyPolicy, current.NextRunAt = input.OpenCardPolicy, input.MisfirePolicy, input.BusyPolicy, input.NextRunAt
	current.UpdatedAt = timestamp()
	database, err := s.scheduleDatabase()
	if err != nil {
		return model.Schedule{}, err
	}
	return current, upsertScheduleDocument(database, current)
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
	database, err := s.scheduleDatabase()
	if err != nil {
		return model.Schedule{}, err
	}
	return item, upsertScheduleDocument(database, item)
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
	database, err := s.scheduleDatabase()
	if err != nil {
		return err
	}
	_, err = database.Exec(`DELETE FROM schedules WHERE id = ?`, item.ID)
	return err
}

func occurrenceIDs(scheduleID, scheduledFor string) (string, string) {
	digest := sha256.Sum256([]byte(scheduleID + "\x00" + scheduledFor))
	suffix := fmt.Sprintf("%x", digest[:12])
	return "sr_" + suffix, "c_sched_" + suffix
}

// ClaimScheduleRun atomically establishes the occurrence and advances the
// schedule cursor in the same SQLite transaction. The deterministic primary
// key preserves the no-replay guarantee across retries and daemon restarts.
func (s *Store) ClaimScheduleRun(scheduleID, scheduledFor, nextRunAt string, manual bool) (model.ScheduleRun, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	defer release()
	database, err := s.scheduleDatabase()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	tx, err := database.BeginTx(context.Background(), nil)
	if err != nil {
		return model.ScheduleRun{}, err
	}
	defer tx.Rollback()
	var scheduleRaw []byte
	if err := tx.QueryRow(`SELECT document FROM schedules WHERE id = ?`, scheduleID).Scan(&scheduleRaw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return model.ScheduleRun{}, fmt.Errorf("schedule %q: %w", scheduleID, ErrNotFound)
		}
		return model.ScheduleRun{}, err
	}
	schedule, err := decodeScheduleDocument(scheduleRaw)
	if err != nil {
		return model.ScheduleRun{}, err
	}
	if _, err := s.ResolveProject(schedule.ProjectID); err != nil {
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
	var existingRaw []byte
	if err := tx.QueryRow(`SELECT document FROM schedule_runs WHERE id = ?`, runID).Scan(&existingRaw); err == nil {
		existing, decodeErr := decodeScheduleRunDocument(existingRaw)
		if decodeErr != nil {
			return model.ScheduleRun{}, decodeErr
		}
		if !manual {
			schedule.NextRunAt, schedule.LastRunAt, schedule.UpdatedAt = nextRunAt, scheduledFor, timestamp()
			if err := upsertScheduleDocument(tx, schedule); err != nil {
				return model.ScheduleRun{}, err
			}
		}
		if err := tx.Commit(); err != nil {
			return model.ScheduleRun{}, err
		}
		return existing, nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return model.ScheduleRun{}, err
	}
	now := timestamp()
	run := model.ScheduleRun{ID: runID, ScheduleID: schedule.ID, ProjectID: schedule.ProjectID, BoardID: schedule.BoardID,
		CardID: cardID, ScheduledFor: scheduledFor, Manual: manual, Action: schedule.Action,
		Status: model.ScheduleRunPending, CreatedAt: now, UpdatedAt: now}
	if err := insertScheduleRunDocument(tx, run, ""); err != nil {
		return model.ScheduleRun{}, err
	}
	if !manual {
		schedule.NextRunAt = nextRunAt
	}
	schedule.LastRunAt, schedule.UpdatedAt = scheduledFor, now
	if err := upsertScheduleDocument(tx, schedule); err != nil {
		return model.ScheduleRun{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.ScheduleRun{}, err
	}
	return run, nil
}

func (s *Store) ResolveScheduleRun(ref string) (model.ScheduleRun, error) {
	database, err := s.scheduleDatabase()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	var raw []byte
	if err := database.QueryRow(`SELECT document FROM schedule_runs WHERE id = ?`, strings.TrimSpace(ref)).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return model.ScheduleRun{}, fmt.Errorf("schedule run %q: %w", ref, ErrNotFound)
		}
		return model.ScheduleRun{}, err
	}
	return decodeScheduleRunDocument(raw)
}

func scanScheduleRunRows(rows *sql.Rows) ([]model.ScheduleRun, error) {
	result := make([]model.ScheduleRun, 0)
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		item, err := decodeScheduleRunDocument(raw)
		if err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) ListScheduleRuns(scheduleRef string, limit int) ([]model.ScheduleRun, error) {
	scheduleID := strings.TrimSpace(scheduleRef)
	if scheduleID != "" && !strings.HasPrefix(scheduleID, "sch_") {
		schedule, err := s.ResolveScheduleIncludingArchived(scheduleID)
		if err != nil {
			return nil, err
		}
		scheduleID = schedule.ID
	}
	database, err := s.scheduleDatabase()
	if err != nil {
		return nil, err
	}
	query := `SELECT document FROM schedule_runs`
	args := []any{}
	if scheduleID != "" {
		query += ` WHERE schedule_id = ?`
		args = append(args, scheduleID)
	}
	query += ` ORDER BY scheduled_for_ns DESC, id DESC`
	if limit > 0 {
		query += ` LIMIT ?`
		args = append(args, limit)
	}
	rows, err := database.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanScheduleRunRows(rows)
}

func (s *Store) ListScheduleRunsPage(scheduleID string, pageSize int, pageToken string) (ScheduleRunPage, error) {
	scheduleID = strings.TrimSpace(scheduleID)
	if scheduleID == "" {
		return ScheduleRunPage{}, errors.New("schedule ID is required")
	}
	pageSize = boundedSchedulePageSize(pageSize)
	cursor := scheduleRunPageCursor{ScheduleID: scheduleID}
	if strings.TrimSpace(pageToken) != "" {
		if err := decodeScheduleCursor(pageToken, &cursor); err != nil || cursor.ScheduleID != scheduleID || cursor.ID == "" || cursor.ScheduledForNano == 0 {
			return ScheduleRunPage{}, errors.New("invalid schedule run page token")
		}
	}
	database, err := s.scheduleDatabase()
	if err != nil {
		return ScheduleRunPage{}, err
	}
	query := `SELECT document FROM schedule_runs WHERE schedule_id = ?`
	args := []any{scheduleID}
	if cursor.ID != "" {
		query += ` AND (scheduled_for_ns < ? OR (scheduled_for_ns = ? AND id < ?))`
		args = append(args, cursor.ScheduledForNano, cursor.ScheduledForNano, cursor.ID)
	}
	query += ` ORDER BY scheduled_for_ns DESC, id DESC LIMIT ?`
	args = append(args, pageSize+1)
	rows, err := database.Query(query, args...)
	if err != nil {
		return ScheduleRunPage{}, err
	}
	defer rows.Close()
	items, err := scanScheduleRunRows(rows)
	if err != nil {
		return ScheduleRunPage{}, err
	}
	result := ScheduleRunPage{Items: items}
	if len(items) > pageSize {
		result.Items = items[:pageSize]
		last := result.Items[len(result.Items)-1]
		result.NextPageToken, err = encodeScheduleCursor(scheduleRunPageCursor{ScheduleID: scheduleID, ScheduledForNano: indexedScheduleTime(last.ScheduledFor), ID: last.ID})
	}
	return result, err
}

func (s *Store) ListDueSchedules(now time.Time, limit int) ([]model.Schedule, error) {
	projects, err := s.ListProjects()
	if err != nil || len(projects) == 0 {
		return nil, err
	}
	if limit <= 0 {
		limit = scheduleRunnableBatchSize
	}
	placeholders := make([]string, len(projects))
	args := make([]any, 0, len(projects)+2)
	for index, project := range projects {
		placeholders[index] = "?"
		args = append(args, project.ID)
	}
	args = append(args, now.UnixNano(), limit)
	database, err := s.scheduleDatabase()
	if err != nil {
		return nil, err
	}
	query := `SELECT document FROM schedules WHERE project_id IN (` + strings.Join(placeholders, ",") + `)
 AND enabled = 1 AND next_run_at_ns > 0 AND next_run_at_ns <= ? ORDER BY next_run_at_ns, id LIMIT ?`
	rows, err := database.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanScheduleRows(rows)
}

func (s *Store) ListRunnableScheduleRuns(now time.Time, limit int) ([]model.ScheduleRun, error) {
	if limit <= 0 {
		limit = scheduleRunnableBatchSize
	}
	database, err := s.scheduleDatabase()
	if err != nil {
		return nil, err
	}
	pendingLimit := (limit + 1) / 2
	waitingLimit := limit / 2
	pendingRows, err := database.Query(`SELECT document FROM schedule_runs
 WHERE status = ? ORDER BY scheduled_for_ns, id LIMIT ?`, model.ScheduleRunPending, pendingLimit)
	if err != nil {
		return nil, err
	}
	pending, err := scanScheduleRunRows(pendingRows)
	_ = pendingRows.Close()
	if err != nil || waitingLimit == 0 {
		return pending, err
	}
	waitingRows, err := database.Query(`SELECT document FROM schedule_runs
 WHERE status = ? AND (next_attempt_at_ns = 0 OR next_attempt_at_ns <= ?)
 ORDER BY next_attempt_at_ns, scheduled_for_ns, id LIMIT ?`, model.ScheduleRunWaitingForProject, now.UnixNano(), waitingLimit)
	if err != nil {
		return nil, err
	}
	waiting, err := scanScheduleRunRows(waitingRows)
	_ = waitingRows.Close()
	if err != nil {
		return nil, err
	}
	return append(pending, waiting...), nil
}

func (s *Store) UpdateScheduleRun(ref, status, message string) (model.ScheduleRun, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	defer release()
	database, err := s.scheduleDatabase()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	tx, err := database.Begin()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	defer tx.Rollback()
	var raw []byte
	if err := tx.QueryRow(`SELECT document FROM schedule_runs WHERE id = ?`, ref).Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return model.ScheduleRun{}, fmt.Errorf("schedule run %q: %w", ref, ErrNotFound)
		}
		return model.ScheduleRun{}, err
	}
	item, err := decodeScheduleRunDocument(raw)
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
	nextAttemptAt := ""
	if status == model.ScheduleRunWaitingForProject {
		// The scheduler tick itself is the retry backoff. Keeping the row due
		// preserves the existing explicit Tick semantics used after capacity is
		// released while the indexed runnable query keeps the work bounded.
		nextAttemptAt = now
	}
	if err := upsertScheduleRunDocument(tx, item, nextAttemptAt); err != nil {
		return model.ScheduleRun{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.ScheduleRun{}, err
	}
	return item, nil
}

func (s *Store) SetScheduleRunCard(ref, cardID string) (model.ScheduleRun, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	defer release()
	database, err := s.scheduleDatabase()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	tx, err := database.Begin()
	if err != nil {
		return model.ScheduleRun{}, err
	}
	defer tx.Rollback()
	var raw []byte
	var nextAttemptAt string
	if err := tx.QueryRow(`SELECT document, next_attempt_at FROM schedule_runs WHERE id = ?`, ref).Scan(&raw, &nextAttemptAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return model.ScheduleRun{}, fmt.Errorf("schedule run %q: %w", ref, ErrNotFound)
		}
		return model.ScheduleRun{}, err
	}
	item, err := decodeScheduleRunDocument(raw)
	if err != nil {
		return model.ScheduleRun{}, err
	}
	item.CardID, item.UpdatedAt = cardID, timestamp()
	if err := upsertScheduleRunDocument(tx, item, nextAttemptAt); err != nil {
		return model.ScheduleRun{}, err
	}
	if err := tx.Commit(); err != nil {
		return model.ScheduleRun{}, err
	}
	return item, nil
}

func (s *Store) RecoverScheduleRuns() error {
	database, err := s.scheduleDatabase()
	if err != nil {
		return err
	}
	rows, err := database.Query(`SELECT document FROM schedule_runs WHERE status IN (?, ?)`, model.ScheduleRunStarting, model.ScheduleRunRunning)
	if err != nil {
		return err
	}
	runs, err := scanScheduleRunRows(rows)
	_ = rows.Close()
	if err != nil {
		return err
	}
	for _, run := range runs {
		_, _ = s.UpdateScheduleRun(run.ID, model.ScheduleRunFailed, "Dieter stopped after this agent turn was dispatched; it was not replayed automatically")
	}
	return nil
}

// sortScheduleRuns remains available to migration and tests which build model
// values directly. Production queries are ordered by the covering SQLite
// indexes and never sort the full occurrence history in memory.
func sortScheduleRuns(items []model.ScheduleRun) {
	sort.Slice(items, func(i, j int) bool {
		if items[i].ScheduledFor == items[j].ScheduledFor {
			return items[i].ID > items[j].ID
		}
		return items[i].ScheduledFor > items[j].ScheduledFor
	})
}
