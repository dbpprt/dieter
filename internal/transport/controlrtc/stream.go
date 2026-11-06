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
const WindowFrames = 16

// Stream uses a small credit window in addition to SCTP congestion control.
// Native data-channel APIs cannot pause receive callbacks; ACK only after the
// consumer accepts a frame prevents unbounded buffering at that boundary.
func Stream(dc *webrtc.DataChannel, closePeer func()) net.Conn {
	client, pipe := net.Pipe()
	received := make(chan []byte, WindowFrames)
	credit := make(chan struct{}, WindowFrames)
	for i := 0; i < WindowFrames; i++ {
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
