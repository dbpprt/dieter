package store

import (
	"database/sql"

	"modernc.org/sqlite"
)

// openSQLite opens a database through the SQLite driver directly rather than
// the process-wide database/sql registry, so the store never depends on a
// side-effect import having registered a driver name.
func openSQLite(dsn string) (*sql.DB, error) {
	connector, err := sqlite.NewConnector(dsn)
	if err != nil {
		return nil, err
	}
	return sql.OpenDB(connector), nil
}
