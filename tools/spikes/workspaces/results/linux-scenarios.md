## Recorder accuracy (sum over all turns and late windows)

| platform | provider         | driver | recorder         | all TP/FP/FN | git-scope TP/FP/FN | p50 ms | p95 ms |
| -------- | ---------------- | ------ | ---------------- | ------------ | ------------------ | ------ | ------ |
| linux    | worktree         | script | manifest         | 10676/0/0    | 635/0/0            | 1      | 2      |
| linux    | worktree         | script | shadow           | 634/0/10042  | 634/0/1            | 5      | 11     |
| linux    | overlay          | script | shadow           | 633/0/10092  | 633/0/1            | 6      | 23     |
| linux    | overlay          | script | upper            | 10725/0/0    | 634/0/0            | 0      | 21     |
| linux    | btrfs            | script | manifest         | 10726/0/0    | 635/0/0            | 3      | 4      |
| linux    | btrfs            | script | shadow           | 634/0/10092  | 634/0/1            | 4      | 5      |
| linux    | reflink          | script | manifest         | 10726/0/0    | 635/0/0            | 3      | 4      |
| linux    | reflink          | script | shadow           | 634/0/10092  | 634/0/1            | 4      | 5      |
| linux    | worktree-hydrate | script | manifest         | 10726/0/0    | 635/0/0            | 3      | 3      |
| linux    | worktree-hydrate | script | shadow           | 634/0/10092  | 634/0/1            | 5      | 11     |
| linux    | overlay          | codex  | harness-reported | 14/0/21336   | 14/0/1254          | –      | –      |
| linux    | overlay          | codex  | shadow           | 1264/0/20086 | 1264/0/4           | 6      | 26     |
| linux    | overlay          | codex  | upper            | 21350/0/0    | 1268/0/0           | 0      | 21     |
| linux    | overlay          | claude | harness-reported | 866/0/20584  | 866/0/402          | –      | –      |
| linux    | overlay          | claude | shadow           | 1266/0/20184 | 1266/0/2           | 6      | 27     |
| linux    | overlay          | claude | upper            | 21450/0/0    | 1268/0/0           | 0      | 22     |

## Harness-reported coverage per scenario (git scope, reported/true paths summed over reps)

| scenario                                            | linux/overlay/claude | linux/overlay/codex |
| --------------------------------------------------- | -------------------- | ------------------- |
| M01 three turns in one session                      | ✓ 4/4                | partial 2/4         |
| M01/t2 three turns in one session                   | ✓ 4/4                | ✗ 0/4               |
| M01/t3 three turns in one session                   | ✓ 2/2                | ✓ 2/2               |
| S01 edit tool modifies a tracked file               | ✓ 2/2                | ✓ 2/2               |
| S02 edit tool creates a file                        | ✓ 2/2                | ✓ 2/2               |
| S03 sed -i on a tracked file                        | ✓ 2/2                | ✗ 0/2               |
| S04 shell creates files                             | ✓ 4/4                | ✗ 0/4               |
| S05 rm a tracked file                               | ✓ 2/2                | ✗ 0/2               |
| S06 mv a tracked file                               | ✓ 4/4                | ✗ 0/4               |
| S07 mv a directory                                  | partial 400/800      | ✗ 0/800             |
| S08 chmod +x only                                   | ✓ 2/2                | ✗ 0/2               |
| S09 touch and identical rewrite (no net change)     | 0/0                  | 0/0                 |
| S10 create and retarget symlinks                    | ✓ 4/4                | ✗ 0/4               |
| S11 1 MiB and 50 MiB binaries                       | ✓ 4/4                | ✗ 0/4               |
| S12 bulk in-place rewrite of 200 files              | ✓ 400/400            | ✗ 0/400             |
| S13 codegen into ignored gen/ and tracked api/      | ✓ 2/2                | ✗ 0/2               |
| S14 dependency install: 10k files into node_modules | 0/0                  | 0/0                 |
| S15 edit ignored .env                               | 0/0                  | 0/0                 |
| S16 agent commits, then edits again                 | ✓ 4/4                | ✗ 0/4               |
| S17 branch switch and stash round trip              | ✓ 2/2                | ✗ 0/2               |
| S18 case-only rename                                | ✓ 4/4                | ✗ 0/4               |
| S19 NFD and NFC filenames                           | ✓ 2/2                | ✗ 0/2               |
| S20 background writer after the turn                | 0/0                  | 0/0                 |
| S21 writes outside the view                         | ✓ 2/2                | ✗ 0/2               |
| S22 hard link                                       | ✓ 2/2                | ✗ 0/2               |
| S23 xattr-only change                               | ✗ 0/2                | ✗ 0/2               |
| S24 rm -rf ignored build/                           | 0/0                  | 0/0                 |
| S25 busy turn: three edits and three shell commands | ✓ 12/12              | partial 6/12        |

