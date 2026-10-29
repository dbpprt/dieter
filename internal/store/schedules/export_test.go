package schedules

import (
	"database/sql"

	"github.com/dbpprt/dieter/internal/model"
)

// Test seams for the external schedule tests, which run against the composed store.

// Database is the schedules.db handle (fixture seeding).
func (s *Store) Database() (*sql.DB, error) { return s.scheduleDatabase() }

// InsertRunDocument inserts an occurrence record unless its ID exists.
func InsertRunDocument(db *sql.DB, run model.ScheduleRun, nextAttemptAt string) error {
	return insertScheduleRunDocument(db, run, nextAttemptAt)
}
