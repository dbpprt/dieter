## E1 view cost (median of runs, ms)

| platform | fixture | provider         | create | first git status | second status | discard | free-space delta MB |
| -------- | ------- | ---------------- | ------ | ---------------- | ------------- | ------- | ------------------- |
| linux    | small   | btrfs            | 3      | 12               | 2             | 27      | 0.0                 |
| linux    | small   | overlay          | 0      | 8                | 1             | 0       | 0.0                 |
| linux    | small   | reflink          | 41     | 11               | 2             | 25      | 0.0                 |
| linux    | small   | worktree         | 14     | 6                | 5             | 8       | 0.0                 |
| linux    | small   | worktree-hydrate | 50     | 6                | 5             | 25      | 0.0                 |
| linux    | js      | btrfs            | 4      | 52               | 3             | 470     | 0.0                 |
| linux    | js      | overlay          | 0      | 31               | 2             | 0       | 0.0                 |
| linux    | js      | reflink          | 586    | 44               | 3             | 388     | 0.0                 |
| linux    | js      | worktree         | 57     | 20               | 21            | 33      | 0.0                 |
| linux    | js      | worktree-hydrate | 670    | 22               | 22            | 402     | 0.0                 |
| linux    | huge    | btrfs            | 13     | 47               | 22            | 1909    | 0.0                 |
| linux    | huge    | overlay          | 0      | 52               | 2             | 0       | 0.0                 |
| linux    | huge    | reflink          | 1838   | 415              | 21            | 1246    | 0.0                 |
| linux    | huge    | worktree         | 621    | 181              | 128           | 334     | 0.1                 |
| linux    | huge    | worktree-hydrate | 1938   | 190              | 23            | 1200    | 0.0                 |

## E6 recorder cost per mark (median ms) by modified tracked files

| platform | fixture | provider | recorder | 0 files | 10 files | 100 files | 789 files | 1000 files |
| -------- | ------- | -------- | -------- | ------- | -------- | --------- | --------- | ---------- |
| linux    | small   | btrfs    | manifest | 3       | 3        | 3         | 3         | –          |
| linux    | small   | btrfs    | shadow   | 3       | 5        | 9         | 29        | –          |
| linux    | small   | overlay  | shadow   | 4       | 18       | –         | –         | –          |
| linux    | small   | overlay  | upper    | 0       | 0        | –         | –         | –          |
| linux    | js      | btrfs    | manifest | 46      | 45       | 47        | –         | 45         |
| linux    | js      | btrfs    | shadow   | 5       | 9        | 13        | –         | 51         |
| linux    | js      | overlay  | shadow   | 5       | 13       | 18        | –         | 84         |
| linux    | js      | overlay  | upper    | 0       | 0        | 1         | –         | 12         |
| linux    | huge    | btrfs    | manifest | 145     | 134      | 121       | –         | 117        |
| linux    | huge    | btrfs    | shadow   | 18      | 39       | 41        | –         | 81         |
| linux    | huge    | overlay  | shadow   | 23      | 49       | 77        | –         | 349        |
| linux    | huge    | overlay  | upper    | 0       | 0        | 1         | –         | 8          |
