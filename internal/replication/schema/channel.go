package schema

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// Agent channels replicate as KV records in these namespaces. Every key has
// one writer, the daemon named in it (the card's owner for receipts), so
// records never conflict, and only daemons write them (the public KV API
// refuses). Values are bounded below and validated on write and on ingest.
const (
	// ChannelNamespace holds messages: key <project>.<origin daemon>.<slot>,
	// slot = origin sequence mod ChannelRingSlots, a per-origin ring.
	ChannelNamespace = "channel"
	// ChannelReceiptNamespace holds a card's latest deliveries: key <card>.
	ChannelReceiptNamespace = "channel-receipt"
	// ChannelPinsNamespace holds one daemon's latest pin changes of a
	// project: key <project>.<daemon>.
	ChannelPinsNamespace = "channel-pins"
	// ChannelClaimsNamespace holds one daemon's live claims in a project's
	// checkout: key <project>.<daemon>. They are advisory on other machines.
	ChannelClaimsNamespace = "channel-claims"
)

// Channel replication bounds.
const (
	ChannelRingSlots      = 64
	ChannelReceiptEntries = 32
	ChannelPinEntries     = 32
	ChannelClaimEntries   = 64
	channelBodyBytes      = 4096
	channelFiles          = 16
	channelRecipients     = 32
	channelTextBytes      = 512
)

// ChannelAuthor is the replicated author of a message.
type ChannelAuthor struct {
	Kind     string `json:"kind"`
	CardID   string `json:"cardId,omitempty"`
	Title    string `json:"title,omitempty"`
	Harness  string `json:"harness,omitempty"`
	Model    string `json:"model,omitempty"`
	DeviceID string `json:"deviceId,omitempty"`
}

// ChannelRecord is one replicated message.
type ChannelRecord struct {
	ID        string        `json:"id"`
	ProjectID string        `json:"projectId"`
	Origin    string        `json:"origin"`
	OriginSeq int64         `json:"originSeq"`
	ThreadID  string        `json:"threadId,omitempty"`
	Kind      string        `json:"kind"`
	Author    ChannelAuthor `json:"author"`
	To        []string      `json:"to,omitempty"`
	Here      bool          `json:"here,omitempty"`
	Wake      bool          `json:"wake,omitempty"`
	Body      string        `json:"body"`
	Files     []string      `json:"files,omitempty"`
	CreatedAt string        `json:"createdAt"`
}

// ChannelDeliveryEntry is one delivery of a message to the receipt's card.
type ChannelDeliveryEntry struct {
	Message string `json:"message"`
	Mode    string `json:"mode"`
	At      string `json:"at"`
}

// ChannelReceiptRecord is a card's latest deliveries, written by its owner.
type ChannelReceiptRecord struct {
	ProjectID  string                 `json:"projectId"`
	Daemon     string                 `json:"daemon"`
	Deliveries []ChannelDeliveryEntry `json:"deliveries"`
}

// ChannelPinEntry is one pin change.
type ChannelPinEntry struct {
	Message string `json:"message"`
	Pinned  bool   `json:"pinned"`
	At      string `json:"at"`
}

// ChannelPinsRecord is one daemon's latest pin changes of a project.
type ChannelPinsRecord struct {
	Pins []ChannelPinEntry `json:"pins"`
}

// ChannelClaimEntry is one live claim in the writer's checkout.
type ChannelClaimEntry struct {
	Path      string `json:"path"`
	CardID    string `json:"cardId"`
	CardTitle string `json:"cardTitle,omitempty"`
	Since     string `json:"since"`
}

// ChannelClaimsRecord is one daemon's live claims in a project's checkout.
type ChannelClaimsRecord struct {
	At     string              `json:"at"`
	Claims []ChannelClaimEntry `json:"claims"`
}

// ChannelNamespaceKind reports whether ns is one of the channel namespaces.
func ChannelNamespaceKind(ns string) bool {
	switch ns {
	case ChannelNamespace, ChannelReceiptNamespace, ChannelPinsNamespace, ChannelClaimsNamespace:
		return true
	}
	return false
}

// ChannelKey is the key of a message slot.
func ChannelKey(projectID, origin string, originSeq int64) string {
	return projectID + "." + origin + "." + strconv.FormatInt(originSeq%ChannelRingSlots, 10)
}

// ChannelScopeKey is the key of a daemon's pins or claims of a project.
func ChannelScopeKey(projectID, daemon string) string { return projectID + "." + daemon }

// SplitChannelKey splits a channel key into its dot-free parts.
func SplitChannelKey(key string) []string { return strings.Split(key, ".") }

