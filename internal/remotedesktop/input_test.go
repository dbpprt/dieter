package remotedesktop

import (
	"bytes"
	"context"
	"io"
	"strings"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/proto"
)

type writeBuffer struct{ bytes.Buffer }

func (*writeBuffer) Close() error { return nil }

func TestValidateInputBindsEpochAndBoundsCoordinates(t *testing.T) {
	epoch := bytes.Repeat([]byte{7}, 16)
	input := &dieterv1.RemoteDesktopInput{
		ProtocolVersion: inputProtocolVersion, InputEpoch: epoch, Sequence: 1,
		Payload: &dieterv1.RemoteDesktopInput_PointerMove{PointerMove: &dieterv1.RemoteDesktopPointerMove{NormalizedX: 500_000, NormalizedY: 1_000_000}},
	}
	if err := validateInput(input, epoch); err != nil {
		t.Fatal(err)
	}
	input.GetPointerMove().NormalizedX = maxNormalizedCoordinate + 1
	if err := validateInput(input, epoch); err == nil {
		t.Fatal("out-of-range coordinate was accepted")
	}
	input.GetPointerMove().NormalizedX = 0
	if err := validateInput(input, bytes.Repeat([]byte{8}, 16)); err == nil {
		t.Fatal("input from another session epoch was accepted")
	}
}

func TestPointerQueueKeepsOnlyTheNewestUnreliableMove(t *testing.T) {
	epoch := bytes.Repeat([]byte{9}, 16)
	session := &Session{control: true, inputEpoch: epoch, pointerInput: make(chan *dieterv1.RemoteDesktopInput, 1), stateInput: make(chan *dieterv1.RemoteDesktopInput, 1)}
	for sequence, x := range []int32{100, 200} {
		input := &dieterv1.RemoteDesktopInput{
			ProtocolVersion: inputProtocolVersion, InputEpoch: epoch, Sequence: uint64(sequence + 1),
			Payload: &dieterv1.RemoteDesktopInput_PointerMove{PointerMove: &dieterv1.RemoteDesktopPointerMove{NormalizedX: x}},
		}
		raw, err := proto.Marshal(input)
		if err != nil {
			t.Fatal(err)
		}
		session.handleInput(pointerChannelLabel, raw)
	}
	latest := <-session.pointerInput
	if latest.GetSequence() != 2 || latest.GetPointerMove().GetNormalizedX() != 200 {
		t.Fatalf("latest pointer move=%#v", latest)
	}
}

func TestNativeInputTranslationDoesNotExposeUnboundedData(t *testing.T) {
	writer := &writeBuffer{}
	source := &nativeHelperSource{control: writer}
	input := &dieterv1.RemoteDesktopInput{Payload: &dieterv1.RemoteDesktopInput_Key{Key: &dieterv1.RemoteDesktopKey{KeyCode: 55, Down: true, Modifiers: 8}}}
	if err := source.SendInput(context.Background(), input); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(writer)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "{\"input\":{\"kind\":\"key\",\"down\":true,\"key_code\":55,\"modifiers\":8}}\n" {
		t.Fatalf("helper command=%q", got)
	}
	if strings.Contains(string(got), "sequence") || strings.Contains(string(got), "epoch") {
		t.Fatalf("helper received transport metadata: %q", got)
	}
}
