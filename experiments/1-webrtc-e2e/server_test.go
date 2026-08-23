package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

func TestEndToEndVideoAndDataChannel(t *testing.T) {
	config := testExperimentConfig()
	host := newExperimentServer(config, syntheticSource{interval: 10 * time.Millisecond}, log.New(io.Discard, "", 0))
	defer host.close()
	httpServer := httptest.NewServer(host.handler())
	defer httpServer.Close()

	settingEngine := webrtc.SettingEngine{}
	settingEngine.SetIncludeLoopbackCandidate(true)
	clientAPI := webrtc.NewAPI(webrtc.WithSettingEngine(settingEngine))
	client, err := clientAPI.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	connected := make(chan struct{}, 1)
	client.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateConnected {
			select {
			case connected <- struct{}{}:
			default:
			}
		}
	})
	video := make(chan struct{}, 1)
	client.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		go func() {
			if _, _, readErr := track.ReadRTP(); readErr == nil {
				select {
				case video <- struct{}{}:
				default:
				}
			}
		}()
	})
	if _, err := client.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		t.Fatal(err)
	}

	pong := make(chan string, 1)
	probe, err := client.CreateDataChannel("probe", nil)
	if err != nil {
		t.Fatal(err)
	}
	probe.OnOpen(func() {
		if sendErr := probe.SendText("ping:test-round-trip"); sendErr != nil {
			t.Errorf("send probe: %v", sendErr)
		}
	})
	probe.OnMessage(func(message webrtc.DataChannelMessage) {
		select {
		case pong <- string(message.Data):
		default:
		}
	})

	offer, err := client.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gatherComplete := webrtc.GatheringCompletePromise(client)
	if err := client.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-gatherComplete:
	case <-time.After(5 * time.Second):
		t.Fatal("client ICE gathering timed out")
	}

	answer := postOffer(t, httpServer.URL, config.token, client.LocalDescription())
	if err := client.SetRemoteDescription(answer); err != nil {
		t.Fatal(err)
	}
	waitForSignal(t, connected, "peer connection")
	waitForSignal(t, video, "video RTP")
	select {
	case message := <-pong:
		if message != "pong:test-round-trip" {
			t.Fatalf("unexpected probe response %q", message)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("timed out waiting for data-channel probe")
	}

	request, err := http.NewRequest(http.MethodGet, httpServer.URL+"/status", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+config.token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var status sessionStatus
	if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
		t.Fatal(err)
	}
	if !status.Active || status.Frames == 0 || status.Bytes == 0 {
		t.Fatalf("unexpected session status: %#v", status)
	}
}

func TestSignalingRequiresTokenAndRejectsInvalidOffer(t *testing.T) {
	config := testExperimentConfig()
	host := newExperimentServer(config, syntheticSource{}, log.New(io.Discard, "", 0))
	defer host.close()

	unauthorized := httptest.NewRequest(http.MethodGet, "/config", nil)
	unauthorizedResponse := httptest.NewRecorder()
	host.handler().ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized config status=%d", unauthorizedResponse.Code)
	}

	invalid := httptest.NewRequest(http.MethodPost, "/offer", strings.NewReader(`{"type":"answer","sdp":"not-an-offer"}`))
	invalid.Header.Set("Authorization", "Bearer "+config.token)
	invalidResponse := httptest.NewRecorder()
	host.handler().ServeHTTP(invalidResponse, invalid)
	if invalidResponse.Code != http.StatusBadRequest {
		t.Fatalf("invalid offer status=%d body=%s", invalidResponse.Code, invalidResponse.Body.String())
	}
}

func TestCloseEndsActiveSession(t *testing.T) {
	config := testExperimentConfig()
	host := newExperimentServer(config, syntheticSource{}, log.New(io.Discard, "", 0))
	defer host.close()

	settingEngine := webrtc.SettingEngine{}
	settingEngine.SetIncludeLoopbackCandidate(true)
	client, err := webrtc.NewAPI(webrtc.WithSettingEngine(settingEngine)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if _, err := client.CreateDataChannel("probe", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := client.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		t.Fatal(err)
	}
	offer, err := client.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gatherComplete := webrtc.GatheringCompletePromise(client)
	if err := client.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	<-gatherComplete
	answer := postOfferHandler(t, host, config.token, client.LocalDescription())
	if err := client.SetRemoteDescription(answer); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodPost, "/close", nil)
	request.Header.Set("Authorization", "Bearer "+config.token)
	response := httptest.NewRecorder()
	host.handler().ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("close status=%d", response.Code)
	}
	if status := host.status(); status.Active {
		t.Fatalf("session remained active: %#v", status)
	}
}

func postOffer(t *testing.T, baseURL, token string, offer *webrtc.SessionDescription) webrtc.SessionDescription {
	t.Helper()
	payload, err := json.Marshal(offer)
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, baseURL+"/offer", bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("offer status=%d body=%s", response.StatusCode, body)
	}
	var answer webrtc.SessionDescription
	if err := json.NewDecoder(response.Body).Decode(&answer); err != nil {
		t.Fatal(err)
	}
	return answer
}

func postOfferHandler(t *testing.T, host *experimentServer, token string, offer *webrtc.SessionDescription) webrtc.SessionDescription {
	t.Helper()
	payload, err := json.Marshal(offer)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/offer", bytes.NewReader(payload))
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	host.handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("offer status=%d body=%s", response.Code, response.Body.String())
	}
	var answer webrtc.SessionDescription
	if err := json.NewDecoder(response.Body).Decode(&answer); err != nil {
		t.Fatal(err)
	}
	return answer
}

func waitForSignal(t *testing.T, signal <-chan struct{}, name string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(8 * time.Second):
		t.Fatalf("timed out waiting for %s", name)
	}
}

func testExperimentConfig() experimentConfig {
	return experimentConfig{
		token:          "test-token",
		source:         "synthetic",
		fps:            30,
		bitrateKbps:    4_000,
		gatherTimeout:  5 * time.Second,
		sessionTimeout: time.Minute,
	}
}

func TestSessionContextDoesNotDependOnOfferRequest(t *testing.T) {
	config := testExperimentConfig()
	host := newExperimentServer(config, syntheticSource{}, log.New(io.Discard, "", 0))
	defer host.close()
	requestContext, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, err := host.answer(requestContext, webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: "invalid"})
	if err == nil {
		t.Fatal("expected invalid/canceled offer to fail")
	}
}
