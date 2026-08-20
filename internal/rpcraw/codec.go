package rpcraw

import "errors"

type Message struct{ Data []byte }

type Codec struct{}

func (Codec) Name() string { return "proto" }

func (Codec) Marshal(value any) ([]byte, error) {
	switch message := value.(type) {
	case *Message:
		return message.Data, nil
	case Message:
		return message.Data, nil
	default:
		return nil, errors.New("raw RPC received a non-frame message")
	}
}

func (Codec) Unmarshal(data []byte, value any) error {
	message, ok := value.(*Message)
	if !ok {
		return errors.New("raw RPC received a non-frame destination")
	}
	message.Data = append(message.Data[:0], data...)
	return nil
}
