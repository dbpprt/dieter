package pipeline

import (
	"context"
	"strings"
)

// changedPaths lists tracked changes against HEAD, or against the merge base
// with base, plus untracked files. Deletions and both sides of a rename count.
func changedPaths(ctx context.Context, root, base string) ([]string, error) {
	ref := "HEAD"
	if base != "" {
		out, err := command(ctx, root, nil, "git", "merge-base", base, "HEAD")
		if err != nil {
			return nil, err
		}
		ref = strings.TrimSpace(out)
	}
	tracked, err := command(ctx, root, nil, "git", "diff", "--name-only", "--no-renames", "-z", ref, "--")
	if err != nil {
		return nil, err
	}
	untracked, err := command(ctx, root, nil, "git", "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return nil, err
	}
	return strings.Split(tracked+untracked, "\x00"), nil
}
