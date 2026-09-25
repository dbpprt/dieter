package peerstore

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Domain records are independent causal registers. Keeping one field per record
// means unrelated edits never conflict or overwrite one another. Local filesystem
// paths, credentials and conversation content are deliberately absent.
var DomainFields = map[string]map[string]string{
	"schedule":   {"summary": "object"},
	"project":    {"updatedAt": "string", "identity": "object", "name": "string", "summary": "string", "prompt": "string", "promptTemplate": "string", "hostnames": "strings", "baseRemote": "string", "baseBranch": "string", "archived": "bool", "consolidatedInto": "string"},
	"board":      {"updatedAt": "string", "identity": "object", "name": "string", "description": "string", "promptTemplate": "string", "hostnames": "strings", "baseRemote": "string", "remotePublishMode": "string", "doneArchivePolicy": "string", "workflow": "string"},
	"label":      {"identity": "object", "name": "string", "color": "string", "instructions": "string", "deleted": "bool"},
	"item":       {"identity": "object", "title": "string", "placement": "object", "archived": "bool", "pinned": "bool", "doneArchiveExempt": "bool", "summary": "object"},
	"assignment": {"membership": "bool"},
	"checkout":   {"registration": "object"},
}

func DomainKind(kind string) bool { _, ok := DomainFields[kind]; return ok }
func SplitField(id string) (string, string) {
	at := strings.LastIndexByte(id, '.')
	if at < 1 {
		return "", ""
	}
	return id[:at], id[at+1:]
}

func ValidateDomain(r Record) error {
	fields, ok := DomainFields[r.Kind]
	if !ok {
		return errors.New("unknown shared domain")
	}
	entity, field := SplitField(r.ID)
	shape, ok := fields[field]
	if !ValidID(entity) || !ok {
		return errors.New("unknown shared field")
	}
	for _, version := range r.Versions {
		if version.Deleted {
			if field == "identity" || field == "registration" || r.Kind == "schedule" {
				return errors.New("shared identities cannot be deleted; archive or detach instead")
			}
			continue
		}
		raw := version.Value
		if bytes.Equal(raw, []byte("null")) {
			return errors.New("shared fields cannot be null")
		}
		var err error
		switch shape {
		case "string":
			var value string
			err = json.Unmarshal(raw, &value)
			options := map[string][]string{"workflow": {"review", "direct"}, "remotePublishMode": {"manual", "pull_request", "push_base"}, "doneArchivePolicy": {"never", "immediately", "after_1_day", "after_7_days", "after_30_days", "after_90_days"}}
			if allowed, exists := options[field]; exists {
				valid := false
				for _, option := range allowed {
					valid = valid || value == option
				}
				if !valid {
					return fmt.Errorf("invalid %s", field)
				}
			}
		case "bool":
			var value bool
			err = json.Unmarshal(raw, &value)
		case "strings":
			var value []string
			err = json.Unmarshal(raw, &value)
			if len(value) > 64 {
				return ErrCapacity
			}
		case "object":
			var value map[string]json.RawMessage
			err = json.Unmarshal(raw, &value)
			if err == nil {
				allowed := map[string]bool{}
				var names string
				switch r.Kind + "/" + field {
				case "schedule/summary":
					names = "id projectId boardId ownerDaemonId checkoutId name cron timezone enabled nextRunAt lastRunAt deleted"
				case "project/identity":
					names = "id createdAt"
				case "board/identity":
					names = "id projectId createdAt"
				case "label/identity":
					names = "id boardId"
				case "item/identity":
					names = "id projectId ownerDaemonId checkoutId scope createdAt"
				case "item/placement":
					names = "boardId lane position orderKey phaseChangedAt"
				case "item/summary":
					names = "runtime runtimeUpdatedAt lastActivityAt provider model effort initialPromptSentAt responseSeq responseMessageId seenResponseSeq mergedIntoCardId"
				case "checkout/registration":
					names = "id projectId daemonId name detached"
				}
				for _, name := range strings.Fields(names) {
					allowed[name] = true
				}
				for name, raw := range value {
					if !allowed[name] {
						return errors.New("unknown shared object field: " + name)
					}
					if bytes.Equal(raw, []byte("null")) {
						return errors.New("null shared object field: " + name)
					}
					switch name {
					case "detached", "enabled", "deleted":
						var v bool
						if json.Unmarshal(raw, &v) != nil {
							return errors.New("detached must be boolean")
						}
					case "position", "responseSeq", "seenResponseSeq":
						var v int64
						if json.Unmarshal(raw, &v) != nil || v < 0 {
							return errors.New("invalid shared count")
						}
					default:
						var v string
						if json.Unmarshal(raw, &v) != nil {
							return fmt.Errorf("%s must be a string", name)
						}
					}
				}
				if field == "identity" || field == "registration" {
					var id string
					_ = json.Unmarshal(value["id"], &id)
					if id != entity {
						return errors.New("shared object identity does not match record")
					}
					required := []string{}
					switch r.Kind {
					case "board":
						required = []string{"projectId"}
					case "label":
						required = []string{"boardId"}
					case "item":
						required = []string{"projectId", "ownerDaemonId", "checkoutId"}
					case "checkout":
						required = []string{"projectId", "daemonId"}
					}
					for _, name := range required {
						var v string
						_ = json.Unmarshal(value[name], &v)
						if !ValidID(v) {
							return fmt.Errorf("missing or invalid %s", name)
						}
					}
					if r.Kind == "item" {
						var scope string
						_ = json.Unmarshal(value["scope"], &scope)
						if scope != "board" && scope != "chat" {
							return errors.New("invalid conversation scope")
						}
					}
				}
				if field == "placement" {
					var order string
					_ = json.Unmarshal(value["orderKey"], &order)
					if len(order) > 512 || strings.IndexFunc(order, func(c rune) bool { return !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z') }) >= 0 {
						return errors.New("invalid placement key")
					}
				}
				if len(value) == 0 {
					return errors.New("empty shared object")
				}
			}
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// Selected returns a stable presentation while preserving every conflicting
// version. Tombstones win presentation; resolution still needs the full revision.
func Selected(r Record) (json.RawMessage, bool) {
	var selected Version
	for _, version := range r.Versions {
		if version.Deleted {
			return nil, false
		}
		if selected.Value == nil || PresentationRank(version) > PresentationRank(selected) {
			selected = version
		}
	}
	return selected.Value, selected.Value != nil
}
