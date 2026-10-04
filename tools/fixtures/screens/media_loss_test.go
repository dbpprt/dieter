package main

import (
	"encoding/binary"
	"sync"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/flexfec"
	"github.com/pion/rtp"
)

func TestFECProofSelectsTailOfRealFlexFECGroupAcrossSequenceWrap(t *testing.T) {
	loss := newMediaLoss()
	loss.configure("fec-proof")
	stream := &lossInterceptor{loss: loss}
	defer stream.Close()
	var delivered []rtp.Packet
	writer := stream.BindLocalStream(&interceptor.StreamInfo{SSRC: 123, SSRCForwardErrorCorrection: 456},
		interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
			delivered = append(delivered, *(&rtp.Packet{Header: *h, Payload: p}).Clone())
			return h.MarshalSize() + len(p), nil
		}))
	var group []rtp.Packet
	for i := 0; i < 6; i++ {
		packet := rtp.Packet{Header: rtp.Header{Version: 2, SSRC: 123, SequenceNumber: uint16(65532 + i), Timestamp: 90000, PayloadType: 96}, Payload: []byte{byte(i), 1, 2}}
		if err := packet.SetExtension(3, []byte{byte(i), 0}); err != nil {
			t.Fatal(err)
		}
		group = append(group, packet)
		if _, err := writer.Write(&packet.Header, packet.Payload, nil); err != nil {
			t.Fatal(err)
		}
	}
	repair := flexfec.NewFlexEncoder03(118, 456).EncodeFec(group, 1)
	if len(repair) != 1 {
		t.Fatal("real encoder did not protect the group")
	}
	if _, err := writer.Write(&repair[0].Header, repair[0].Payload, nil); err != nil {
		t.Fatal(err)
	}
	tail := group[len(group)-1]
	if _, err := writer.Write(&tail.Header, tail.Payload, nil); err != nil {
		t.Fatal(err)
	}
	if state := loss.snapshot(); state["mode"] != "proof-complete" || state["repairedTimestamp"] != tail.Timestamp || state["dropped"] != uint64(2) {
		t.Fatalf("real parity did not discard exactly the original and retry: %v", state)
	}
	if len(delivered) != len(group) || delivered[len(delivered)-1].SSRC != 456 {
		t.Fatalf("expected all preceding media plus parity: %v", delivered)
	}
	for i := range group[:len(group)-1] {
		if delivered[i].SequenceNumber != group[i].SequenceNumber {
			t.Fatal("fixture delayed or lost earlier media")
		}
	}
}

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

func TestFECProofSelectsLatestGroupPacketWithoutDelayingEarlierMedia(t *testing.T) {
	loss := newMediaLoss()
	loss.configure("fec-proof")
	stream := &lossInterceptor{loss: loss}
	defer stream.Close()
	var mu sync.Mutex
	var delivered []rtp.Header
	writer := stream.BindLocalStream(&interceptor.StreamInfo{SSRC: 123, SSRCForwardErrorCorrection: 456},
		interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
			mu.Lock()
			delivered = append(delivered, h.Clone())
			mu.Unlock()
			return h.MarshalSize() + len(p), nil
		}))
	write := func(h rtp.Header, p []byte) {
		t.Helper()
		if _, err := writer.Write(&h, p, nil); err != nil {
			t.Fatal(err)
		}
	}
	original := rtp.Header{Version: 2, SSRC: 123, SequenceNumber: 42, Timestamp: 90000, Marker: true}
	write(original, []byte{1})
	write(rtp.Header{Version: 2, SSRC: 123, SequenceNumber: 43, Timestamp: 93000, Marker: true}, []byte{2})
	parity := make([]byte, 20)
	binary.BigEndian.PutUint16(parity[16:18], 40)
	binary.BigEndian.PutUint16(parity[18:20], 1<<14) // Older unrelated parity.
	write(rtp.Header{Version: 2, SSRC: 456}, parity)
	latest := rtp.Header{Version: 2, SSRC: 123, SequenceNumber: 43, Timestamp: 93000, Marker: true}
	write(latest, []byte{2}) // Its retransmission must stay withheld.
	binary.BigEndian.PutUint16(parity[18:20], 1<<11)
	write(rtp.Header{Version: 2, SSRC: 456}, parity)
	write(latest, []byte{2})
	state := loss.snapshot()
	if state["repairedTimestamp"] != uint32(93000) || state["dropped"] != uint64(3) {
		t.Fatalf("proof did not select the protected tail: %v", state)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(delivered) != 3 {
		t.Fatalf("only intervening media and parity may be delivered: %v", delivered)
	}
	for _, h := range delivered {
		if h.SSRC == latest.SSRC && h.SequenceNumber == latest.SequenceNumber {
			t.Fatal("protected original or retransmission escaped before proof")
		}
	}
	if delivered[0].SequenceNumber != original.SequenceNumber {
		t.Fatal("earlier media must be released before parity without a timer delay")
	}
}

