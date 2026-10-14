---
title: "File transfers"
description: "Copy and sync binary files between your computer and a Dieter workspace."
weight: 65
---

Use `dieter file cp` for individual files and `dieter file sync` for one-way
directory synchronization. Files may be binary and larger than the editor's
5 MiB limit. Uploads support files up to 64 GiB.

One endpoint is a path on the computer running the CLI. Prefix the other with
`remote:` to select a path relative to the daemon's project checkout or
conversation workspace. Global `--machine` selects the owning daemon; omit it
to use your local daemon. Transfers use the same authenticated local, direct
TLS, WebRTC, and gateway relay routes as other CLI operations.

```sh
# Upload and download an individual file.
dieter --machine builder file cp --project PROJECT ./archive.tar remote:artifacts/archive.tar
dieter --machine builder file cp --card CARD remote:results/report.pdf ./report.pdf

# Preview, then synchronize a directory's contents.
dieter --machine builder file sync --project PROJECT --dryrun ./dist/ remote:dist/
dieter --machine builder file sync --project PROJECT ./dist/ remote:dist/

# Pull remote results into a local directory.
dieter --machine builder file sync --card CARD remote:results/ ./results/
```

Use `--checkout ID` when a project has several checkouts on the selected machine.
`--card` also accepts a standalone conversation ID. Both endpoints cannot be
remote. Remote paths cannot escape the selected workspace.

## Copy and comparison rules

`cp` copies a file, replacing an observed destination file unless
`--no-clobber` is set. An existing directory destination receives the source
filename. `cp --recursive` copies directory contents, as does `sync`; a trailing
slash does not add another directory level. Empty directories are not copied.

`sync` copies missing files and files whose size or modification time differs.
It preserves source modification times and ordinary permission bits. It does
not preserve ownership, ACLs, extended attributes, hard links, or sparse layout.
Use `--checksum` to compare SHA-256 instead of modification times, including
files with equal sizes and times. `--size-only` compares only sizes and cannot
be combined with `--checksum`. All copied content is verified with SHA-256,
regardless of the comparison mode.

Hidden files are included. `.git` and names beginning with `.dieter-transfer-`
are protected and excluded from transfer and deletion. Included symlinks and special
files are unsupported and cause an explicit error. File/directory conflicts
also fail instead of implicitly replacing an entire subtree.

The CLI finishes enumeration before copying. A scan is limited to 100,000
entries; select a narrower directory for larger trees. Directory pages carry
revision checks. Transfers detect source and destination changes using observed
file revisions and verify content before publishing. This is not a filesystem
snapshot or a transaction across the whole tree. Other programs running as the
same OS user can still race the final filesystem operation; avoid concurrent
writers when mirroring important data.

## Filters and deletion

Filters match paths relative to the transferred directory, or the source
filename for a single-file copy. `*` can match across
slashes. Rules are applied in command-line order; the last match wins. Paths
are included unless a matching rule excludes them.

```sh
dieter --machine builder file sync --project PROJECT \
  --exclude '*' --include '*.json' ./data/ remote:data/

dieter --machine builder file sync --project PROJECT \
  --delete --exclude '*.secret' ./dist/ remote:dist/
```

`--delete` is available only with `sync`. It deletes destination-only files,
never excluded files or directories recursively. Copies must all succeed first,
and Dieter rescans the source before deletion. A failed scan, failed transfer,
or changed source suppresses the deletion phase. Each deletion checks the
observed destination revision. Empty destination directories may remain.

Always inspect `--dryrun --delete` when adopting an existing destination. Dry
runs print the same planner's actions without creating uploads or writing files.

## Interrupted transfers and resource limits

Rerun the same command after interruption. Uploads resume from durable chunk
receipts on the destination daemon; identical retries do not append duplicate
bytes. Commit receipts resolve a connection loss after publication. Upload
metadata and staged chunks stay under `DIETER_HOME`, never in project metadata
or on the gateway.

Downloads retain a payload-only partial file beside the destination. Its name
starts with `.dieter-transfer-` and is tied to the destination name and expected
content hash. Rerunning resumes at the saved chunk boundary and verifies the
whole file before atomic publication. A corrupted partial fails verification;
remove the partial named in the error to restart. An interruption can leave
partials that must be removed manually when no longer needed.

Uploads expire after 24 hours; expired staging is collected when a new upload
is admitted. At most 4,096 upload sessions (including retained receipts) and
256 GiB of reserved staging are admitted per daemon. An exceeded limit fails
explicitly. Aborting releases staged payload but retains its replay receipt
until expiry. If publication is uncertain, `file upload commit` recovers the receipt before
an abort can be considered.

Transfers use 1 MiB chunks and default to four concurrent files. Set
`--concurrency 1` through `8`; `--bandwidth-limit BYTES_PER_SECOND` divides an
aggregate payload budget between workers. Each file is published atomically.
An interrupted directory sync can contain a mixture of completed and unchanged
files; rerunning reconciles the remainder.

## Automation and protocol inspection

Use `--format jsonl --no-progress` for action records on stdout. Progress is
written to stderr. Each record has `action` (`copy`, `skip`, `delete`), `path`,
`state` (`planned`, `complete`, `unchanged`), and `bytes`. Any failed operation
returns a nonzero exit status. A successful dry run returns zero even if it
plans changes.

`file stat --checksum` returns transfer metadata. `file scan` returns a bounded
directory page; pass its `next` and `revision` with `--after` and `--revision`.
The `file upload` group exposes `begin`, `chunk`, `show`, `commit`, and `abort`
for tools that need explicit upload sessions. Its offline help documents the
required hashes, revisions, operation IDs, and chunk alignment. Prefer `cp` and
`sync` for ordinary transfers.
