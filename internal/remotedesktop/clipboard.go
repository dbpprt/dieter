package remotedesktop

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"sync"
	"time"
	"unicode/utf8"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4"
	"google.golang.org/protobuf/proto"
)

const ClipboardMaxBytes = 1 << 20
const clipboardChunkBytes = 16 << 10
const clipboardWireBytes = ClipboardMaxBytes + 4096
const clipboardChannelLabel = "dieter-clipboard-v1"

// ClipboardBackend is deliberately independent of capture and host platform.
// Implementations must honor cancellation and never log or persist content.
type ClipboardBackend interface {
	Exchange(context.Context, *dieterv1.RemoteDesktopClipboardRequest) (*dieterv1.RemoteDesktopClipboardResponse, error)
	Close()
}

type clipboardResult struct {
	digest   [32]byte
	response *dieterv1.RemoteDesktopClipboardResponse
}
type sessionClipboard struct {
	mu      sync.Mutex
	backend ClipboardBackend
	channel *webrtc.DataChannel
	results map[string]clipboardResult
	order   []string
	// All wire buffers and native operations have a single owner.
}

func (m *Manager) ExchangeClipboard(ctx context.Context, r *dieterv1.RemoteDesktopClipboardRequest) (*dieterv1.RemoteDesktopClipboardResponse, error) {
	s := m.sessionFor(r.GetSessionId())
	if s == nil {
		return nil, ErrNotFound
	}
	return s.exchangeClipboard(ctx, r)
}

