package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
	"gopkg.in/yaml.v3"
)

type ImportReport struct {
	Root          string   `json:"root"`
	Backup        string   `json:"backup"`
	Projects      int      `json:"projects"`
	Boards        int      `json:"boards"`
	Conversations int      `json:"conversations"`
	Applied       bool     `json:"applied"`
	Notes         []string `json:"notes"`
}

type importManifest struct {
	Backup string `json:"backup"`
	Ready  bool   `json:"ready"`
}

// ImportLegacy is an explicit, offline maintenance operation. Ordinary daemon
// APIs never read the legacy project/board store. The byte-for-byte backup is
// the immutable input on every resume; the original root retains all local
// paths and conversation identities, avoiding dangling workspace references.
func (s *Store) ImportLegacy(backup string, apply bool) (ImportReport, error) {
	report := ImportReport{Root: s.Root, Backup: backup, Notes: []string{"Conversations, events, comments, schedules, and occurrence receipts retain their IDs.", "Existing peer settings are retained separately; they do not override project or board fields.", "Parallel-session caps and capacity queue policies are removed. Waiting occurrences are interrupted and never replayed automatically.", "The backup is never changed after creation. Rollback discards changes made after import."}}
	if backup == "" {
		return report, errors.New("an explicit backup directory is required")
	}
	abs, err := filepath.Abs(backup)
	if err != nil {
		return report, err
	}
	backup = filepath.Clean(abs)
	report.Backup = backup
	if backup == s.Root || strings.HasPrefix(backup, s.Root+string(filepath.Separator)) || strings.HasPrefix(s.Root, backup+string(filepath.Separator)) {
		return report, errors.New("backup must be outside the source root and cannot contain it")
	}
	var runtime struct {
		PID int `json:"pid"`
	}
	_ = readJSON(filepath.Join(s.runtimeDir(), "daemon.json"), &runtime)
	if runtime.PID > 0 && processAlive(runtime.PID) {
		return report, errors.New("source daemon is running; stop it explicitly before offline import")
	}
	leases, err := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
	if err != nil {
		return report, err
	}
	if len(leases) > 0 {
		return report, ErrCardActive
	}
	s.importing = true
	defer func() { s.importing = false }()
	release, err := s.beginWriteLock()
	if err != nil {
		return report, err
	}
	defer release()
	var manifest importManifest
	manifestPath := filepath.Join(s.Root, "import-state.json")
	source := s.Root
	if err = readJSON(manifestPath, &manifest); err == nil {
		if manifest.Backup != backup {
			return report, errors.New("resume requires the original backup directory")
		}
		if manifest.Ready {
			source = backup
		}
	} else if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, ErrNotFound) {
		return report, err
	} else {
		if raw, e := os.ReadFile(filepath.Join(s.Root, "storage-schema.json")); e == nil {
			var schema struct {
				Version int `json:"version"`
			}
			_ = json.Unmarshal(raw, &schema)
			if schema.Version == storageSchema {
				return report, errors.New("store already uses the shared project schema")
			}
		}
	}
	sourceStore := New(source)
	projects, err := listMarkdown(sourceStore.projectDir())
	if err != nil {
		return report, err
	}
	boards, err := listMarkdown(sourceStore.boardDir())
	if err != nil {
		return report, err
	}
	cards, err := listMarkdown(sourceStore.cardDir())
	if err != nil {
		return report, err
	}
	archived, err := listMarkdown(sourceStore.archivedCardDir())
	if err != nil {
		return report, err
	}
	cards = append(cards, archived...)
	report.Projects, report.Boards, report.Conversations = len(projects), len(boards), len(cards)
	if err = validateLegacyReferences(sourceStore, projects, boards, cards); err != nil {
		return report, err
	}
	if !apply {
		return report, nil
	}
	if source == s.Root {
		if manifest.Backup == "" {
			if _, err = os.Stat(backup); !errors.Is(err, os.ErrNotExist) {
				return report, errors.New("backup destination must not exist")
			}
			if err = writeJSON(manifestPath, importManifest{Backup: backup}); err != nil {
				return report, err
			}
		}
		if err = copyStoreBackup(s.Root, backup); err != nil {
			return report, err
		}
		if err = writeJSON(manifestPath, importManifest{Backup: backup, Ready: true}); err != nil {
			return report, err
		}
		source = backup
		for i, path := range projects {
			rel, _ := filepath.Rel(s.Root, path)
			projects[i] = filepath.Join(backup, rel)
		}
		for i, path := range boards {
			rel, _ := filepath.Rel(s.Root, path)
			boards[i] = filepath.Join(backup, rel)
		}
		for i, path := range cards {
			rel, _ := filepath.Rel(s.Root, path)
			cards[i] = filepath.Join(backup, rel)
		}
	}
	identity, err := s.sharedIdentity()
	if err != nil {
		return report, err
	}
	// Preserve older abstract peer documents without feeding them into domain projections.
	oldPeer := filepath.Join(source, "peers", peerstore.Revision(identity.Account)+".json")
	var oldData PeerData
	if err = readPeerJSON(oldPeer, &oldData); err == nil {
		current, e := s.PeerData(identity.Account)
		if e != nil {
			return report, e
		}
		current.State = clonePeerState(current.State)
		for key, record := range oldData.Records {
			if !peerstore.DomainKind(record.Kind) {
				merged, e := peerstore.Merge(current.Records[key], record)
				if e != nil {
					return report, e
				}
				current.Records[key] = merged
				current.Dirty[key] = true
			}
		}
		if err = s.savePeerData(identity.Account, current); err != nil {
			return report, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return report, err
	}
	checkoutByProject := map[string]model.Checkout{}
	for _, path := range projects {
		var p model.Project
		body, e := readMarkdown(path, &p)
		if e != nil {
			return report, e
		}
		p.Prompt = body
		if p.ID == "" || p.Path == "" {
			return report, fmt.Errorf("invalid legacy project %s", path)
		}
		p.SharedBase = nil
		if err = s.writeProject(p); err != nil {
			return report, err
		}
		checkout := model.Checkout{ID: "co_" + peerstore.Revision([]string{identity.DaemonID, p.ID})[:24], ProjectID: p.ID, DaemonID: identity.DaemonID, Name: filepath.Base(p.Path), Path: p.Path, ValidationCommands: p.ValidationCommands}
		if err = s.publishCheckout(checkout); err != nil {
			return report, err
		}
		checkoutByProject[p.ID] = checkout
	}
	for _, path := range boards {
		var b model.Board
		body, e := readMarkdown(path, &b)
		if e != nil {
			return report, e
		}
		if b.Description == "" {
			b.Description = body
		}
		if _, ok := checkoutByProject[b.ProjectID]; !ok {
			return report, fmt.Errorf("board %s has a missing project", b.ID)
		}
		if err = s.writeBoard(hydrateBoard(b)); err != nil {
			return report, err
		}
	}
	var values []model.Card
	for _, path := range cards {
		var card model.Card
		body, e := readMarkdown(path, &card)
		if e != nil {
			return report, e
		}
		card.InitialPrompt = body
		values = append(values, card)
	}
	sort.Slice(values, func(i, j int) bool {
		if values[i].Position != values[j].Position {
			return values[i].Position < values[j].Position
		}
		return values[i].ID < values[j].ID
	})
	for _, card := range values {
		checkout, ok := checkoutByProject[card.ProjectID]
		if !ok {
			return report, fmt.Errorf("conversation %s has a missing project", card.ID)
		}
		card.OwnerDaemonID, card.CheckoutID = identity.DaemonID, checkout.ID
		if card.Scope == "" {
			card.Scope = model.ConversationScopeBoard
			if card.BoardID == "" {
				card.Scope = model.ConversationScopeChat
			}
		}
		// Stable ordering across retries; IDs and original integer position are input.
		card.OrderKey = fmt.Sprintf("h%016x%s", uint64(card.Position), peerstore.Revision(card.ID)[:12])
		if err = s.writeCard(card); err != nil {
			return report, err
		}
	}
	// Opening this database performs the one-shot legacy schedule import. Persist
	// checkout/owner references without changing occurrence or dispatch records.
	db, err := s.scheduleDatabase()
	if err != nil {
		return report, err
	}
	schedules, err := s.listSchedules()
	if err != nil {
		return report, err
	}
	for _, item := range schedules {
		checkout, ok := checkoutByProject[item.ProjectID]
		if !ok {
			return report, fmt.Errorf("schedule %s has a missing project", item.ID)
		}
		item.OwnerDaemonID, item.CheckoutID = identity.DaemonID, checkout.ID
		if err = upsertScheduleDocument(db, item); err != nil {
			return report, err
		}
	}
	if _, err = db.Exec(`UPDATE schedule_runs SET status='interrupted', document=json_set(document, '$.status', 'interrupted', '$.message', 'Capacity waiting removed during import; not replayed automatically') WHERE status='waiting_for_project'`); err != nil {
		return report, err
	}
	for {
		var remaining int
		if err = db.QueryRow("SELECT count(*) FROM schedule_peer_outbox").Scan(&remaining); err != nil {
			return report, err
		}
		if remaining == 0 {
			break
		}
		if err = s.flushScheduleOutbox(); err != nil {
			return report, err
		}
	}
	if err = s.recoverCardWrites(); err != nil {
		return report, err
	}
	settings, err := s.readSettings()
	if err != nil {
		return report, err
	}
	rawSettings, err := yaml.Marshal(settings)
	if err != nil {
		return report, err
	}
	if err = atomicWrite(s.settingsPath(), rawSettings); err != nil {
		return report, err
	}
	if err = atomicWrite(filepath.Join(s.Root, "storage-schema.json"), []byte(`{"version":2}`)); err != nil {
		return report, err
	}
	// Remove only obsolete domain projections; the backup keeps their original bytes.
	for _, dir := range []string{s.projectDir(), s.boardDir()} {
		paths, e := listMarkdown(dir)
		if e != nil {
			return report, e
		}
		for _, path := range paths {
			if err = os.Remove(path); err != nil {
				return report, err
			}
		}
	}
	if err = os.Remove(manifestPath); err != nil {
		return report, err
	}
	report.Applied = true
	return report, nil
}

