package remotedesktop

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf16"
	"unicode/utf8"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4"
	"google.golang.org/protobuf/proto"
)

const (
	inputProtocolVersion    uint32 = 2
	hostChannelLabel               = "dieter-session-v2"
	pointerChannelLabel            = "dieter-pointer-v2"
	stateChannelLabel              = "dieter-input-state-v2"
	maxInputMessageBytes           = 4 << 10
	maxNormalizedCoordinate        = 1_000_000
	maxScrollDelta                 = 100_000
	maxMacVirtualKeyCode           = 255
	maxInputModifiers              = 0x3f
)

func (s *Session) installInputChannels() {
	s.pc.OnDataChannel(func(channel *webrtc.DataChannel) {
		if channel.Label() == clipboardChannelLabel {
			s.installClipboardChannel(channel)
			return
		}
		if channel.Label() == hostChannelLabel {
			s.mu.Lock()
			duplicate := s.hostChannel != nil
			if !duplicate {
				s.hostChannel = channel
			}
			s.mu.Unlock()
			if duplicate {
				_ = channel.Close()
				return
			}
			channel.OnMessage(func(message webrtc.DataChannelMessage) {
				if !message.IsString && len(message.Data) <= maxInputMessageBytes {
					s.receiveFeedback(message.Data)
				}
			})
			channel.OnOpen(func() {
				if state, err := s.manager.SessionState(s.id); err == nil {
					s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_State{State: state}})
				}
				s.mu.Lock()
				cursor := s.cursor
				s.mu.Unlock()
				if cursor != nil {
					s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_Cursor{Cursor: cursor}})
				}
			})
			channel.OnClose(func() { s.inputStopped.Store(true); go s.close("remote desktop data channel closed") })
			return
		}
		if !s.control || (channel.Label() != pointerChannelLabel && channel.Label() != stateChannelLabel) {
			_ = channel.Close()
			return
		}
		s.mu.Lock()
		if s.inputChannels == nil {
			s.inputChannels = make(map[string]bool)
		}
		duplicate := s.inputChannels[channel.Label()]
		s.inputChannels[channel.Label()] = true
		s.mu.Unlock()
		if duplicate {
			_ = channel.Close()
			return
		}
		channel.OnMessage(func(message webrtc.DataChannelMessage) {
			if !message.IsString && len(message.Data) <= maxInputMessageBytes {
				s.handleInput(channel.Label(), message.Data)
			}
		})
		channel.OnClose(func() { s.inputStopped.Store(true); go s.close("remote desktop data channel closed") })
		channel.OnError(func(err error) {
			s.manager.options.Logger.Warn("remote desktop input channel failed", "channel", channel.Label(), "error", err)
			s.inputStopped.Store(true)
			go s.close("remote desktop input channel failed")
		})
	})
}

func (s *Session) handleInput(label string, raw []byte) {
	if s.inputStopped.Load() {
		return
	}
	var input dieterv1.RemoteDesktopInput
	if err := proto.Unmarshal(raw, &input); err != nil || (input.GetProtocolVersion() != s.protocol && s.protocol != 0) || validateInput(&input, s.inputEpoch) != nil {
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
		s.inputStopped.Store(true)
		go s.close("remote input queue overflow")
	}
}

func (s *Session) runInput() {
	sink, ok := s.source.(InputSink)
	if !ok {
		return
	}
	var pending *dieterv1.RemoteDesktopInput
	for {
		select {
		case <-s.ctx.Done():
			return
		default:
		}
		select {
		case input := <-s.stateInput:
			s.deliverInput(sink, input)
			s.lastStateApplied = input.GetSequence()
			s.completedStateSequence.Store(input.GetSequence())
		default:
			if pending != nil && pending.GetStateBarrier() <= s.lastStateApplied {
				if pending.GetEventOrdinal() == 0 || pending.GetEventOrdinal() > s.lastOrdinal {
					s.deliverInput(sink, pending)
				}
				pending = nil
			}
			select {
			case <-s.ctx.Done():
				return
			case input := <-s.stateInput:
				s.deliverInput(sink, input)
				s.lastStateApplied = input.GetSequence()
				s.completedStateSequence.Store(input.GetSequence())
			case input := <-s.pointerInput:
				pending = input
			}
		}
	}
}

