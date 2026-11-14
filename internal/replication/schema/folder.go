package schema

import (
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
)

// FolderMemberNamespace holds each daemon's membership of synced folders:
// key <folder>.<daemon>, written only by that daemon (the public KV API
// refuses), with the client members homed on it. It never holds a path.
const FolderMemberNamespace = "folder-member"

// Folder replication bounds.
const (
	MaxFolders           = 64
	MaxFolderMembers     = 16
	MaxFolderClients     = 16
	folderMemberTextSize = 512
)

// Folder member states, as the folder-member records spell them.
var folderStates = []string{"idle", "scanning", "syncing", "paused", "attention", "error"}

// FolderClientRecord is a client member homed on the writing daemon.
type FolderClientRecord struct {
	DeviceID     string `json:"deviceId"`
	Name         string `json:"name,omitempty"`
	Mode         string `json:"mode"`
	LastSeenAt   string `json:"lastSeenAt,omitempty"`
	Acknowledged uint64 `json:"acknowledged,omitempty"`
}

// FolderMemberRecord is one daemon's membership of one folder.
type FolderMemberRecord struct {
	FolderID    string               `json:"folderId"`
	DaemonID    string               `json:"daemonId"`
	Name        string               `json:"name,omitempty"`
	Mode        string               `json:"mode"`
	Paused      bool                 `json:"paused,omitempty"`
	State       string               `json:"state"`
	StateDetail string               `json:"stateDetail,omitempty"`
	IndexID     string               `json:"indexId,omitempty"`
	Sequence    uint64               `json:"sequence,omitempty"`
	LastSyncAt  string               `json:"lastSyncAt,omitempty"`
	NeedFiles   int64                `json:"needFiles,omitempty"`
	NeedBytes   int64                `json:"needBytes,omitempty"`
	Conflicts   int                  `json:"conflicts,omitempty"`
	Clients     []FolderClientRecord `json:"clients,omitempty"`
}

// DaemonNamespaceKind reports whether only daemons write ns: the agent
// channel namespaces and folder membership.
func DaemonNamespaceKind(ns string) bool {
	return ChannelNamespaceKind(ns) || ns == FolderMemberNamespace
}

// FolderMemberKey is the key of a daemon's membership of a folder.
func FolderMemberKey(folderID, daemonID string) string { return folderID + "." + daemonID }

func folderText(s string) bool {
	return len(s) <= folderMemberTextSize && utf8.ValidString(s) && !strings.ContainsAny(s, "\x00")
}

func folderTime(s string) bool {
	if s == "" {
		return true
	}
	_, err := time.Parse(time.RFC3339Nano, s)
	return err == nil
}

// DecodeFolderMember decodes and validates a membership record stored at key.
func DecodeFolderMember(key string, raw []byte) (FolderMemberRecord, error) {
	var value FolderMemberRecord
	if err := strictJSON(raw, &value); err != nil {
		return value, err
	}
	parts := strings.Split(key, ".")
	if len(parts) != 2 || parts[0] != value.FolderID || parts[1] != value.DaemonID || !channelID(value.FolderID) || !channelID(value.DaemonID) {
		return value, fault.New(fault.Invalid, "folder member key does not match its folder and daemon")
	}
	if !folders.ValidMode(folders.Mode(value.Mode)) || !slices.Contains(folderStates, value.State) {
		return value, fault.New(fault.Invalid, "invalid folder member mode or state")
	}
	if !folderText(value.Name) || !folderText(value.StateDetail) || len(value.IndexID) > 64 || !folderTime(value.LastSyncAt) ||
		value.NeedFiles < 0 || value.NeedBytes < 0 || value.Conflicts < 0 {
		return value, fault.New(fault.Invalid, "invalid folder member fields")
	}
	if len(value.Clients) > MaxFolderClients {
		return value, fault.New(fault.Invalid, "too many folder clients")
	}
	seen := map[string]bool{}
	for _, client := range value.Clients {
		if client.DeviceID == "" || len(client.DeviceID) > 128 || seen[client.DeviceID] || !folderText(client.Name) ||
			!folders.ValidMode(folders.Mode(client.Mode)) || !folderTime(client.LastSeenAt) {
			return value, fault.New(fault.Invalid, "invalid folder client")
		}
		seen[client.DeviceID] = true
	}
	return value, nil
}
