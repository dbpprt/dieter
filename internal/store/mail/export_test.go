package mail

import "time"

// SetNow replaces the clock of s for a test.
func SetNow(s *Store, now func() time.Time) { s.now = now }

// SetBounds lowers the store bounds for a test and returns the restore.
func SetBounds(messages int, bodyBytes int64) func() {
	oldMessages, oldBytes := maxMessages, maxBodyBytes
	maxMessages, maxBodyBytes = messages, bodyBytes
	return func() { maxMessages, maxBodyBytes = oldMessages, oldBytes }
}
