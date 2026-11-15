//go:build unix

package codexrpc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// The test binary doubles as a fake app-server: `codexrpc.test fake-app-server`.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "fake-app-server" {
		fakeAppServer()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func fakeAppServer() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 4<<20)
	out := bufio.NewWriter(os.Stdout)
	send := func(value any) {
		raw, _ := json.Marshal(value)
		_, _ = out.Write(append(raw, '\n'))
		_ = out.Flush()
	}
	initialized := false
	for scanner.Scan() {
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(scanner.Bytes(), &request) != nil {
			continue
		}
		switch request.Method {
		case "initialize":
			var params struct {
				ClientInfo struct{ Name, Title, Version string } `json:"clientInfo"`
			}
			_ = json.Unmarshal(request.Params, &params)
			if params.ClientInfo.Name != "dieter" || params.ClientInfo.Title != "Dieter" || params.ClientInfo.Version == "" {
				send(map[string]any{"id": request.ID, "error": map[string]any{"code": -32600, "message": "bad clientInfo"}})
				continue
			}
			send(map[string]any{"id": request.ID, "result": map[string]any{"codexHome": "/tmp/x", "platformFamily": "unix", "platformOs": "macos", "userAgent": "fake"}})
		case "initialized":
			initialized = true
		case "echo":
			if !initialized {
				send(map[string]any{"id": request.ID, "error": map[string]any{"code": -32002, "message": "not initialized"}})
				continue
			}
			send(map[string]any{"id": request.ID, "result": map[string]any{"params": request.Params}})
		case "notify":
			// A server request, then notifications, then the response.
			send(map[string]any{"id": "srv-1", "method": "account/chatgptAuthTokens/refresh", "params": map[string]any{}})
			for i := 0; i < 3; i++ {
				send(map[string]any{"method": "account/rateLimits/updated", "params": map[string]any{"n": i}})
			}
			send(map[string]any{"id": request.ID, "result": map[string]any{}})
		case "fail":
			send(map[string]any{"id": request.ID, "error": map[string]any{"code": -32000, "message": "nope"}})
		case "slow":
			// Never answers.
		case "huge":
			send(map[string]any{"method": "big", "params": strings.Repeat("x", MaxLineBytes+10)})
		case "exit":
			fmt.Fprintln(os.Stderr, "fatal: fake app-server exits")
			os.Exit(3)
		}
		if strings.Contains(string(request.ID), "srv-1") {
			// The client's refusal of the server request.
			send(map[string]any{"method": "refused", "params": json.RawMessage(scanner.Bytes())})
		}
	}
}

func start(t *testing.T) *Client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client, err := Start(ctx, Options{Path: os.Args[0], Args: []string{"fake-app-server"}, Env: []string{"PATH=/usr/bin:/bin"}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client
}

func TestRequestsNotificationsAndServerRequests(t *testing.T) {
	t.Parallel()
	client := start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var echoed struct {
		Params map[string]any `json:"params"`
	}
	if err := client.Request(ctx, "echo", map[string]any{"refreshToken": true}, &echoed); err != nil || echoed.Params["refreshToken"] != true {
		t.Fatalf("echo = %+v, %v", echoed, err)
	}
	if err := client.Request(ctx, "notify", nil, nil); err != nil {
		t.Fatal(err)
	}
	var methods []string
	for len(methods) < 4 {
		select {
		case n := <-client.Notifications():
			methods = append(methods, n.Method)
		case <-ctx.Done():
			t.Fatalf("notifications = %v", methods)
		}
	}
	if strings.Join(methods[:3], ",") != "account/rateLimits/updated,account/rateLimits/updated,account/rateLimits/updated" || methods[3] != "refused" {
		t.Fatalf("notifications = %v", methods)
	}
	var rpcErr *Error
	if err := client.Request(ctx, "fail", nil, nil); !errors.As(err, &rpcErr) || rpcErr.Code != -32000 {
		t.Fatalf("fail = %v", err)
	}
}

func TestRequestHonorsContextDeadline(t *testing.T) {
	t.Parallel()
	client := start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if err := client.Request(ctx, "slow", nil, nil); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("slow = %v", err)
	}
	// The client stays usable.
	ctx2, cancel2 := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel2()
	if err := client.Request(ctx2, "echo", nil, nil); err != nil {
		t.Fatal(err)
	}
}

func TestOversizedLinesEndTheSession(t *testing.T) {
	t.Parallel()
	client := start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := client.Request(ctx, "huge", nil, nil); err == nil {
		t.Fatal("oversized line accepted")
	}
	select {
	case <-client.Done():
	case <-ctx.Done():
		t.Fatal("app-server still running")
	}
	if err := client.Request(ctx, "echo", nil, nil); err == nil {
		t.Fatal("request after the session ended")
	}
}

func TestExitFailsPendingRequestsWithStderr(t *testing.T) {
	t.Parallel()
	client := start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	err := client.Request(ctx, "exit", nil, nil)
	if !errors.Is(err, ErrClosed) || !strings.Contains(err.Error(), "fake app-server exits") {
		t.Fatalf("exit = %v", err)
	}
	if _, open := <-client.Notifications(); open {
		t.Fatal("notifications stay open after exit")
	}
}

func TestCloseStopsTheProcess(t *testing.T) {
	t.Parallel()
	client := start(t)
	started := time.Now()
	client.Close()
	client.Close()
	select {
	case <-client.Done():
	default:
		t.Fatal("Close returned before the process exited")
	}
	if time.Since(started) > 3*time.Second {
		t.Fatal("app-server ignored stdin EOF")
	}
}

func TestStartFailsWhenInitializeFails(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := Start(ctx, Options{Path: "/bin/sh", Args: []string{"-c", "exit 1"}}); err == nil {
		t.Fatal("started without a handshake")
	}
	if _, err := Start(ctx, Options{Path: "/nonexistent/codex"}); err == nil {
		t.Fatal("started a missing executable")
	}
}
