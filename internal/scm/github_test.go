package scm

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestParseGitHubRemote(t *testing.T) {
	for _, value := range []string{
		"https://github.com/dbpprt/dieter.git",
		"git@github.com:dbpprt/dieter.git",
		"ssh://git@github.com/dbpprt/dieter.git",
	} {
		host, owner, repository, err := parseGitHubRemote(value)
		if err != nil || host != "github.com" || owner != "dbpprt" || repository != "dieter" {
			t.Fatalf("parse %q = %s/%s/%s, %v", value, host, owner, repository, err)
		}
	}
	if _, _, _, err := parseGitHubRemote("file:///tmp/repo"); err == nil {
		t.Fatal("expected unsupported remote error")
	}
}

func TestCreatePullRequestReturnsExistingOpenRequest(t *testing.T) {
	runner := &fakeCommands{}
	provider := &GitHub{Commands: runner, LookPath: func(string) (string, error) { return "/usr/bin/gh", nil }}
	value, err := provider.CreatePullRequest(context.Background(), "/repo", "origin", CreatePullRequestInput{
		Title: "Title", Base: "main", Head: "feature",
	})
	if err != nil {
		t.Fatal(err)
	}
	if value.Number != 42 || value.URL != "https://github.com/acme/repo/pull/42" {
		t.Fatalf("unexpected pull request: %#v", value)
	}
	for _, call := range runner.calls {
		if strings.Contains(call, "pr create") {
			t.Fatalf("idempotent creation called pr create: %v", runner.calls)
		}
	}
}

type fakeCommands struct{ calls []string }

func (f *fakeCommands) Run(_ context.Context, _ string, name string, args ...string) ([]byte, error) {
	call := name + " " + strings.Join(args, " ")
	f.calls = append(f.calls, call)
	switch {
	case call == "git remote get-url origin":
		return []byte("git@github.com:acme/repo.git\n"), nil
	case strings.HasPrefix(call, "gh auth status"):
		return nil, nil
	case strings.HasPrefix(call, "gh pr list"):
		return []byte(`[{"number":42}]`), nil
	case strings.HasPrefix(call, "gh pr view"):
		return []byte(`{"number":42,"url":"https://github.com/acme/repo/pull/42","state":"OPEN","mergeable":"MERGEABLE","headRefName":"feature","headRefOid":"abc","baseRefName":"main","baseRefOid":"def","statusCheckRollup":[]}`), nil
	default:
		return nil, errors.New("unexpected command: " + call)
	}
}