func TestFECProofAdvancesPastUnprotectedCandidateAndSelectsNonMarker(t *testing.T) {
	loss := newMediaLoss()
	loss.configure("fec-proof")
	stream := &lossInterceptor{loss: loss}
	defer stream.Close()
	var delivered []rtp.Header
	writer := stream.BindLocalStream(&interceptor.StreamInfo{SSRC: 123, SSRCForwardErrorCorrection: 456},
		interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
			delivered = append(delivered, h.Clone())
			return h.MarshalSize() + len(p), nil
		}))
	write := func(h rtp.Header, p []byte) {
		t.Helper()
		if _, err := writer.Write(&h, p, nil); err != nil {
			t.Fatal(err)
		}
	}
	write(rtp.Header{SSRC: 123, SequenceNumber: 42, Timestamp: 90000, Marker: true}, []byte{1})
	parity := make([]byte, 20)
	binary.BigEndian.PutUint16(parity[16:18], 43)
	binary.BigEndian.PutUint16(parity[18:20], 1<<14)
	write(rtp.Header{SSRC: 456}, parity)
	// A frame's last fragment can be outside its protected six-packet
	// group. Its first non-marker fragment must also be eligible.
	write(rtp.Header{SSRC: 123, SequenceNumber: 44, Timestamp: 93000}, []byte{2})
	binary.BigEndian.PutUint16(parity[16:18], 44)
	write(rtp.Header{SSRC: 456}, parity)
	if state := loss.snapshot(); state["repairedTimestamp"] != uint32(93000) || state["dropped"] != uint64(1) {
		t.Fatalf("did not advance to a protected fragment: %v", state)
	}
	if len(delivered) != 3 || delivered[0].SequenceNumber != 42 || delivered[1].SSRC != 456 || delivered[2].SSRC != 456 {
		t.Fatalf("unprotected original and both repairs must pass: %v", delivered)
	}
}

func TestFECProofDoesNotHoldRetransmissionsFromPreviousFaultMode(t *testing.T) {
	loss := newMediaLoss()
	stream := &lossInterceptor{loss: loss}
	defer stream.Close()
	var delivered []uint16
	writer := stream.BindLocalStream(&interceptor.StreamInfo{SSRC: 123, SSRCForwardErrorCorrection: 456},
		interceptor.RTPWriterFunc(func(h *rtp.Header, p []byte, _ interceptor.Attributes) (int, error) {
			delivered = append(delivered, h.SequenceNumber)
			return h.MarshalSize() + len(p), nil
		}))
	for _, seq := range []uint16{42, 43} {
		_, _ = writer.Write(&rtp.Header{SSRC: 123, SequenceNumber: seq, Marker: true}, []byte{1}, nil)
	}
	loss.configure("fec-proof")
	_, _ = writer.Write(&rtp.Header{SSRC: 123, SequenceNumber: 42, Marker: true}, []byte{1}, nil)
	_, _ = writer.Write(&rtp.Header{SSRC: 123, SequenceNumber: 44, Timestamp: 93000}, []byte{2}, nil)
	parity := make([]byte, 20)
	binary.BigEndian.PutUint16(parity[16:18], 44)
	binary.BigEndian.PutUint16(parity[18:20], 1<<14)
	_, _ = writer.Write(&rtp.Header{SSRC: 456, SequenceNumber: 100}, parity, nil)
	if state := loss.snapshot(); state["repairedTimestamp"] != uint32(93000) || state["dropped"] != uint64(1) {
		t.Fatalf("retransmission prevented fresh parity proof: %v", state)
	}
	if len(delivered) != 4 || delivered[2] != 42 || delivered[3] != 100 {
		t.Fatalf("previous retransmission must pass; protected original must not: %v", delivered)
	}
}
