package server

import "github.com/dbpprt/dieter/internal/store"

// A quiet selected conversation must not repeatedly decode its card, copy its
// transcript, rebuild protobufs and serialize/hash the entire visible tail.
// The metadata cursor covers read receipts, workspace, project and board metadata as
// well as peer commits; transcript revision also covers asynchronous checkpoints.
type conversationWatchRevision struct {
	cursor     store.SyncCursor
	transcript string
}

func (api *grpcAPI) conversationWatchRevision(cardID string) (conversationWatchRevision, bool, error) {
	cursor, err := api.server.store.MetadataCursor()
	if err != nil {
		return conversationWatchRevision{}, false, err
	}
	transcript, err := api.server.store.ConversationRevisionByID(cardID)
	return conversationWatchRevision{cursor, transcript}, api.server.store.SyncMutationPending(), err
}
