package peerstore

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// ValidateSettings is the first consumer's explicit schema allowlist. The CRDT
// itself is schema-independent. Paths, credentials, executable environments and
// machine admission policy intentionally have no field here.
func ValidateSettings(r Record) error {
	if DomainKind(r.Kind) {
		return ValidateDomain(r)
	}
	if r.Kind != "project-settings" && r.Kind != "board-settings" {
		return errors.New("unsupported peer record kind")
	}
	for _, v := range r.Versions {
		if v.Deleted {
			continue
		}
		var data map[string]json.RawMessage
		if err := json.Unmarshal(v.Value, &data); err != nil || data == nil {
			return errors.New("settings must be a JSON object")
		}
		for field, raw := range data {
			switch field {
			case "name", "summary", "prompt", "promptTemplate", "baseRemote", "baseBranch":
				var s string
				if json.Unmarshal(raw, &s) != nil || bytes.Equal(raw, []byte("null")) {
					return fmt.Errorf("%s must be a string", field)
				}
			case "projectId":
				var s string
				if r.Kind != "board-settings" || json.Unmarshal(raw, &s) != nil || !ValidID(s) {
					return errors.New("invalid shared projectId")
				}
			case "workflow", "doneArchivePolicy", "remotePublishMode":
				var text string
				if r.Kind != "board-settings" || json.Unmarshal(raw, &text) != nil {
					return fmt.Errorf("invalid board field %s", field)
				}
				allowed := map[string][]string{"workflow": {"review", "direct"}, "doneArchivePolicy": {"never", "immediately", "after_1_day", "after_7_days", "after_30_days", "after_90_days"}, "remotePublishMode": {"manual", "pull_request", "push_base"}}
				valid := false
				for _, v := range allowed[field] {
					if text == v {
						valid = true
					}
				}
				if !valid {
					return fmt.Errorf("unsupported %s", field)
				}
			case "labels":
				if r.Kind != "board-settings" {
					return errors.New("labels belong to boards")
				}
				var labels []struct {
					ID           string `json:"id"`
					Name         string `json:"name"`
					Color        string `json:"color"`
					Instructions string `json:"instructions"`
				}
				decoder := json.NewDecoder(bytes.NewReader(raw))
				decoder.DisallowUnknownFields()
				if decoder.Decode(&labels) != nil || len(labels) > 128 {
					return errors.New("invalid shared labels")
				}
				seen := map[string]bool{}
				for _, label := range labels {
					if !ValidID(label.ID) || seen[label.ID] || strings.TrimSpace(label.Name) == "" || len(label.Name) > 128 {
						return errors.New("invalid or duplicate label identity")
					}
					seen[label.ID] = true
				}
			case "hostnames":
				var v []string
				if json.Unmarshal(raw, &v) != nil || len(v) > 64 {
					return errors.New("invalid hostnames")
				}
				for _, h := range v {
					if len(h) > 253 || strings.ContainsAny(h, "/@\\ \t\r\n") {
						return errors.New("hostnames must be credential-free host mappings")
					}
				}
			default:
				return fmt.Errorf("unsupported shared settings field %q", field)
			}
		}
	}
	return nil
}
