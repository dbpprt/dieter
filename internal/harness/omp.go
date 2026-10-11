package harness

import "encoding/json"

// LegacyOMPSession identifies ACP persistence without discarding native history
// when a migrated conversation is interrupted.
func LegacyOMPSession(state json.RawMessage) bool {
	var envelope struct {
		Data struct {
			ACPSessionID string          `json:"acpSessionId"`
			RPC          json.RawMessage `json:"ompRPC"`
		} `json:"data"`
	}
	return json.Unmarshal(state, &envelope) == nil && envelope.Data.ACPSessionID != "" && len(envelope.Data.RPC) == 0
}

func legacyOMPContinuation(state json.RawMessage) bool {
	var envelope struct {
		ContinueFrom struct {
			Data struct {
				ACPSessionID string          `json:"acpSessionId"`
				RPC          json.RawMessage `json:"ompRPC"`
			} `json:"data"`
		} `json:"continueFrom"`
	}
	return json.Unmarshal(state, &envelope) == nil && envelope.ContinueFrom.Data.ACPSessionID != "" && len(envelope.ContinueFrom.Data.RPC) == 0
}

// Canceled questions keep their persisted native session, but cannot reattach
// to the stopped dialog handle on the next human message.
func ClearOMPInput(state json.RawMessage) json.RawMessage {
	if !AwaitingOMPInput(state) {
		return state
	}
	var envelope map[string]json.RawMessage
	var data map[string]json.RawMessage
	var rpc map[string]json.RawMessage
	_ = json.Unmarshal(state, &envelope)
	_ = json.Unmarshal(envelope["data"], &data)
	_ = json.Unmarshal(data["ompRPC"], &rpc)
	delete(rpc, "pendingDialog")
	delete(rpc, "stream")
	data["ompRPC"], _ = json.Marshal(rpc)
	envelope["data"], _ = json.Marshal(data)
	cleared, _ := json.Marshal(envelope)
	return cleared
}

// AwaitingOMPInput identifies an owned native RPC dialog parked between normal
// chat messages. Its provider process must survive the terminal worker turn.
// No client-specific question operation or state is introduced.
func AwaitingOMPInput(state json.RawMessage) bool {
	var envelope struct {
		HarnessID string `json:"harnessId"`
		Data      struct {
			RPC struct {
				Version       int    `json:"version"`
				PromptID      string `json:"promptId"`
				SessionFile   string `json:"sessionFile"`
				PendingDialog struct {
					ID     string `json:"id"`
					Method string `json:"method"`
				} `json:"pendingDialog"`
			} `json:"ompRPC"`
		} `json:"data"`
	}
	if json.Unmarshal(state, &envelope) != nil || envelope.HarnessID != "omp" {
		return false
	}
	rpc := envelope.Data.RPC
	if rpc.Version != 1 || rpc.PromptID == "" || rpc.SessionFile == "" || rpc.PendingDialog.ID == "" {
		return false
	}
	switch rpc.PendingDialog.Method {
	case "select", "confirm", "input", "editor":
		return true
	default:
		return false
	}
}
