package relay

import "errors"

type RawMessage struct{ Data []byte }

type RawCodec struct{}

func (RawCodec) Name() string { return "proto" }

func (RawCodec) Marshal(value any) ([]byte, error) {
	switch message := value.(type) {
	case *RawMessage:
		return message.Data, nil
	case RawMessage:
		return message.Data, nil
	default:
		return nil, errors.New("raw RPC received a non-frame message")
	}
}

func (RawCodec) Unmarshal(data []byte, value any) error {
	message, ok := value.(*RawMessage)
	if !ok {
		return errors.New("raw RPC received a non-frame destination")
	}
	message.Data = append(message.Data[:0], data...)
	return nil
}
