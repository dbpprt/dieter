package remotedesktop

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sync/atomic"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4"
	"google.golang.org/protobuf/proto"
)

const (
	inputProtocolVersion    uint32 = 1
	pointerChannelLabel            = "dieter-pointer-v1"
	stateChannelLabel              = "dieter-input-state-v1"
	maxInputMessageBytes           = 4 << 10
	maxNormalizedCoordinate        = 1_000_000
	maxScrollDelta                 = 100_000
	maxMacVirtualKeyCode           = 255
	maxInputModifiers              = 0x3f
)

func (s *Session) installInputChannels() {
	s.pc.OnDataChannel(func(channel *webrtc.DataChannel) {
		if !s.control || (channel.Label() != pointerChannelLabel && channel.Label() != stateChannelLabel) {
			_ = channel.Close()
			return
		}
		channel.OnMessage(func(message webrtc.DataChannelMessage) {
			if !message.IsString && len(message.Data) <= maxInputMessageBytes {
				s.handleInput(channel.Label(), message.Data)
			}
		})
		channel.OnClose(func() { s.releaseInput() })
		channel.OnError(func(err error) {
			s.manager.options.Logger.Warn("remote desktop input channel failed", "channel", channel.Label(), "error", err)
			s.releaseInput()
		})
	})
}

func (s *Session) handleInput(label string, raw []byte) {
	var input dieterv1.RemoteDesktopInput
	if err := proto.Unmarshal(raw, &input); err != nil || validateInput(&input, s.inputEpoch) != nil {
		return
	}
	var sequence *atomic.Uint64
	if label == pointerChannelLabel {
		if input.GetPointerMove() == nil {
			return
		}
		sequence = &s.pointerInputSequence
	} else {
		if input.GetPointerMove() != nil {
			return
		}
		sequence = &s.stateInputSequence
	}
	for {
		previous := sequence.Load()
		if input.GetSequence() <= previous || !sequence.CompareAndSwap(previous, input.GetSequence()) {
			if input.GetSequence() <= previous {
				return
			}
			continue
		}
		break
	}
	copy := proto.Clone(&input).(*dieterv1.RemoteDesktopInput)
	if label == pointerChannelLabel {
		select {
		case s.pointerInput <- copy:
		default:
			select {
			case <-s.pointerInput:
			default:
			}
			select {
			case s.pointerInput <- copy:
			default:
			}
		}
		return
	}
	select {
	case s.stateInput <- copy:
	default:
		s.releaseInput()
		go s.close("remote input queue overflow")
	}
}

func (s *Session) runInput() {
	sink, ok := s.source.(InputSink)
	if !ok {
		return
	}
	for {
		select {
		case <-s.ctx.Done():
			return
		case input := <-s.stateInput:
			s.deliverInput(sink, input)
		default:
			select {
			case <-s.ctx.Done():
				return
			case input := <-s.stateInput:
				s.deliverInput(sink, input)
			case input := <-s.pointerInput:
				s.deliverInput(sink, input)
			}
		}
	}
}

func (s *Session) deliverInput(sink InputSink, input *dieterv1.RemoteDesktopInput) {
	if err := sink.SendInput(s.ctx, input); err != nil && s.ctx.Err() == nil {
		s.manager.options.Logger.Debug("remote desktop input was not delivered", "kind", inputKind(input), "error", err)
	}
}

func validateInput(input *dieterv1.RemoteDesktopInput, epoch []byte) error {
	if input == nil || input.GetProtocolVersion() != inputProtocolVersion || !bytes.Equal(input.GetInputEpoch(), epoch) || input.GetSequence() == 0 {
		return errors.New("invalid remote desktop input envelope")
	}
	coordinate := func(x, y int32) error {
		if x < 0 || x > maxNormalizedCoordinate || y < 0 || y > maxNormalizedCoordinate {
			return errors.New("remote desktop pointer coordinate is out of range")
		}
		return nil
	}
	switch value := input.GetPayload().(type) {
	case *dieterv1.RemoteDesktopInput_PointerMove:
		return coordinate(value.PointerMove.GetNormalizedX(), value.PointerMove.GetNormalizedY())
	case *dieterv1.RemoteDesktopInput_PointerButton:
		button := value.PointerButton.GetButton()
		if button < dieterv1.RemoteDesktopPointerButton_BUTTON_LEFT || button > dieterv1.RemoteDesktopPointerButton_BUTTON_FORWARD || value.PointerButton.GetClickCount() < 0 || value.PointerButton.GetClickCount() > 3 || value.PointerButton.GetModifiers() > maxInputModifiers {
			return errors.New("invalid remote desktop pointer button")
		}
		return coordinate(value.PointerButton.GetNormalizedX(), value.PointerButton.GetNormalizedY())
	case *dieterv1.RemoteDesktopInput_Scroll:
		if abs64(int64(value.Scroll.GetDeltaX())) > maxScrollDelta || abs64(int64(value.Scroll.GetDeltaY())) > maxScrollDelta || value.Scroll.GetModifiers() > maxInputModifiers {
			return errors.New("invalid remote desktop scroll event")
		}
	case *dieterv1.RemoteDesktopInput_Key:
		if value.Key.GetKeyCode() > maxMacVirtualKeyCode || value.Key.GetModifiers() > maxInputModifiers {
			return errors.New("invalid remote desktop key event")
		}
	case *dieterv1.RemoteDesktopInput_ReleaseAll:
	default:
		return errors.New("remote desktop input payload is missing")
	}
	return nil
}

func (s *Session) releaseInput() {
	if !s.control {
		return
	}
	if sink, ok := s.source.(InputSink); ok {
		sink.ReleaseInput(context.Background())
	}
}

func inputKind(input *dieterv1.RemoteDesktopInput) string {
	switch input.GetPayload().(type) {
	case *dieterv1.RemoteDesktopInput_PointerMove:
		return "pointer_move"
	case *dieterv1.RemoteDesktopInput_PointerButton:
		return "pointer_button"
	case *dieterv1.RemoteDesktopInput_Scroll:
		return "scroll"
	case *dieterv1.RemoteDesktopInput_Key:
		return "key"
	case *dieterv1.RemoteDesktopInput_ReleaseAll:
		return "release_all"
	default:
		return fmt.Sprintf("unknown_%T", input.GetPayload())
	}
}

func abs64(value int64) int64 {
	if value < 0 {
		return -value
	}
	return value
}
