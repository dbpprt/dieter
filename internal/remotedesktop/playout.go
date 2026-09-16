package remotedesktop

import (
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

const playoutDelayURI = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"

type immediatePlayoutFactory struct{}

func (immediatePlayoutFactory) NewInterceptor(string) (interceptor.Interceptor, error) {
	return &immediatePlayout{}, nil
}

type immediatePlayout struct{ interceptor.NoOp }

func (*immediatePlayout) BindLocalStream(info *interceptor.StreamInfo, writer interceptor.RTPWriter) interceptor.RTPWriter {
	for _, extension := range info.RTPHeaderExtensions {
		if extension.URI != playoutDelayURI || extension.ID < 1 || extension.ID > 255 {
			continue
		}
		id := uint8(extension.ID)
		return interceptor.RTPWriterFunc(func(h *rtp.Header, payload []byte, attributes interceptor.Attributes) (int, error) {
			// Both 12-bit values are zero: render as soon as decoding permits.
			// Repeat on every packet so loss/reconnect needs no separate ACK state.
			if err := h.SetExtension(id, []byte{0, 0, 0}); err != nil {
				return 0, err
			}
			return writer.Write(h, payload, attributes)
		})
	}
	return writer // Older peers retain their normal playout policy.
}
