package daemon

import "testing"

func TestRelayMethodPriorityKeepsCommandsAheadOfStreams(t *testing.T) {
	for _, method := range []string{
		"/nauclio.v1.NauclioService/StartCard",
		"/nauclio.v1.NauclioService/MoveCard",
		"/nauclio.v1.NauclioService/Health",
	} {
		if !relayMethodPriority(method) {
			t.Fatalf("%s should use the priority relay queue", method)
		}
	}
	for _, method := range []string{
		"/nauclio.v1.NauclioService/WatchSync",
		"/nauclio.v1.NauclioService/WatchConversation",
		"/nauclio.v1.NauclioService/WatchState",
	} {
		if relayMethodPriority(method) {
			t.Fatalf("%s should use the bounded streaming relay queue", method)
		}
	}
}