func (s *Session) clipboardAllowed(r *dieterv1.RemoteDesktopClipboardRequest) bool {
	if !s.active() || !s.control || s.manager.controller != s || r.ControlGeneration != s.manager.controlGeneration {
		return false
	}
	if len(r.InputEpoch) != 0 && !bytes.Equal(r.InputEpoch, s.inputEpoch) {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return r.Action == dieterv1.RemoteDesktopClipboardRequest_CONFIGURE || (s.status.ClipboardEnabled && !s.receiverInputExpired)
}

func (s *Session) exchangeClipboard(ctx context.Context, r *dieterv1.RemoteDesktopClipboardRequest) (*dieterv1.RemoteDesktopClipboardResponse, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if len(r.OperationId) == 0 || len(r.OperationId) > 80 || len(r.Text) > ClipboardMaxBytes || !utf8.ValidString(r.Text) || len(r.KnownRevision) > 128 || r.Action < 0 || r.Action > dieterv1.RemoteDesktopClipboardRequest_CUT {
		return nil, errors.New("invalid clipboard request (text limit: 1 MiB)")
	}
	if !s.clipboard.mu.TryLock() {
		return nil, errors.New("clipboard is busy")
	}
	defer s.clipboard.mu.Unlock()
	if r.InputBarrier > 0 {
		waitCtx, cancel := context.WithTimeout(ctx, 750*time.Millisecond)
		defer cancel()
		for s.completedStateSequence.Load() < r.InputBarrier {
			select {
			case <-waitCtx.Done():
				return nil, errors.New("clipboard selection input did not arrive; shortcut was not sent")
			case <-s.ctx.Done():
				return nil, ErrNotFound
			case <-time.After(time.Millisecond):
			}
		}
	}
	s.manager.controlMu.Lock()
	if !s.clipboardAllowed(r) {
		s.manager.controlMu.Unlock()
		return nil, errors.New("clipboard requires the current control grant and enabled sharing")
	}
	if r.Action == dieterv1.RemoteDesktopClipboardRequest_CONFIGURE {
		s.mu.Lock()
		s.status.ClipboardEnabled = r.Enabled
		s.status.ClipboardGeneration++
		state := proto.Clone(s.status).(*dieterv1.RemoteDesktopSessionState)
		s.mu.Unlock()
		s.emit(&dieterv1.RemoteDesktopSignal{Payload: &dieterv1.RemoteDesktopSignal_State{State: state}})
		s.sendHost(&dieterv1.RemoteDesktopHostEvent{Payload: &dieterv1.RemoteDesktopHostEvent_State{State: state}})
		s.manager.controlMu.Unlock()
		return &dieterv1.RemoteDesktopClipboardResponse{OperationId: r.OperationId, Enabled: r.Enabled}, nil
	}
	// Reads may wait on another application's pasteboard provider. They never
	// hold the input ownership lock, and are revalidated before returning data.
	read := r.Action == dieterv1.RemoteDesktopClipboardRequest_READ
	if read {
		s.manager.controlMu.Unlock()
	} else {
		defer s.manager.controlMu.Unlock()
	}
	raw, _ := proto.MarshalOptions{Deterministic: true}.Marshal(r)
	digest := sha256.Sum256(raw)
	if !read {
		if old, ok := s.clipboard.results[r.OperationId]; ok {
			if old.digest != digest {
				return nil, errors.New("clipboard operation ID reused with different content")
			}
			return proto.Clone(old.response).(*dieterv1.RemoteDesktopClipboardResponse), nil
		}
	}
	if s.clipboard.backend == nil {
		if s.manager.options.ClipboardFactory != nil {
			s.clipboard.backend = s.manager.options.ClipboardFactory()
		} else {
			s.clipboard.backend = newNativeClipboard(s.ctx, s.manager.options.Source, s.manager.clipboardName)
		}
	}
	operationCtx, cancel := context.WithTimeout(ctx, 750*time.Millisecond)
	defer cancel()
	value, err := s.clipboard.backend.Exchange(operationCtx, r)
	if err != nil {
		s.clipboard.backend.Close()
		s.clipboard.backend = nil
		value = &dieterv1.RemoteDesktopClipboardResponse{Error: err.Error()}
	}
	if value == nil {
		value = &dieterv1.RemoteDesktopClipboardResponse{Error: "clipboard unavailable"}
	}
	if len(value.Text) > ClipboardMaxBytes {
		value = &dieterv1.RemoteDesktopClipboardResponse{Error: "clipboard text exceeds 1 MiB"}
	}
	value.OperationId = r.OperationId
	value.Enabled = true
	if read {
		s.manager.controlMu.Lock()
		allowed := s.clipboardAllowed(r)
		s.manager.controlMu.Unlock()
		if !allowed {
			return nil, errors.New("clipboard control grant expired")
		}
	} else {
		if s.clipboard.results == nil {
			s.clipboard.results = make(map[string]clipboardResult)
		}
		// Mutations are never automatically replayed by clients. Retain recent
		// results, including unknown outcomes, to make immediate retries safe.
		if len(s.clipboard.order) >= 128 {
			delete(s.clipboard.results, s.clipboard.order[0])
			s.clipboard.order = s.clipboard.order[1:]
		}
		s.clipboard.order = append(s.clipboard.order, r.OperationId)
		cached := proto.Clone(value).(*dieterv1.RemoteDesktopClipboardResponse)
		// Keep the deduplication journal bounded independently of text size.
		// A repeated copy/cut can read current content separately; it must not
		// invoke the shortcut again against a different selection.
		cached.Text = ""
		cached.Changed = false
		cached.HasText = false
		s.clipboard.results[r.OperationId] = clipboardResult{digest, cached}
	}
	return value, nil
}

func (s *Session) installClipboardChannel(channel *webrtc.DataChannel) {
	s.mu.Lock()
	if s.clipboard.channel != nil || !s.control || s.protocol < 3 {
		s.mu.Unlock()
		_ = channel.Close()
		return
	}
	s.clipboard.channel = channel
	s.mu.Unlock()
	queue := make(chan []byte, 4)
	done := make(chan struct{})
	var once sync.Once
	stop := func() { once.Do(func() { close(done) }) }
	channel.OnClose(stop)
	channel.OnMessage(func(message webrtc.DataChannelMessage) {
		if message.IsString || len(message.Data) > clipboardChunkBytes+128 {
			stop()
			_ = channel.Close()
			return
		}
		select {
		case queue <- append([]byte(nil), message.Data...):
		default:
			stop()
			_ = channel.Close()
		}
	})
	go func() {
		defer stop()
		var buffer []byte
		var id string
		timer := time.NewTimer(5 * time.Second)
		defer timer.Stop()
		for {
			select {
			case <-s.ctx.Done():
				return
			case <-done:
				return
			case <-timer.C:
				if len(buffer) != 0 {
					_ = channel.Close()
					return
				}
				timer.Reset(5 * time.Second)
			case raw := <-queue:
				var frame dieterv1.RemoteDesktopClipboardFrame
				if proto.Unmarshal(raw, &frame) != nil || len(frame.OperationId) == 0 || len(frame.OperationId) > 80 || len(frame.Data) > clipboardChunkBytes || (id != "" && id != frame.OperationId) || len(buffer)+len(frame.Data) > clipboardWireBytes {
					_ = channel.Close()
					return
				}
				if id == "" {
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
					timer.Reset(5 * time.Second)
				}
				id = frame.OperationId
				buffer = append(buffer, frame.Data...)
				if !frame.End {
					continue
				}
				var request dieterv1.RemoteDesktopClipboardRequest
				response := &dieterv1.RemoteDesktopClipboardResponse{OperationId: id}
				if proto.Unmarshal(buffer, &request) != nil || request.OperationId != id || request.SessionId != s.id || !bytes.Equal(request.InputEpoch, s.inputEpoch) {
					response.Error = "invalid clipboard request"
				} else {
					value, err := s.exchangeClipboard(s.ctx, &request)
					if err != nil {
						response.Error = err.Error()
					} else {
						response = value
					}
				}
				buffer = nil
				id = ""
				if err := sendClipboardResponse(s.ctx, channel, response); err != nil {
					_ = channel.Close()
					return
				}
			}
		}
	}()
}

func sendClipboardResponse(ctx context.Context, channel *webrtc.DataChannel, response *dieterv1.RemoteDesktopClipboardResponse) error {
	raw, err := proto.Marshal(response)
	if err != nil {
		return err
	}
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for len(raw) > 0 {
		for channel.BufferedAmount() > 32<<10 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-deadline.C:
				return errors.New("clipboard send timed out")
			case <-time.After(5 * time.Millisecond):
			}
		}
		n := min(clipboardChunkBytes, len(raw))
		frame, _ := proto.Marshal(&dieterv1.RemoteDesktopClipboardFrame{OperationId: response.OperationId, Data: raw[:n], End: n == len(raw)})
		if err := channel.Send(frame); err != nil {
			return err
		}
		raw = raw[n:]
	}
	return nil
}

// MemoryClipboard is an isolated backend for synthetic/transport fixtures.
type MemoryClipboard struct {
	mu       sync.Mutex
	text     string
	revision uint64
	Pastes   int
}

func (m *MemoryClipboard) Close() {}
func (m *MemoryClipboard) Exchange(_ context.Context, r *dieterv1.RemoteDesktopClipboardRequest) (*dieterv1.RemoteDesktopClipboardResponse, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	switch r.Action {
	case dieterv1.RemoteDesktopClipboardRequest_WRITE, dieterv1.RemoteDesktopClipboardRequest_PASTE:
		m.text = r.Text
		m.revision++
		if r.Action == dieterv1.RemoteDesktopClipboardRequest_PASTE {
			m.Pastes++
		}
	}
	rev := fmt.Sprint(m.revision)
	v := &dieterv1.RemoteDesktopClipboardResponse{Revision: rev, HasText: m.revision > 0, Changed: r.KnownRevision != rev}
	if (r.Action == dieterv1.RemoteDesktopClipboardRequest_READ && v.Changed) || r.Action == dieterv1.RemoteDesktopClipboardRequest_COPY || r.Action == dieterv1.RemoteDesktopClipboardRequest_CUT {
		v.Text = m.text
	}
	return v, nil
}
