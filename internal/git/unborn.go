package git

import (
	"context"
	"errors"
)

// UnbornHead reports whether the checkout is on the named branch with no ref
// yet. Other branches may already have commits in linked worktrees. Git errors
// other than an absent HEAD must not be interpreted as an empty repository.
func UnbornHead(ctx context.Context, runner Runner, directory, branch string) (bool, error) {
	if branch == "" {
		return false, nil
	}
	head, err := runner.Run(ctx, directory, "symbolic-ref", "--quiet", "HEAD")
	if err != nil {
		return false, err
	}
	if Output(head) != "refs/heads/"+branch {
		return false, nil
	}
	_, err = runner.Run(ctx, directory, "rev-parse", "--verify", "--quiet", "HEAD")
	if err == nil {
		return false, nil
	}
	var command *CommandError
	if errors.As(err, &command) && command.ExitCode == 1 {
		return true, nil
	}
	return false, err
}
