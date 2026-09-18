package main

import (
	"encoding/binary"
	"sync"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

func TestFECProofWithholdsOriginalUntilPacedParityAndBlocksRetransmission(t *testing.T) {
	loss := newMediaLoss()
	loss.configure("fec-proof")
	stream := &lossInterceptor{loss: loss}
	defer stream.Close()
	var mu sync.Mutex
	var delivered []uint32
	writer := stream.BindLocalStream(&interceptor.StreamInfo{SSRC: 123, SSRCForwardErrorCorrection: 456},
		interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
			mu.Lock()
			delivered = append(delivered, h.SSRC)
			mu.Unlock()
			return h.MarshalSize() + len(p), nil
		}))
	media := rtp.Header{Version: 2, SSRC: 123, SequenceNumber: 42, Timestamp: 90000, Marker: true}
	if _, err := writer.Write(&media, []byte{1, 2, 3}, nil); err != nil {
		t.Fatal(err)
	}
	// A repair paced at a reduced bitrate routinely needs more than the old
	// four-millisecond hold. No receiver/network clock is fabricated here.
	time.Sleep(20 * time.Millisecond)
	parity := make([]byte, 20)
	binary.BigEndian.PutUint16(parity[16:18], media.SequenceNumber)
	binary.BigEndian.PutUint16(parity[18:20], 1<<14)
	if _, err := writer.Write(&rtp.Header{Version: 2, SSRC: 456}, parity, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(&media, []byte{1, 2, 3}, nil); err != nil {
		t.Fatal(err)
	}
	state := loss.snapshot()
	if state["repairedTimestamp"] != uint32(90000) || state["dropped"] != uint64(2) {
		t.Fatalf("proof did not drop original and retransmission: %v", state)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(delivered) != 1 || delivered[0] != 456 {
		t.Fatalf("only parity may reach the receiver: %v", delivered)
	}
}
