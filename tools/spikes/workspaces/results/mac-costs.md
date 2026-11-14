## E1 view cost (median of runs, ms)

| platform | fixture | provider         | create | first git status | second status | discard | free-space delta MB |
| -------- | ------- | ---------------- | ------ | ---------------- | ------------- | ------- | ------------------- |
| darwin   | small   | clone            | 203    | 75               | 58            | 791     | 1.0                 |
| darwin   | small   | clone-cp         | 2316   | 66               | 55            | 720     | 1.4                 |
| darwin   | small   | clone-raw        | 105    | 319              | 60            | 664     | 1.0                 |
| darwin   | small   | clone-worktree   | 229    | 311              | 62            | 697     | 1.0                 |
| darwin   | small   | worktree         | 793    | 173              | 165           | 328     | 4.5                 |
| darwin   | small   | worktree-hydrate | 861    | 148              | 99            | 1022    | 5.2                 |
| darwin   | js      | clone            | 1859   | 116              | 74            | 11336   | 16.1                |
| darwin   | js      | clone-raw        | 1685   | 1338             | 78            | 10758   | 16.9                |
| darwin   | js      | clone-worktree   | 1823   | 1181             | 70            | 11393   | 17.2                |
| darwin   | js      | worktree         | 1721   | 233              | 129           | 845     | 22.0                |
| darwin   | js      | worktree-hydrate | 3637   | 219              | 73            | 11040   | 36.1                |
| darwin   | huge    | clone            | 9488   | 851              | 310           | 40685   | 51.9                |
| darwin   | huge    | clone-raw        | 7522   | 13963            | 293           | 34558   | 51.7                |
| darwin   | huge    | clone-worktree   | 7758   | 11540            | 301           | 36379   | 50.7                |
| darwin   | huge    | worktree         | 16716  | 446              | 269           | 8674    | 220.1               |
| darwin   | huge    | worktree-hydrate | 23550  | 485              | 249           | 36704   | 256.9               |

## E6 recorder cost per mark (median ms) by modified tracked files

| platform | fixture | provider | recorder  | 0 files | 10 files | 100 files | 789 files | 1000 files |
| -------- | ------- | -------- | --------- | ------- | -------- | --------- | --------- | ---------- |
| darwin   | small   | clone    | clonescan | 18      | 16       | 14        | 19        | –          |
| darwin   | small   | clone    | fsevents  | 80      | 70       | 211       | 98        | –          |
| darwin   | small   | clone    | manifest  | 30      | 21       | 24        | 43        | –          |
| darwin   | small   | clone    | shadow    | 202     | 232      | 448       | 2475      | –          |
| darwin   | js      | clone    | clonescan | 347     | 326      | 452       | –         | 475        |
| darwin   | js      | clone    | fsevents  | 115     | 211      | 72        | –         | 103        |
| darwin   | js      | clone    | manifest  | 490     | 547      | 677       | –         | 711        |
| darwin   | js      | clone    | shadow    | 239     | 275      | 517       | –         | 3290       |
| darwin   | huge    | clone    | clonescan | 1008    | 850      | 1157      | –         | 950        |
| darwin   | huge    | clone    | fsevents  | 211     | 72       | 71        | –         | 96         |
| darwin   | huge    | clone    | manifest  | 1494    | 1305     | 1585      | –         | 1425       |
| darwin   | huge    | clone    | shadow    | 495     | 565      | 909       | –         | 3083       |
