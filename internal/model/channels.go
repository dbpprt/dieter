package model

import "strings"

// Agent channels: one message channel per project on each daemon, on for
// every project and card. Messages, deliveries and read positions are
// daemon-local.

// Channel message kinds. Agents and humans write note, request, done and
// decision; Dieter writes claim, hold and release coordination events.
const (
	ChannelKindNote     = "note"
	ChannelKindRequest  = "request"
	ChannelKindDone     = "done"
	ChannelKindDecision = "decision"
	ChannelKindClaim    = "claim"
	ChannelKindHold     = "hold"
	ChannelKindRelease  = "release"
)

// Channel author kinds.
const (
	ChannelAuthorAgent  = "agent"
	ChannelAuthorHuman  = "human"
	ChannelAuthorDieter = "dieter"
)

// Channel delivery modes: how a message reached one recipient card.
const (
	ChannelDeliveryPending = "pending"
	ChannelDeliverySteered = "steered"
	ChannelDeliveryDigest  = "digest"
	ChannelDeliveryInbox   = "inbox"
	ChannelDeliveryWoke    = "woke"
)

// Channel bounds.
const (
	ChannelMaxBodyBytes  = 4096
	ChannelMaxFiles      = 16
	ChannelMaxRecipients = 32
)

// ChannelWakeMessagePrefix marks a user message that a channel message
// started (a wake). The conversation store records origin "channel" in the
// message metadata for it, including after queueing.
const ChannelWakeMessagePrefix = "msg_channel_"

// IsChannelWakeMessage reports whether messageID was created by a channel wake.
func IsChannelWakeMessage(messageID string) bool {
	return strings.HasPrefix(messageID, ChannelWakeMessagePrefix)
}

type ChannelAuthor struct {
	Kind     string `json:"kind"`
	CardID   string `json:"cardId,omitempty"`
	Title    string `json:"title,omitempty"`
	Harness  string `json:"harness,omitempty"`
	Model    string `json:"model,omitempty"`
	DeviceID string `json:"deviceId,omitempty"`
}

// ChannelDeliveryEntry is one delivery of a message to a known card, as a
// receipt replicates it.
type ChannelDeliveryEntry struct {
	MessageID string
	Mode      string
	At        string
}

// ChannelPinChange is one pin change of a message.
type ChannelPinChange struct {
	MessageID string
	Pinned    bool
	At        string
}

type ChannelDelivery struct {
	CardID string `json:"cardId"`
	Mode   string `json:"mode"`
	At     string `json:"at"`
}

// ChannelMessage is one post of a project channel. Seq orders the channel;
// Pinned, Deliveries and ReplyCount are projections of later events.
type ChannelMessage struct {
	ID        string        `json:"id"`
	ProjectID string        `json:"projectId"`
	Seq       int64         `json:"seq"`
	ThreadID  string        `json:"threadId,omitempty"`
	Kind      string        `json:"kind"`
	Author    ChannelAuthor `json:"author"`
	To        []string      `json:"to,omitempty"`
	// Here mentions every running member: it steers them on every machine
	// and is not part of later digests. Only people post it.
	Here  bool     `json:"here,omitempty"`
	Body  string   `json:"body"`
	Files []string `json:"files,omitempty"`
	// Origin is the daemon the message was posted on; OriginSeq numbers its
	// replicated messages of the project. Dieter's own coordination events
	// (claim, hold, release) are not replicated and have no origin sequence.
	Origin    string `json:"origin,omitempty"`
	OriginSeq int64  `json:"originSeq,omitempty"`
	// Wake asks the recipients' owner daemons to start idle direct recipients.
	Wake       bool              `json:"wake,omitempty"`
	Pinned     bool              `json:"pinned,omitempty"`
	CreatedAt  string            `json:"createdAt"`
	ReplyCount int               `json:"-"`
	Deliveries []ChannelDelivery `json:"-"`
}

// Direct reports whether cardID is one of the message's named recipients.
func (m ChannelMessage) Direct(cardID string) bool {
	for _, to := range m.To {
		if to == cardID {
			return true
		}
	}
	return false
}

// AddressedTo reports whether the message is for cardID: a direct message to
// it, or a channel message it did not write.
func (m ChannelMessage) AddressedTo(cardID string) bool {
	if m.Author.CardID == cardID {
		return false
	}
	if len(m.To) == 0 {
		return true
	}
	for _, to := range m.To {
		if to == cardID {
			return true
		}
	}
	return false
}

// ChannelClaim is a live claim: a card's running turn is changing Path in its
// workspace. Claims end with the turn or an explicit release.
type ChannelClaim struct {
	ProjectID string   `json:"projectId"`
	Workspace string   `json:"workspace"`
	Path      string   `json:"path"`
	CardID    string   `json:"cardId"`
	CardTitle string   `json:"cardTitle"`
	Since     string   `json:"since"`
	Waiting   []string `json:"waiting,omitempty"`
	// Parked claims belong to a card that ended its turn waiting for another
	// card's file; they hold its uncommitted changes until it is woken.
	Parked bool `json:"parked,omitempty"`
	// Daemon is the machine whose checkout the claim is in. Remote claims are
	// another machine's: advisory here, never blocking.
	Daemon string `json:"daemon,omitempty"`
	Remote bool   `json:"remote,omitempty"`
}
