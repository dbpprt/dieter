# Fast Changes and shipping — 25 September 2026

## Outcome

Dieter has one VS Code-style Changes workflow. The only difference between the
two workspace modes is which checkout it reads:

- **Project directory:** every change in the registered shared checkout.
  Several agents and the human can contribute to the same list; Dieter does not
  invent file ownership.
- **New worktree:** every change in the conversation's isolated checkout.

Both use the same status reader, diff service, Git-operation manager, RPCs, CLI
commands, and client semantics.

Creating a project no longer asks how its first board should publish. Initial
boards use `manual`; remote publishing remains an explicit board or workspace
setting later.

## The workflow

The normal path is deliberately small:

1. Open Changes and immediately see staged, unstaged, untracked, renamed,
   deleted, submodule, and conflicted paths.
2. Select a file to load only that diff.
3. Stage or unstage a file or the full set.
4. Discard a confirmed file change with recovery artifacts, or commit exactly
   what is staged.
5. Update and validate explicitly.
6. Push the current project branch, or integrate a worktree branch and then use
   the configured explicit push or pull-request action.

Every mutation is a daemon-owned Git operation. Mac, Android, and the CLI ask
for an operation and then reload authoritative state; clients do not guess the
new index or branch state.

## Fast read path

An open Changes screen normally runs one bounded command:

```text
git status --porcelain=v2 -z --branch --untracked-files=all
```

That one result supplies branch, HEAD, upstream, ahead/behind, file sections,
conflicts, renames, deletions, and submodules. The list path does not calculate
all patches, scan repository size, read every untracked file, or write
incidental workspace statistics.

The daemon coalesces simultaneous reads per checkout and retains a 200 ms
in-memory presentation snapshot. Explicit diff and mutation precondition reads
bypass that snapshot. Invalidation is generation-aware: an old in-flight scan
cannot repopulate the cache after a Git operation or Dieter file edit.

Git output is bounded. A truncated status becomes a clear too-many-changes
error instead of a partial authoritative list. A selected patch is capped and
paged at 1 MiB.

## Lazy diffs and mutations

Selecting a file runs one fresh status precondition followed by one path-scoped
diff. Superseded client diff requests are canceled or ignored by generation.

Stage, unstage, discard, and commit require the caller's status revision. A
concurrent edit produces a stale-revision response and refresh instead of
silently operating on the old view. Dieter's index-changing commands are
serialized per checkout. External editors and project-mode agents can keep
writing; the next authoritative refresh shows their result.

Safe index/ref operations—stage, unstage, commit, validate, and push—remain
available while a project-mode agent is active. Branch-moving or destructive
project operations—update and discard—require the shared checkout to be idle.

## Shipping semantics

Project mode can update, validate, and explicitly push its current branch,
including the configured base branch. It does not require a fabricated review
branch.

Worktree mode keeps the existing server-owned integration sequence: commit the
worktree, update if needed, integrate into the registered base checkout,
validate, expose conflicts for continue or abort, and clean up only after a
successful integration. Publishing remains explicit.

## Native clients

Mac and Android expose the same actions and availability rules. Both retain one
latest snapshot, one selected file and diff, and one active operation. Refresh
triggers coalesce into one in-flight request plus at most one follow-up. A
project-mode activity banner explains that the shared list can keep moving; it
does not disable safe mutations.

## Qualification

The change is covered at four levels:

- parser and real-Git fixtures for staged/unstaged, rename, untracked,
  submodule, conflict, external edits, output bounds, and a 1,000-file set;
- operation tests for project staging during an active agent, idle-only update,
  commit, discard recovery, update, validate, and a real push to a disposable
  bare remote;
- Connect and CLI end-to-end flows over the same daemon APIs;
- visible Mac and Android journeys for project and worktree review, mutation,
  commit, update/validate controls, discard, conflict, and integration.

The important regression budgets are structural rather than a new subsystem:
one status command to open the list, no eager repository-wide diffs, one
mutation plus a fresh status reconciliation, bounded output, and never more
than one concurrent status scan per checkout.

## Explicit non-goals

This does not add file-to-agent ownership, persistent diff artifacts, a Git
hosting layer, synchronized commit-message drafts, a distributed transaction
system, or a new native-test scheduler. Those are unrelated to making Changes
fast and predictable.