func copyStoreBackup(source, target string) error {
	var directories []string
	err := filepath.WalkDir(source, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		if rel == ".write-lock" || rel == ".writer-admission" || rel == "import-state.json" {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		to := filepath.Join(target, rel)
		if entry.IsDir() {
			directories = append(directories, to)
			return os.MkdirAll(to, 0700)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			link, e := os.Readlink(path)
			if e != nil {
				return e
			}
			if existing, e := os.Readlink(to); e == nil && existing == link {
				return nil
			}
			return os.Symlink(link, to)
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		in, err := os.Open(path)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(to, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		_, err = io.Copy(out, in)
		if err == nil {
			err = out.Sync()
		}
		closeErr := out.Close()
		if err == nil {
			err = closeErr
		}
		return err
	})
	if err != nil {
		return err
	}
	// Persist directory entries before the manifest can declare the backup ready.
	directories = append([]string{filepath.Dir(target)}, directories...)
	for i := len(directories) - 1; i >= 0; i-- {
		dir, err := os.Open(directories[i])
		if err != nil {
			return err
		}
		err = dir.Sync()
		_ = dir.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

// Validation is read-only and runs before creating the backup or destination.
// Missing parents are errors, never silently dropped items during cutover.
func validateLegacyReferences(source *Store, projectPaths, boardPaths, cardPaths []string) error {
	projects := map[string]model.Project{}
	paths := map[string]bool{}
	for _, path := range projectPaths {
		var item model.Project
		if _, err := readMarkdown(path, &item); err != nil {
			return err
		}
		if !peerstore.ValidID(item.ID) || item.Path == "" {
			return fmt.Errorf("invalid legacy project %s", path)
		}
		if _, ok := projects[item.ID]; ok {
			return fmt.Errorf("duplicate project %s", item.ID)
		}
		canonical, err := filepath.EvalSymlinks(item.Path)
		if err != nil {
			return fmt.Errorf("project %s checkout: %w", item.ID, err)
		}
		canonical, err = filepath.Abs(canonical)
		if err != nil {
			return err
		}
		if paths[canonical] {
			return fmt.Errorf("duplicate checkout path %s", canonical)
		}
		paths[canonical] = true
		if _, err = os.Stat(filepath.Join(canonical, ".git")); err != nil {
			return fmt.Errorf("project %s is not a Git checkout: %w", item.ID, err)
		}
		projects[item.ID] = item
	}
	boards := map[string]model.Board{}
	for _, path := range boardPaths {
		var item model.Board
		if _, err := readMarkdown(path, &item); err != nil {
			return err
		}
		if !peerstore.ValidID(item.ID) || projects[item.ProjectID].ID == "" {
			return fmt.Errorf("board %s has a missing project", item.ID)
		}
		if _, ok := boards[item.ID]; ok {
			return fmt.Errorf("duplicate board %s", item.ID)
		}
		boards[item.ID] = item
	}
	cards := map[string]bool{}
	for _, path := range cardPaths {
		var item model.Card
		if _, err := readMarkdown(path, &item); err != nil {
			return err
		}
		if !peerstore.ValidID(item.ID) || projects[item.ProjectID].ID == "" {
			return fmt.Errorf("conversation %s has a missing project", item.ID)
		}
		if item.BoardID != "" && boards[item.BoardID].ProjectID != item.ProjectID {
			return fmt.Errorf("conversation %s has an invalid board", item.ID)
		}
		if cards[item.ID] {
			return fmt.Errorf("duplicate conversation %s", item.ID)
		}
		cards[item.ID] = true
	}
	schedulePaths, err := listMarkdown(source.scheduleDir())
	if err != nil {
		return err
	}
	for _, path := range schedulePaths {
		var item model.Schedule
		if _, err := readMarkdown(path, &item); err != nil {
			return err
		}
		if projects[item.ProjectID].ID == "" || item.BoardID != "" && boards[item.BoardID].ProjectID != item.ProjectID {
			return fmt.Errorf("schedule %s has invalid references", item.ID)
		}
	}
	if _, err = os.Stat(source.scheduleDatabasePath()); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	// Do not invoke scheduleDatabase: it creates tables and migration triggers.
	uri := url.URL{Scheme: "file", Path: source.scheduleDatabasePath(), RawQuery: "mode=ro"}
	db, err := sql.Open("sqlite", uri.String())
	if err != nil {
		return err
	}
	defer db.Close()
	for _, table := range []string{"schedules", "schedule_runs"} {
		var exists int
		if err = db.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", table).Scan(&exists); err != nil {
			return err
		}
		if exists == 0 {
			continue
		}
		rows, err := db.Query("SELECT id, project_id, board_id, document FROM " + table)
		if err != nil {
			return err
		}
		for rows.Next() {
			var id, project, board string
			var raw []byte
			if err = rows.Scan(&id, &project, &board, &raw); err != nil {
				break
			}
			var item struct {
				ID        string `json:"id"`
				ProjectID string `json:"projectId"`
				BoardID   string `json:"boardId"`
			}
			if err = json.Unmarshal(raw, &item); err != nil {
				break
			}
			if !peerstore.ValidID(id) || item.ID != id || item.ProjectID != project || item.BoardID != board || projects[project].ID == "" || board != "" && boards[board].ProjectID != project {
				err = fmt.Errorf("%s %s has invalid references", table, id)
				break
			}
		}
		rowErr := rows.Err()
		_ = rows.Close()
		if err != nil {
			return err
		}
		if rowErr != nil {
			return rowErr
		}
	}
	return nil
}
