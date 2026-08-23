package daemon

import "testing"

func TestRelayMethodPriorityKeepsCommandsAheadOfStreams(t *testing.T) {
	for _, method := range []string{
		"/dieter.v1.DieterService/StartCard",
		"/dieter.v1.DieterService/MoveCard",
		"/dieter.v1.DieterService/Health",
	} {
		if !relayMethodPriority(method) {
			t.Fatalf("%s should use the priority relay queue", method)
		}
	}
	for _, method := range []string{
		"/dieter.v1.DieterService/WatchSync",
		"/dieter.v1.DieterService/WatchConversation",
		"/dieter.v1.DieterService/WatchState",
		"/dieter.v1.DieterService/WatchTerminal",
	} {
		if relayMethodPriority(method) {
			t.Fatalf("%s should use the bounded streaming relay queue", method)
		}
	}
}
