package accounts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

const maxAuditBytes = 4 << 20

// auditEntry is one sign-in, sign-out, reset or cleanup on this machine. It
// never holds a secret.
type auditEntry struct {
	Time      string `json:"time"`
	AccountID string `json:"accountId"`
	DaemonID  string `json:"daemonId,omitempty"`
	Action    string `json:"action"`
	Outcome   string `json:"outcome"`
}

func (s *Service) auditPath() string {
	return filepath.Join(s.store.ProviderAccountsDir(), "audit.ndjson")
}

// audit appends to the local audit log, bounded to two 4 MiB generations
// like the vault audit.
func (s *Service) audit(accountID, action, outcome string) {
	raw, err := json.Marshal(auditEntry{Time: s.now().UTC().Format(time.RFC3339Nano), AccountID: accountID, DaemonID: s.daemonID(), Action: action, Outcome: outcome})
	if err != nil {
		return
	}
	if err := s.appendAudit(raw); err != nil {
		s.log.Warn("provider account audit not recorded", "account", accountID, "action", action, "error", err)
	}
}

func (s *Service) appendAudit(line []byte) error {
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	if err := os.MkdirAll(s.store.ProviderAccountsDir(), 0o700); err != nil {
		return err
	}
	release, err := s.store.BeginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	path := s.auditPath()
	if info, err := os.Stat(path); err == nil && info.Size()+int64(len(line)) > maxAuditBytes {
		if err := os.Rename(path, path+".1"); err != nil {
			return err
		}
	}
	return appendLine(path, line)
}