## Late writes, escapes, git ops

- **linux/worktree/script**: S20 r1: late ['late.txt'] caught by ['manifest', 'shadow']; S21 r1: escapes {'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r1: late ['late-m01.txt'] caught by ['manifest', 'shadow']
- **linux/overlay/script**: S21 r1: escapes {'sentinel': ['escape.txt']}
- **linux/btrfs/script**: S20 r1: late ['late.txt'] caught by ['manifest', 'shadow']; S21 r1: escapes {'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r1: late ['late-m01.txt'] caught by ['manifest', 'shadow']
- **linux/reflink/script**: S20 r1: late ['late.txt'] caught by ['manifest', 'shadow']; S21 r1: escapes {'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r1: late ['late-m01.txt'] caught by ['manifest', 'shadow']
- **linux/worktree-hydrate/script**: S01 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S02 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S03 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S04 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S05 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S06 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S07 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S08 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S09 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S10 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S11 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S12 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S13 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S14 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S15 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S16 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S17 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S18 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S19 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S20 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S21 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S22 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S23 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S24 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S25 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; M01 r1: error create view: hydrate .env: readdirent /home/dbpprt/dieter-spike/linux/script/worktree-hydrate/base/.env: not a directory; S20 r1: late ['late.txt'] caught by ['manifest', 'shadow']; S21 r1: escapes {'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r1: late ['late-m01.txt'] caught by ['manifest', 'shadow']
- **linux/overlay/codex**: S21 r1: escapes {'sentinel': ['escape.txt']}; S21 r2: escapes {'sentinel': ['escape.txt']}
- **linux/overlay/claude**: S21 r1: escapes {'sentinel': ['escape.txt']}; S21 r2: escapes {'sentinel': ['escape.txt']}

## Git-scope misses of the shadow snapshot

- **linux/worktree/script**: S23: ['docs/guide.md']
- **linux/overlay/script**: S23: ['docs/guide.md']
- **linux/btrfs/script**: S23: ['docs/guide.md']
- **linux/reflink/script**: S23: ['docs/guide.md']
- **linux/worktree-hydrate/script**: S23: ['docs/guide.md']
- **linux/overlay/codex**: S19: ['docs/Café.txt']; S23: ['docs/guide.md']
- **linux/overlay/claude**: S23: ['docs/guide.md']

## View creation inside scenario runs (small fixture)

| platform | provider         | driver | create p50 ms | p95 ms |
| -------- | ---------------- | ------ | ------------- | ------ |
| linux    | worktree         | script | 14            | 16     |
| linux    | overlay          | script | 0             | 0      |
| linux    | btrfs            | script | 5             | 12     |
| linux    | reflink          | script | 41            | 43     |
| linux    | worktree-hydrate | script | 46            | 49     |
| linux    | overlay          | codex  | 0             | 0      |
| linux    | overlay          | claude | 0             | 0      |
