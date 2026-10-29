# Proposal: worktree retention for Done cards (14 or 30 days)

Status: proposal 2026-10-29 · scope: a board retention setting next to Done-card
archiving, a `parked` workspace state, a sweep in the scheduler tick, restore in
`Manager.Ensure`, CLI and one row in the clients' board retention settings ·
related: "No garbage collection" in
[agent-workspaces.md](agent-workspaces.md#1-why-worktrees-hurt-today)

## TL;DR

Every new-worktree conversation leaves a full checkout under
`DIETER_HOME/worktrees/<project>/<card>`, with its own dependencies and build
output. Nothing removes it unless someone runs the `cleanup` or `discard`
operation by hand: Done-card archiving leaves worktrees behind, and nothing
runs `git worktree prune`. On a machine that runs scheduled agents, these
folders only grow.

Proposal: extend the board's retention settings, which today only archive Done
cards, with **worktree retention**: `never`, `after_14_days` or
`after_30_days`. It applies **only to cards in Done**, archived or not, counted
from when the card reached Done, the same clock Done-card archiving uses. Cards
in Todo, Running or Review keep their worktrees however long they wait.

When a Done card's worktree is due and nothing would be lost, the owner daemon
**parks** it:

- the folder goes; the branch and the workspace record stay;
- if the card is reopened or messaged again, the worktree comes back on the
  same branch at the same path;
- worktrees with uncommitted or untracked files, running turns, terminals,
  background processes or Git operations are never touched;
- integrated worktrees (`cleanup_pending`) are removed completely, through the
  existing `cleanup` operation.

Recommended default: `after_30_days`, with `after_14_days` for machines short
on disk and `never` to opt out.

## 1. Goals and non-goals

Goals:

1. Disk used by worktrees of finished work comes back without anyone cleaning
   up by hand.
2. No committed or uncommitted work is lost, and a reopened Done card
   continues where it stopped.
3. The rule is visible and has the same shape as Done-card archiving: a board
   setting, applied by the scheduler, shown on the card.

Non-goals (v1):

- Worktrees of cards that are not in Done, however long they have been idle.
- Removing worktrees with uncommitted changes, even with recovery artifacts
  (§6).
- Project-directory workspaces: that directory belongs to the user.
- Retention of `DIETER_HOME/recovery` (§6).
- Copy-on-write views from [agent-workspaces.md](agent-workspaces.md); the
  same setting should cover them once they exist.

## 2. What exists today (code facts)

| What                | Where                                                                                                                                                                                                                                                                                                                       |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Board retention     | `Board.done_archive_policy`: `never`, `immediately`, `after_1_day`, `after_7_days`, `after_30_days`, `after_90_days` (`internal/model/model.go:40-45`); CLI `dieter board retention --archive-done POLICY BOARD`; docs: "retention settings can automatically archive Done cards" (`site/content/docs/projects.md`)         |
| Done clock          | `doneCardsEligibleForArchive` measures from `Card.PhaseChangedAt` (falling back to `UpdatedAt`) and skips `DoneArchiveExempt` cards, cards owned by another daemon, and active or turn-holding cards (`internal/store/kanban/cards.go:732-772`); run from the scheduler tick (`internal/engine/scheduler/scheduler.go:188`) |
| Worktree location   | `filepath.Join(WorktreeRoot(), project.ID, card.ID)`, `WorktreeRoot()` = `DIETER_HOME/worktrees` (`internal/git/workspace/manager.go`, `internal/store/home/paths.go:27`)                                                                                                                                                   |
| Creation            | `Manager.Ensure` at turn admission (`internal/engine/turn_admission.go:138`) and recovery (`turn_recovery.go:343`); `provision` reuses `refs/heads/<branch>` when it exists, else `worktree add -b` from the base                                                                                                           |
| Managed branch name | `branchName(card)` = `dieter/<id12>-<slug of the current title>`; a fresh provision after a rename picks a different name                                                                                                                                                                                                   |
| Missing folder      | `Manager.Refresh` marks the workspace `orphaned` when its path no longer exists (`manager.go:234-236`); `Ensure` then provisions again from the card, choosing the branch name anew                                                                                                                                         |
| Removal             | `cleanup` and `discard` git operations (`internal/git/operations/manager.go:335-338`): refuse while busy, refuse dirty trees unless discarding, `discard` writes recovery artifacts first, then `git worktree remove` and branch delete                                                                                     |
| Busy check          | `operations.Manager.Busy`: terminal sessions and background processes inside the workspace (`internal/api/server.go:191`)                                                                                                                                                                                                   |
| Integrated          | merge and PR merge set `cleanup_pending` with `IntegratedHeadSHA` (`operations/manager.go:832`, `:1104`)                                                                                                                                                                                                                    |
| Activity            | `Card.LastActivityAt` advances with conversation events (`internal/store/conversations/conversations.go:372-390`); `Workspace.LastActivityAt` is rewritten on every `Refresh` (`manager.go:319`), so it means "last looked at", not "last used"                                                                             |
| Deletion cost       | In the workspace spike, deleting a view was 4–6 times slower than creating it; it recommends renaming into a trash directory and deleting in the background ([results](agent-workspaces-results.md))                                                                                                                        |

## 3. Design

### 3.1 The setting

- `Board.worktree_retention`: `never`, `after_14_days`, `after_30_days`;
  unset reads as the default (§6, question 1). It is independent of
  `done_archive_policy`: a board can archive Done cards after 7 days and park
  their worktrees after 30.
- A replicated board field `worktreeRetention`, one register like
  `doneArchivePolicy`. Each daemon applies it only to worktrees of checkouts it
  owns, because worktrees are local to their execution owner.
- `SetBoardArchivePolicyRequest` gains `worktree_retention`.
- CLI: `dieter board retention --worktrees never|14d|30d BOARD`, next to
  `--archive-done`.
- Clients: one row under the Done-card archive policy (Compose board
  administration, Mac `ArchivePolicySheet`).

### 3.2 Which worktrees are parked

All of these must hold, checked under the workspace lock and the repository
lock:

1. The card is a board card in **Done** (archived or not), not
   `DoneArchiveExempt`, and has been in Done for the board's period, by
   `PhaseChangedAt` as in Done-card archiving.
2. No conversation activity in that period either: `Card.LastActivityAt` is
   older than the period, so a Done card someone still chats on keeps its
   worktree.
3. Workspace mode `worktree`, state `ready`; never `conflicted`,
   `recovery_required`, `provisioning`, `failed` or `orphaned`.
4. No active turn lease, `Busy(card)` is false, no git operation is running.
5. Clean: `git status --porcelain` is empty, so no untracked, non-ignored
   files either. Ignored files don't count; reclaiming them is the point.
6. `HEAD` is on the recorded branch, so its commits stay reachable after the
   folder goes. A detached `HEAD` is kept.

A `cleanup_pending` workspace whose `HEAD` equals `IntegratedHeadSHA` follows
rules 1–4 and then runs the existing `cleanup` operation instead of parking:
its work is already in the base branch.

### 3.3 Parking

1. Record a `park` git operation, so it appears in the operation history with
   its reason ("Done for 31 days, board retention 30 days") and the size it
   freed.
2. `git worktree remove <path>` without `--force`. Git itself refuses a
   modified tree, a second guard after §3.2.5.
3. Rename what remains into `DIETER_HOME/trash/` and delete it in the
   background.
4. Keep the branch, also a managed one. Set the workspace state to `parked`
   with `ParkedAt`; keep `Branch`, `BaseBranch`, `BaseSHA` and `HeadSHA`.
5. `git worktree prune` for the repository, which also clears entries of
   folders deleted by hand.

At most a few workspaces per tick (for example 2), so the first run after an
upgrade does not saturate the disk.

### 3.4 Restoring

- `Manager.Ensure` treats `parked` as a provision with a fixed branch:
  `git worktree add <same path> <recorded branch>`, then `ready`. It never calls
  `branchName` again, so a renamed card keeps its branch.
- If the recorded branch was deleted meanwhile, the state becomes
  `recovery_required` with a message naming the branch and `HeadSHA`; nothing
  is guessed.
- `Manager.Refresh` leaves `parked` alone instead of marking it `orphaned`.
- Restoring costs what a new worktree costs today, once, when a Done card is
  used again.

### 3.5 Visibility

- `WorkspaceSummary.state = parked` reaches the clients; the core renders
  "Worktree removed after 30 days in Done · restored on the next message".
- `dieter workspace list` shows parked workspaces and the space they freed;
  `dieter workspace run --kind park|restore` runs the same paths on demand.
- Done cards past the period whose worktree was kept show why ("uncommitted
  changes", "terminal open"), so a person can act.

## 4. Why 14 or 30 days, and why only Done

- A card in Done is finished by the person's own judgement; a card waiting in
  Todo or Review is not, even after weeks. Tying retention to Done keeps the
  rule predictable and reuses a clock people already know from archiving.
- 30 days is one of the periods Done-card archiving already offers and leaves
  time to reopen a card after review or a release.
- 14 days suits machines that run nightly scheduled agents, where each run's
  card can end in Done with a worktree full of dependencies.
- Shorter periods would make people pay the restore cost for cards they reopen
  after a quick review; they are left out on purpose.

## 5. Tests

- Eligibility table: each rule in §3.2 alone keeps a workspace; Todo, Running
  and Review cards are never parked.
- Park then `Ensure` restores the same path and branch, also after the card
  was renamed; a second `Ensure` is a no-op.
- `Refresh` on a parked workspace keeps `parked`.
- A tree written to after the status check is kept: `git worktree remove`
  without `--force` fails and the state stays `ready`.
- `cleanup_pending` goes through `cleanup`; only there is the managed branch
  deleted.
- The setting replicates; only the checkout's owner daemon parks.
- CLI end to end over local, direct TLS and relay routes for
  `board retention --worktrees` and `workspace run --kind park|restore`.

## 6. Open questions for maintainers

1. Default: `after_30_days` for all boards, or `never` for existing boards and
   `after_30_days` for new ones?
2. Board setting, as proposed, or also a machine-wide override, since disk is
   per machine?
3. Later: park dirty Done worktrees after writing the existing recovery
   artifacts (`createRecovery`)? That would need a retention rule for
   `DIETER_HOME/recovery`, which today also only grows.
4. Should managed branches of parked worktrees be deleted after a much longer
   time (for example 180 days), or are branches left to the person?
