package accounts

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/harness/codexrpc"
	"github.com/dbpprt/dieter/internal/platform/fault"
)

const (
	// codexDeviceLifetime is how long OpenAI keeps a device code (P0.4).
	codexDeviceLifetime = 15 * time.Minute
	// codexDeviceRestarts bounds automatic new codes after an expiry.
	codexDeviceRestarts = 3
	// codexCallbackPort is Codex's fixed browser-login callback port.
	codexCallbackPort = 1455
)

// codexLogin drives Codex's own ChatGPT login over app-server (proposal S4,
// P0.4): a device code by default, or a browser login whose loopback
// callback can be forwarded from another device.
type codexLogin struct {
	backend *execBackend
	request CodexLoginRequest
	client  *codexrpc.Client
	updates chan LoginUpdate
	cancel  context.CancelFunc

	mu        sync.Mutex
	loginID   string
	challenge Challenge
}

func (b *execBackend) CodexLogin(ctx context.Context, request CodexLoginRequest) (LoginDriver, error) {
	if request.Flow != FlowDeviceCode && request.Flow != FlowBrowser {
		return nil, fault.Invalidf("Codex has no %s sign-in", request.Flow)
	}
	client, err := b.startCodex(ctx, request.Home)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	login := &codexLogin{backend: b, request: request, client: client, updates: make(chan LoginUpdate, 8), cancel: cancel}
	go login.run(ctx)
	return login, nil
}

func (l *codexLogin) Updates() <-chan LoginUpdate { return l.updates }

func (l *codexLogin) Cancel() { l.cancel() }

func (l *codexLogin) send(ctx context.Context, update LoginUpdate) {
	select {
	case l.updates <- update:
	case <-ctx.Done():
	}
}

func (l *codexLogin) fail(ctx context.Context, message string) {
	l.send(ctx, LoginUpdate{Phase: PhaseFailed, ErrorCode: "login_failed", ErrorMessage: message})
}

// start asks Codex for a new login and reports its challenge.
func (l *codexLogin) start(ctx context.Context) error {
	params := map[string]any{"type": "chatgptDeviceCode"}
	if l.request.Flow == FlowBrowser {
		params = map[string]any{"type": "chatgpt"}
	}
	var result struct {
		LoginID         string `json:"loginId"`
		VerificationURL string `json:"verificationUrl"`
		UserCode        string `json:"userCode"`
		AuthURL         string `json:"authUrl"`
	}
	if err := l.client.Request(ctx, "account/login/start", params, &result); err != nil {
		return err
	}
	challenge := Challenge{OpenURL: result.VerificationURL, UserCode: result.UserCode, Expects: ExpectsNone,
		ExpiresAt: l.backend.now().Add(codexDeviceLifetime).UTC().Format(time.RFC3339)}
	if l.request.Flow == FlowBrowser {
		challenge = Challenge{OpenURL: result.AuthURL, LocalURL: result.AuthURL, CallbackPort: redirectPort(result.AuthURL, codexCallbackPort), Expects: ExpectsCallback}
	}
	l.mu.Lock()
	l.loginID, l.challenge = result.LoginID, challenge
	l.mu.Unlock()
	l.send(ctx, LoginUpdate{Phase: PhaseWaiting, Challenge: challenge})
	return nil
}

func (l *codexLogin) run(ctx context.Context) {
	defer close(l.updates)
	defer l.client.Close()
	if err := l.start(ctx); err != nil {
		if ctx.Err() == nil {
			l.fail(ctx, "Codex could not start the sign-in: "+err.Error())
		}
		return
	}
	restarts := 0
	for {
		select {
		case <-ctx.Done():
			l.mu.Lock()
			loginID := l.loginID
			l.mu.Unlock()
			cancelCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = l.client.Request(cancelCtx, "account/login/cancel", map[string]any{"loginId": loginID}, nil)
			cancel()
			return
		case <-l.client.Done():
			l.fail(ctx, "Codex stopped during the sign-in")
			return
		case notification, open := <-l.client.Notifications():
			if !open {
				l.fail(ctx, "Codex stopped during the sign-in")
				return
			}
			if notification.Method != "account/login/completed" {
				continue
			}
			var completed struct {
				LoginID *string `json:"loginId"`
				Success bool    `json:"success"`
				Error   *string `json:"error"`
			}
			if json.Unmarshal(notification.Params, &completed) != nil {
				continue
			}
			l.mu.Lock()
			current := l.loginID
			l.mu.Unlock()
			if completed.LoginID != nil && *completed.LoginID != "" && *completed.LoginID != current {
				continue
			}
			if completed.Success {
				l.finish(ctx)
				return
			}
			reason := "the sign-in did not complete"
			if completed.Error != nil && *completed.Error != "" {
				reason = *completed.Error
			}
			// Device codes expire after 15 minutes; offer a fresh one.
			if l.request.Flow == FlowDeviceCode && strings.Contains(strings.ToLower(reason), "timed out") && restarts < codexDeviceRestarts {
				restarts++
				if err := l.start(ctx); err != nil {
					if ctx.Err() == nil {
						l.fail(ctx, "Codex could not start a new code: "+err.Error())
					}
					return
				}
				continue
			}
			l.fail(ctx, "Codex: "+reason)
			return
		}
	}
}

// finish reads the signed-in identity from account/read and auth.json.
func (l *codexLogin) finish(ctx context.Context) {
	readCtx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	var read codexAccount
	if err := l.client.Request(readCtx, "account/read", map[string]any{}, &read); err != nil {
		l.fail(ctx, "Codex signed in but could not read the account: "+err.Error())
		return
	}
	status, err := codexIdentity(read, l.request.Home.Dir)
	if err != nil || !status.LoggedIn {
		l.fail(ctx, "Codex finished without a ChatGPT sign-in")
		return
	}
	l.send(ctx, LoginUpdate{Phase: PhaseSucceeded, Identity: status.Identity})
}

// Submit replays the browser's loopback redirect to Codex's listener; device
// codes complete on their own.
func (l *codexLogin) Submit(ctx context.Context, code, callbackURL string) error {
	l.mu.Lock()
	challenge := l.challenge
	l.mu.Unlock()
	if callbackURL == "" || challenge.Expects != ExpectsCallback {
		return fault.New(fault.FailedPrecondition, "this ChatGPT sign-in completes on its own; enter the code on OpenAI's page")
	}
	address, err := parseCallback(callbackURL, challenge.CallbackPort, "/auth/callback")
	if err != nil {
		return err
	}
	return replayCallback(ctx, address, challenge.CallbackPort)
}
