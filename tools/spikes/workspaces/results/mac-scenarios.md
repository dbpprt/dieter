## Recorder accuracy (sum over all turns and late windows)

| platform | provider         | driver | recorder         | all TP/FP/FN  | git-scope TP/FP/FN | p50 ms | p95 ms |
| -------- | ---------------- | ------ | ---------------- | ------------- | ------------------ | ------ | ------ |
| darwin   | clone            | script | clonescan        | 10726/3/0     | 635/3/0            | 21     | 55     |
| darwin   | clone            | script | fsevents         | 10326/204/400 | 235/204/400        | 76     | 221    |
| darwin   | clone            | script | manifest         | 10726/0/0     | 635/0/0            | 30     | 68     |
| darwin   | clone            | script | shadow           | 632/0/10094   | 632/0/3            | 240    | 453    |
| darwin   | clone-raw        | script | clonescan        | 10726/3/0     | 635/3/0            | 22     | 42     |
| darwin   | clone-raw        | script | fsevents         | 10326/204/400 | 235/204/400        | 86     | 352    |
| darwin   | clone-raw        | script | manifest         | 10726/0/0     | 635/0/0            | 34     | 85     |
| darwin   | clone-raw        | script | shadow           | 632/0/10094   | 632/0/3            | 285    | 519    |
| darwin   | clone-worktree   | script | clonescan        | 10726/3/0     | 635/3/0            | 20     | 46     |
| darwin   | clone-worktree   | script | fsevents         | 10326/204/400 | 235/204/400        | 76     | 370    |
| darwin   | clone-worktree   | script | manifest         | 10726/0/0     | 635/0/0            | 31     | 59     |
| darwin   | clone-worktree   | script | shadow           | 632/0/10094   | 632/0/3            | 278    | 474    |
| darwin   | worktree-hydrate | script | clonescan        | 10726/3/0     | 635/3/0            | 23     | 57     |
| darwin   | worktree-hydrate | script | fsevents         | 10326/204/400 | 235/204/400        | 76     | 378    |
| darwin   | worktree-hydrate | script | manifest         | 10726/0/0     | 635/0/0            | 33     | 67     |
| darwin   | worktree-hydrate | script | shadow           | 632/0/10094   | 632/0/3            | 276    | 466    |
| darwin   | worktree         | script | clonescan        | 10676/3/0     | 635/3/0            | 5      | 16     |
| darwin   | worktree         | script | fsevents         | 10276/204/400 | 235/204/400        | 76     | 372    |
| darwin   | worktree         | script | manifest         | 10676/0/0     | 635/0/0            | 7      | 78     |
| darwin   | worktree         | script | shadow           | 632/0/10044   | 632/0/3            | 288    | 3060   |
| darwin   | clone            | codex  | harness-reported | 14/0/21334    | 14/0/1252          | –      | –      |
| darwin   | clone            | codex  | clonescan        | 21348/6/0     | 1266/6/0           | 23     | 55     |
| darwin   | clone            | codex  | fsevents         | 20548/408/800 | 466/408/800        | 87     | 502    |
| darwin   | clone            | codex  | manifest         | 21348/0/0     | 1266/0/0           | 33     | 99     |
| darwin   | clone            | codex  | shadow           | 1260/0/20088  | 1260/0/6           | 303    | 577    |
| darwin   | clone            | claude | harness-reported | 862/0/20587   | 862/0/405          | –      | –      |
| darwin   | clone            | claude | clonescan        | 21452/6/0     | 1270/6/0           | 24     | 81     |
| darwin   | clone            | claude | fsevents         | 20652/422/800 | 470/422/800        | 91     | 504    |
| darwin   | clone            | claude | manifest         | 21452/0/0     | 1270/0/0           | 36     | 106    |
| darwin   | clone            | claude | shadow           | 1264/0/20188  | 1264/0/6           | 277    | 623    |

## Harness-reported coverage per scenario (git scope, reported/true paths summed over reps)