func (s *Session) deliverInput(sink InputSink, input *dieterv1.RemoteDesktopInput) {
	if s.manager != nil {
		s.manager.controlMu.Lock()
		defer s.manager.controlMu.Unlock()
		if s.manager.controller != s || (s.protocol >= 3 && input.GetControlGeneration() != s.manager.controlGeneration) {
			return
		}
	}
	s.inputMu.Lock()
	defer s.inputMu.Unlock()
	if s.inputStopped.Load() {
		return
	}
	s.mu.Lock()
	generation := s.status.GetDisplayGeneration()
	modeChanging := s.displayModeFence != 0 && s.displayModeFence == generation
	expired := s.receiverInputExpired
	floor := s.expiredStateSequence
	if input.GetPointerMove() != nil {
		floor = s.expiredPointerSequence
	}
	s.mu.Unlock()
	if modeChanging && input.GetReleaseAll() == nil {
		return
	}
	if (expired || (floor > 0 && input.Sequence <= floor)) && input.GetReleaseAll() == nil {
		return
	}
	if input.GetReleaseAll() == nil && generation != 0 && input.GetDisplayGeneration() != 0 && generation != input.GetDisplayGeneration() {
		return
	}
	if err := sink.SendInput(s.ctx, input); err != nil && s.ctx.Err() == nil {
		if strings.Contains(err.Error(), "stale input display") {
			return
		}
		s.manager.options.Logger.Warn("remote input delivery failed", "kind", inputKind(input), "error", err)
		s.inputStopped.Store(true)
		go s.close("remote input delivery failed")
		return
	}
	s.lastOrdinal = max(s.lastOrdinal, input.GetEventOrdinal())
	s.mu.Lock()
	if s.status != nil {
		s.status.LastInputOrdinal = s.lastOrdinal
	}
	s.mu.Unlock()
	s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_InputAck{InputAck: s.lastOrdinal}})
}

func validateInput(input *dieterv1.RemoteDesktopInput, epoch []byte) error {
	if input == nil || (input.GetProtocolVersion() != 2 && input.GetProtocolVersion() != 3) || !bytes.Equal(input.GetInputEpoch(), epoch) || input.GetSequence() == 0 {
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
		if !finiteBound(value.Scroll.GetPreciseDeltaX(), 100000) || !finiteBound(value.Scroll.GetPreciseDeltaY(), 100000) || value.Scroll.GetPhase() > 255 || value.Scroll.GetMomentumPhase() > 255 {
			return errors.New("invalid precise scroll")
		}
		if abs64(int64(value.Scroll.GetDeltaX())) > maxScrollDelta || abs64(int64(value.Scroll.GetDeltaY())) > maxScrollDelta || value.Scroll.GetModifiers() > maxInputModifiers {
			return errors.New("invalid remote desktop scroll event")
		}
	case *dieterv1.RemoteDesktopInput_Key:
		if value.Key.GetKeyCode() > maxMacVirtualKeyCode || value.Key.GetPhysicalKey() > 255 || value.Key.GetModifiers() > maxInputModifiers {
			return errors.New("invalid remote desktop key event")
		}
	case *dieterv1.RemoteDesktopInput_Text:
		if !utf8.ValidString(value.Text.GetText()) || len(value.Text.GetText()) == 0 || len(value.Text.GetText()) > 2048 || len(utf16.Encode([]rune(value.Text.GetText()))) > 1024 {
			return errors.New("invalid committed text")
		}
	case *dieterv1.RemoteDesktopInput_ReleaseAll:
	default:
		return errors.New("remote desktop input payload is missing")
	}
	return nil
}

