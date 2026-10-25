An [inline link](https://example.com/docs) and one [with a title](https://example.com "Title").

A [link with **bold**](https://example.com/a) and [nested [brackets]](https://example.com/b).

Autolinks: <https://example.com/auto>, <mailto:ops@example.com> and <ops@example.com>.

Bare addresses: https://example.com/path?q=1, localhost:8080/health and (https://example.com/x).

Bold address: **https://example.com/bold** and a sentence ending in https://example.com/end.

Workspace links: [README.md](README.md), [line 12](src/app.kt#L12) and [a file](file:///work/repo/notes.md).

[Angle destination](<docs/My File.md>) and [empty]() and [not a link] (missing).

An image: ![Build graph](https://example.com/graph.png) is never fetched.

Raw HTML stays text: <b>bold</b> and <img src="x.png">.