| scenario                                            | darwin/clone/claude | darwin/clone/codex |
| --------------------------------------------------- | ------------------- | ------------------ |
| M01 three turns in one session                      | ✓ 4/4               | partial 2/4        |
| M01/t2 three turns in one session                   | ✓ 4/4               | ✗ 0/4              |
| M01/t3 three turns in one session                   | partial 2/3         | ✓ 2/2              |
| S01 edit tool modifies a tracked file               | ✓ 2/2               | ✓ 2/2              |
| S02 edit tool creates a file                        | ✓ 2/2               | ✓ 2/2              |
| S03 sed -i on a tracked file                        | ✓ 2/2               | ✗ 0/2              |
| S04 shell creates files                             | ✓ 4/4               | ✗ 0/4              |
| S05 rm a tracked file                               | ✓ 2/2               | ✗ 0/2              |
| S06 mv a tracked file                               | ✓ 4/4               | ✗ 0/4              |
| S07 mv a directory                                  | partial 400/800     | ✗ 0/800            |
| S08 chmod +x only                                   | ✓ 2/2               | ✗ 0/2              |
| S09 touch and identical rewrite (no net change)     | 0/0                 | 0/0                |
| S10 create and retarget symlinks                    | ✓ 4/4               | ✗ 0/4              |
| S11 1 MiB and 50 MiB binaries                       | ✓ 4/4               | ✗ 0/4              |
| S12 bulk in-place rewrite of 200 files              | ✓ 400/400           | ✗ 0/400            |
| S13 codegen into ignored gen/ and tracked api/      | ✓ 2/2               | ✗ 0/2              |
| S14 dependency install: 10k files into node_modules | 0/0                 | 0/0                |
| S15 edit ignored .env                               | 0/0                 | 0/0                |
| S16 agent commits, then edits again                 | ✓ 4/4               | ✗ 0/4              |
| S17 branch switch and stash round trip              | ✓ 2/2               | ✗ 0/2              |
| S18 case-only rename                                | partial 2/4         | ✗ 0/4              |
| S19 NFD and NFC filenames                           | ✓ 2/2               | ✗ 0/2              |
| S20 background writer after the turn                | 0/0                 | 0/0                |
| S21 writes outside the view                         | 0/0                 | 0/0                |
| S22 hard link                                       | ✓ 2/2               | ✗ 0/2              |
| S23 xattr-only change                               | ✗ 0/2               | ✗ 0/2              |
| S24 rm -rf ignored build/                           | 0/0                 | 0/0                |
| S25 busy turn: three edits and three shell commands | ✓ 12/12             | partial 6/12       |

## Late writes, escapes, git ops

- **darwin/clone/script**: S20 r1: late ['late.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']; S21 r1: escapes {'fsevents-escape': ['sentinel:escape.txt', 'source:escape-into-source.txt'], 'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r1: late ['late-m01.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']
- **darwin/clone-raw/script**: S20 r1: late ['late.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']; S21 r1: escapes {'fsevents-escape': ['sentinel:escape.txt', 'source:escape-into-source.txt'], 'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r1: late ['late-m01.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']
- **darwin/clone-worktree/script**: S20 r1: late ['late.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']; S21 r1: escapes {'fsevents-escape': ['sentinel:escape.txt', 'source:escape-into-source.txt'], 'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r1: late ['late-m01.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']
- **darwin/worktree-hydrate/script**: S20 r1: late ['late.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']; S21 r1: escapes {'fsevents-escape': ['sentinel:escape.txt', 'source:escape-into-source.txt'], 'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r1: late ['late-m01.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']
- **darwin/worktree/script**: S20 r1: late ['late.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']; S21 r1: escapes {'fsevents-escape': ['sentinel:escape.txt', 'source:escape-into-source.txt'], 'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r1: late ['late-m01.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']
- **darwin/clone/codex**: S21 r1: escapes {'fsevents-escape': ['sentinel:escape.txt', 'source:escape-into-source.txt'], 'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; S21 r2: escapes {'fsevents-escape': ['sentinel:escape.txt', 'source:escape-into-source.txt'], 'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}
- **darwin/clone/claude**: S20 r1: late ['late.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']; S21 r1: escapes {'fsevents-escape': ['sentinel:escape.txt', 'source:escape-into-source.txt'], 'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; S20 r2: late ['late.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']; S21 r2: escapes {'fsevents-escape': ['sentinel:escape.txt', 'source:escape-into-source.txt'], 'sentinel': ['escape.txt'], 'source': ['escape-into-source.txt']}; M01 r2: late ['late-m01.txt'] caught by ['clonescan', 'fsevents', 'manifest', 'shadow']

## Git-scope misses of the shadow snapshot

- **darwin/clone/script**: S18: ['README.md', 'Readme.md']; S23: ['docs/guide.md']
- **darwin/clone-raw/script**: S18: ['README.md', 'Readme.md']; S23: ['docs/guide.md']
- **darwin/clone-worktree/script**: S18: ['README.md', 'Readme.md']; S23: ['docs/guide.md']
- **darwin/worktree-hydrate/script**: S18: ['README.md', 'Readme.md']; S23: ['docs/guide.md']
- **darwin/worktree/script**: S18: ['README.md', 'Readme.md']; S23: ['docs/guide.md']
- **darwin/clone/codex**: S18: ['README.md', 'Readme.md']; S23: ['docs/guide.md']
- **darwin/clone/claude**: S18: ['README.md', 'Readme.md']; S23: ['docs/guide.md']

## View creation inside scenario runs (small fixture)

| platform | provider         | driver | create p50 ms | p95 ms |
| -------- | ---------------- | ------ | ------------- | ------ |
| darwin   | clone            | script | 214           | 486    |
| darwin   | clone-raw        | script | 97            | 106    |
| darwin   | clone-worktree   | script | 222           | 333    |
| darwin   | worktree-hydrate | script | 714           | 1307   |
| darwin   | worktree         | script | 718           | 5952   |
| darwin   | clone            | codex  | 227           | 428    |
| darwin   | clone            | claude | 235           | 417    |