func (s *Session) releaseInput() {
	if s.manager != nil {
		s.manager.controlMu.Lock()
		defer s.manager.controlMu.Unlock()
		if s.manager.controller != s {
			return
		}
	}
	if !s.control {
		return
	}
	if sink, ok := s.source.(InputSink); ok {
		s.inputMu.Lock()
		ctx, cancel := context.WithTimeout(context.Background(), nativeCommandTimeout)
		sink.ReleaseInput(ctx)
		cancel()
		s.inputMu.Unlock()
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

func finiteBound(v, max float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && math.Abs(v) <= max
}
func (s *Session) receiveFeedback(raw []byte) {
	var value dieterv1.RemoteDesktopReceiverFeedback
	if proto.Unmarshal(raw, &value) != nil || value.ProtocolVersion != inputProtocolVersion || !bytes.Equal(value.InputEpoch, s.inputEpoch) || value.Sequence == 0 {
		return
	}
	validStatistics := finiteBound(value.FramesPerSecond, 240) && finiteBound(value.DecodeMs, 10000) && finiteBound(value.JitterMs, 10000) && finiteBound(value.RttMs, 60000) && finiteBound(value.LossFraction, 1) && finiteBound(value.JitterBufferMs, 10000) && finiteBound(value.RenderMs, 10000) && value.JitterBufferMs >= 0 && value.RenderMs >= 0
	previous := s.feedbackSequence.Load()
	if value.Sequence <= previous || !s.feedbackSequence.CompareAndSwap(previous, value.Sequence) {
		return
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	wasActive := s.receiver.GetInputActive()
	s.lastFeedback = time.Now()
	// The authenticated signaling subscription supplies authorization; the
	// epoch-bound, increasing WebRTC heartbeat supplies receiver liveness.
	// A delayed unary renewal must not kill a healthy peer. Do not renew after
	// signaling detaches: its existing grace still bounds expiry/revocation.
	if s.manager != nil && len(s.subscribers) > 0 {
		s.leaseExpiresAt = s.manager.options.Now().UTC().Add(s.manager.options.SessionLease)
	}
	if s.receiverInputExpired {
		// Discard input queued before/during the interruption, even if its
		// worker runs only after the new heartbeat has resumed control.
		s.expiredStateSequence = s.stateInputSequence.Load()
		s.expiredPointerSequence = s.pointerInputSequence.Load()
	}
	s.receiverInputExpired = false
	logRejectedStatistics := !validStatistics && !s.receiverStatsRejected
	s.receiverStatsRejected = !validStatistics
	if validStatistics {
		s.receiver = &value
		if value.MeasurementSequence == 0 || value.MeasurementSequence > s.receiverMeasurement {
			s.receiverMeasurement = value.MeasurementSequence
			s.receiverMeasuredAt = s.lastFeedback.Add(-time.Duration(value.MeasurementAgeMs) * time.Millisecond)
		}
		if s.status != nil {
			s.status.ReceiverFps = value.FramesPerSecond
			s.status.RttMs = value.RttMs
			s.status.JitterBufferMs = value.JitterBufferMs
			s.status.RenderMs = value.RenderMs
		}
	} else {
		// The epoch and strictly increasing heartbeat sequence already prove
		// receiver liveness. A bad getStats sample must not turn that evidence
		// into a three-second input disconnect. Preserve the last valid sample
		// and its age while accepting only the fresh control-activity evidence.
		heartbeat := &dieterv1.RemoteDesktopReceiverFeedback{}
		if s.receiver != nil {
			heartbeat = proto.Clone(s.receiver).(*dieterv1.RemoteDesktopReceiverFeedback)
		}
		heartbeat.ProtocolVersion, heartbeat.InputEpoch = value.ProtocolVersion, value.InputEpoch
		heartbeat.Sequence, heartbeat.InputActive = value.Sequence, value.InputActive
		s.receiver = heartbeat
	}
	s.mu.Unlock()
	if logRejectedStatistics && s.manager != nil && s.manager.options.Logger != nil {
		s.manager.options.Logger.Warn("remote desktop ignored invalid receiver statistics; heartbeat accepted", "session", s.id, "measurementSequence", value.MeasurementSequence, "measurementAgeMs", value.MeasurementAgeMs)
	}
	if len(value.DecodedReferences) <= 8 && s.referenceQueue != nil {
		for _, ack := range value.DecodedReferences {
			if m, ok := s.references.acknowledge(time.Now(), ack); ok {
				select {
				case s.referenceQueue <- m:
				default:
				}
			}
		}
	}
	if wasActive && !value.InputActive {
		s.releaseInput()
	}
}

// Input safety and video liveness are separate. A short receiver scheduling or
// network gap releases held keys once and suppresses input until a fresh signed
// heartbeat; peer/signaling grace and the session lease still bound video life.
func (s *Session) expireReceiverInput(now time.Time) {
	s.mu.Lock()
	expired := s.control && !s.closed && !s.receiverInputExpired && !s.lastFeedback.IsZero() && now.Sub(s.lastFeedback) > 3*time.Second
	if expired {
		s.receiverInputExpired = true
	}
	s.mu.Unlock()
	if !expired {
		return
	}
	s.releaseInput()
	if s.manager != nil && s.manager.options.Logger != nil {
		s.manager.options.Logger.Info("remote desktop input paused; awaiting receiver heartbeat", "session", s.id)
	}
}

func (s *Session) sendHost(value *dieterv1.RemoteDesktopHostEvent) {
	s.hostSendMu.Lock()
	defer s.hostSendMu.Unlock()
	s.mu.Lock()
	channel, closed := s.hostChannel, s.closed
	s.mu.Unlock()
	if closed || channel == nil || channel.ReadyState() != webrtc.DataChannelStateOpen || channel.BufferedAmount() > 384<<10 {
		return
	}
	cursor := value.GetCursor()
	if cursor != nil && cursor.ShapeId == s.lastCursorShapeSent {
		value = proto.Clone(value).(*dieterv1.RemoteDesktopHostEvent)
		value.GetCursor().Png = nil
	}
	raw, err := proto.Marshal(value)
	if err != nil || len(raw) > 350000 {
		return
	}
	if channel.Send(raw) == nil && cursor != nil && len(cursor.Png) > 0 {
		s.lastCursorShapeSent = cursor.ShapeId
	}
}