// DecodeChannelRecord decodes and validates a message record stored at key.
func DecodeChannelRecord(key string, raw []byte) (ChannelRecord, error) {
	var value ChannelRecord
	if err := strictJSON(raw, &value); err != nil {
		return value, err
	}
	parts := SplitChannelKey(key)
	if len(parts) != 3 || parts[0] != value.ProjectID || parts[1] != value.Origin || parts[2] != strconv.FormatInt(value.OriginSeq%ChannelRingSlots, 10) {
		return value, fault.New(fault.Invalid, "channel message key does not match its project, origin and slot")
	}
	if !channelID(value.ID) || !channelID(value.ProjectID) || !channelID(value.Origin) || value.OriginSeq < 1 {
		return value, fault.New(fault.Invalid, "invalid channel message identity")
	}
	if value.ThreadID != "" && !channelID(value.ThreadID) {
		return value, fault.New(fault.Invalid, "invalid channel thread")
	}
	switch value.Kind {
	case "note", "request", "done", "decision":
	default:
		return value, fault.New(fault.Invalid, "invalid channel message kind")
	}
	switch value.Author.Kind {
	case "agent":
		if !channelID(value.Author.CardID) {
			return value, fault.New(fault.Invalid, "an agent message names its card")
		}
	case "human":
	default:
		return value, fault.New(fault.Invalid, "invalid channel author")
	}
	for _, text := range []string{value.Author.Title, value.Author.Harness, value.Author.Model, value.Author.DeviceID} {
		if !channelText(text) {
			return value, fault.New(fault.Invalid, "invalid channel author field")
		}
	}
	if strings.TrimSpace(value.Body) == "" || len(value.Body) > channelBodyBytes || !utf8.ValidString(value.Body) {
		return value, fault.New(fault.Invalid, "invalid channel message body")
	}
	if len(value.To) > channelRecipients || len(value.Files) > channelFiles {
		return value, fault.New(fault.Invalid, "too many channel recipients or files")
	}
	for _, to := range value.To {
		if !channelID(to) {
			return value, fault.New(fault.Invalid, "invalid channel recipient")
		}
	}
	for _, file := range value.Files {
		if file == "" || !channelText(file) {
			return value, fault.New(fault.Invalid, "invalid channel file")
		}
	}
	if value.Here && value.Author.Kind != "human" {
		return value, fault.New(fault.Invalid, "only people mention @here")
	}
	if !channelTime(value.CreatedAt) {
		return value, fault.New(fault.Invalid, "invalid channel message time")
	}
	return value, nil
}

// DecodeChannelReceipt decodes and validates a card's receipt record.
func DecodeChannelReceipt(key string, raw []byte) (ChannelReceiptRecord, error) {
	var value ChannelReceiptRecord
	if err := strictJSON(raw, &value); err != nil {
		return value, err
	}
	if !channelID(key) || !channelID(value.ProjectID) || !channelID(value.Daemon) || len(value.Deliveries) > ChannelReceiptEntries {
		return value, fault.New(fault.Invalid, "invalid channel receipt")
	}
	for _, delivery := range value.Deliveries {
		switch delivery.Mode {
		case "steered", "digest", "inbox", "woke":
		default:
			return value, fault.New(fault.Invalid, "invalid channel delivery mode")
		}
		if !channelID(delivery.Message) || !channelTime(delivery.At) {
			return value, fault.New(fault.Invalid, "invalid channel delivery")
		}
	}
	return value, nil
}

// DecodeChannelPins decodes and validates a daemon's pins record.
func DecodeChannelPins(key string, raw []byte) (ChannelPinsRecord, error) {
	var value ChannelPinsRecord
	if err := strictJSON(raw, &value); err != nil {
		return value, err
	}
	if len(SplitChannelKey(key)) != 2 || len(value.Pins) > ChannelPinEntries {
		return value, fault.New(fault.Invalid, "invalid channel pins")
	}
	for _, pin := range value.Pins {
		if !channelID(pin.Message) || !channelTime(pin.At) {
			return value, fault.New(fault.Invalid, "invalid channel pin")
		}
	}
	return value, nil
}

// DecodeChannelClaims decodes and validates a daemon's claims record.
func DecodeChannelClaims(key string, raw []byte) (ChannelClaimsRecord, error) {
	var value ChannelClaimsRecord
	if err := strictJSON(raw, &value); err != nil {
		return value, err
	}
	if len(SplitChannelKey(key)) != 2 || len(value.Claims) > ChannelClaimEntries || !channelTime(value.At) {
		return value, fault.New(fault.Invalid, "invalid channel claims")
	}
	for _, claim := range value.Claims {
		if claim.Path == "" || !channelText(claim.Path) || !channelText(claim.CardTitle) || !channelID(claim.CardID) || !channelTime(claim.Since) {
			return value, fault.New(fault.Invalid, "invalid channel claim")
		}
	}
	return value, nil
}

func validateChannel(ns, key string, raw []byte) error {
	var err error
	switch ns {
	case ChannelNamespace:
		_, err = DecodeChannelRecord(key, raw)
	case ChannelReceiptNamespace:
		_, err = DecodeChannelReceipt(key, raw)
	case ChannelPinsNamespace:
		_, err = DecodeChannelPins(key, raw)
	case ChannelClaimsNamespace:
		_, err = DecodeChannelClaims(key, raw)
	}
	return err
}

func strictJSON(raw []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return fault.Invalidf("invalid channel record: %v", err)
	}
	return nil
}

// channelID is a dot-free identifier (cards, projects, daemons, messages).
func channelID(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func channelText(value string) bool {
	return len(value) <= channelTextBytes && utf8.ValidString(value) && !strings.ContainsAny(value, "\x00\n\r")
}

func channelTime(value string) bool {
	_, err := time.Parse(time.RFC3339Nano, value)
	return err == nil
}
