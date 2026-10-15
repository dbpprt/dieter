package cli

import (
	"context"
	"github.com/dbpprt/dieter/internal/claudedesign"
	"sync"
)

// cliDesignFixture stands in for Claude Code on the isolated daemon host. No
// test reaches claude.ai or the operator's Claude credentials.
type cliDesignFixture struct {
	mu       sync.Mutex
	signedIn bool
	granted  bool
	revokes  int
}

func (f *cliDesignFixture) Status(context.Context) (claudedesign.Status, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return claudedesign.Status{RuntimeReady: true, Version: "2.1.285", Available: true, SignedIn: f.signedIn, CanSignIn: true}, nil
}

func (f *cliDesignFixture) SignIn(ctx context.Context, codes <-chan string, event func(claudedesign.Event) error) error {
	if err := event(claudedesign.Event{Kind: "pages", URL: "https://claude.com/cai/oauth/authorize?flow=loopback", ManualURL: "https://claude.com/cai/oauth/authorize?flow=manual"}); err != nil {
		return err
	}
	for {
		select {
		case code := <-codes:
			if code == "good-code" {
				f.mu.Lock()
				f.signedIn = true
				f.mu.Unlock()
				return event(claudedesign.Event{Kind: "done", OK: true, Message: "Signed in to Claude Design."})
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (f *cliDesignFixture) SetGrant(_ context.Context, granted bool) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.granted = granted
	if !granted {
		f.revokes++
	}
	return "ok", nil
}
