// Package controlrtc carries an authenticated TLS/gRPC stream over WebRTC.
// It never decodes RPCs or bypasses the direct server's authentication.
package controlrtc

import (
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"

	"github.com/pion/webrtc/v4"
)

const Label = "dieter-control-tls-v1"
const ChunkSize = 16383

// WindowFrames is the protocol's base credit window. Every peer accepts this
// many unacknowledged data frames, also one that predates window negotiation
// (the native clients) and so advertises no window.
const WindowFrames = 16

// MaxWindowFrames is the window this implementation advertises and buffers:
// 8 MiB in flight. The base window allows only 256 KiB per round trip, about
// 2.5 MiB/s over a 100 ms TURN path; this window fills most WAN links.
const MaxWindowFrames = 512

// SendWindow is the credit window toward a peer that advertised advertised
// receive frames; zero means a peer without window negotiation.
func SendWindow(advertised uint32) int {
	return int(min(max(advertised, WindowFrames), MaxWindowFrames))
}

// sctpReceiveBuffer caps SCTP's advertised receive window. It must exceed a
// full credit window, or SCTP flow control throttles below it. The stream
// drains SCTP into its bounded queue at once, so the cap is rarely occupied.
const sctpReceiveBuffer = 2 * MaxWindowFrames * (ChunkSize + 1)

// api creates the data-only peer connections of both endpoints.
var api = func() *webrtc.API {
	var settings webrtc.SettingEngine
	settings.SetSCTPMaxReceiveBufferSize(sctpReceiveBuffer)
	return webrtc.NewAPI(webrtc.WithSettingEngine(settings))
}()

// Stream uses a credit window in addition to SCTP congestion control.
// Native data-channel APIs cannot pause receive callbacks; ACK only after the
// consumer accepts a frame prevents unbounded buffering at that boundary.
// receive is the window this side advertised, send the peer's (SendWindow).
func Stream(dc *webrtc.DataChannel, receive, send int, closePeer func()) net.Conn {
	client, pipe := net.Pipe()
	received := make(chan []byte, receive)
	credit := make(chan struct{}, send)
	for i := 0; i < send; i++ {
		credit <- struct{}{}
	}
	done := make(chan struct{})
	var once sync.Once
	var outstanding atomic.Int32
	closeAll := func() {
		once.Do(func() {
			close(done)
			_ = pipe.Close()
			_ = client.Close()
			if closePeer != nil {
				go closePeer()
			}
		})
	}
	dc.OnClose(closeAll)
	dc.OnError(func(error) { closeAll() })
	dc.OnMessage(func(message webrtc.DataChannelMessage) {
		data := message.Data
		if message.IsString || len(data) == 0 || len(data) > ChunkSize+1 {
			closeAll()
			return
		}
		switch data[0] {
		case 0:
			if len(data) == 1 {
				closeAll()
				return
			}
			copyData := append([]byte(nil), data[1:]...)
			select {
			case received <- copyData:
			case <-done:
			default:
				closeAll()
			}
		case 1:
			if len(data) != 1 || outstanding.Add(-1) < 0 {
				closeAll()
				return
			}
			select {
			case credit <- struct{}{}:
			case <-done:
			default:
				closeAll()
			}
		default:
			closeAll()
		}
	})
	dc.OnOpen(func() {
		go func() {
			defer closeAll()
			frame := make([]byte, ChunkSize+1)
			for {
				select {
				case <-done:
					return
				case <-credit:
				}
				n, err := pipe.Read(frame[1:])
				if err != nil {
					return
				}
				outstanding.Add(1)
				if err = dc.Send(frame[:n+1]); err != nil {
					return
				}
			}
		}()
		go func() {
			defer closeAll()
			for {
				select {
				case <-done:
					return
				case data := <-received:
					if _, err := pipe.Write(data); err != nil {
						return
					}
					if err := dc.Send([]byte{1}); err != nil {
						return
					}
				}
			}
		}()
	})
	return &streamConn{Conn: client, close: closeAll}
}

type streamConn struct {
	net.Conn
	close func()
}

func (s *streamConn) Close() error { s.close(); return nil }

// CopyStream closes both ends when either direction ends. RPC cancellation
// remains an HTTP/2 stream operation, independent of this transport lifetime.
func CopyStream(a, b net.Conn) {
	defer a.Close()
	defer b.Close()
	finished := make(chan struct{}, 1)
	go func() { _, _ = io.Copy(a, b); finished <- struct{}{} }()
	go func() { _, _ = io.Copy(b, a); finished <- struct{}{} }()
	<-finished
}

var ErrUnavailable = errors.New("WebRTC control transport is unavailable")
