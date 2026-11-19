package git_test

import (
	"context"
	"errors"
	"testing"

	"github.com/dbpprt/dieter/internal/git"
)

type unbornProbeRunner struct {
	resolveErr error
	symbolic   string
	calls      int
}

func (r *unbornProbeRunner) Run(_ context.Context, _ string, args ...string) (git.Result, error) {
	r.calls++
	if args[0] == "symbolic-ref" {
		return git.Result{Output: []byte(r.symbolic)}, nil
	}
	return git.Result{}, r.resolveErr
}

func TestUnbornHeadDoesNotHideGitFailures(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name   string
		err    error
		unborn bool
	}{
		{"missing", &git.CommandError{ExitCode: 1}, true},
		{"existing", nil, false},
		{"corrupt", &git.CommandError{ExitCode: 128}, false},
		{"canceled", context.Canceled, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			runner := &unbornProbeRunner{resolveErr: tc.err, symbolic: "refs/heads/main"}
			actual, err := git.UnbornHead(context.Background(), runner, "repo", "main")
			if actual != tc.unborn {
				t.Fatalf("unborn=%v want %v", actual, tc.unborn)
			}
			if tc.err != nil && !tc.unborn && !errors.Is(err, tc.err) {
				t.Fatalf("hid failure: %v", err)
			}
			if (tc.err == nil || tc.unborn) && err != nil {
				t.Fatal(err)
			}
		})
	}
	runner := &unbornProbeRunner{resolveErr: &git.CommandError{ExitCode: 1}, symbolic: "refs/heads/other"}
	if unborn, err := git.UnbornHead(context.Background(), runner, "repo", "main"); unborn || err != nil || runner.calls != 1 {
		t.Fatalf("treated another missing branch as unborn: %v %v", unborn, err)
	}
}
