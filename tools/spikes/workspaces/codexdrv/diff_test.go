package codexdrv

import (
	"reflect"
	"testing"
)

func TestParseUnifiedDiffPaths(t *testing.T) {
	cases := []struct {
		name string
		diff string
		want []string
	}{
		{"empty", "", []string{}},
		{"modify", `diff --git a/src/main.go b/src/main.go
index 1111111..2222222 100644
--- a/src/main.go
+++ b/src/main.go
@@ -1,2 +1,2 @@
 package main
-var x = 1
+var x = 2
`, []string{"src/main.go"}},
		{"add and delete with dev null", `diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..587be6b
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+x
diff --git a/old.txt b/old.txt
deleted file mode 100644
index 587be6b..0000000
--- a/old.txt
+++ /dev/null
@@ -1 +0,0 @@
-x
`, []string{"new.txt", "old.txt"}},
		{"empty new file has header only", `diff --git a/empty b/empty
new file mode 100644
index 0000000..e69de29
`, []string{"empty"}},
		{"rename", `diff --git a/dir/old name.txt b/dir/new name.txt
similarity index 90%
rename from dir/old name.txt
rename to dir/new name.txt
index 1..2 100644
` + "--- a/dir/old name.txt\t\n+++ b/dir/new name.txt\t\n" + `@@ -1 +1 @@
-a
+b
`, []string{"dir/new name.txt", "dir/old name.txt"}},
		{"pure rename without hunks", `diff --git a/a.txt b/b.txt
similarity index 100%
rename from a.txt
rename to b.txt
`, []string{"a.txt", "b.txt"}},
		{"quoted paths", `diff --git "a/caf\303\251 \"q\".txt" "b/caf\303\251 \"q\".txt"
index 1..2 100644
--- "a/caf\303\251 \"q\".txt"
+++ "b/caf\303\251 \"q\".txt"
@@ -1 +1 @@
-a
+b
`, []string{`café "q".txt`}},
		{"mixed quoting in header", `diff --git a/plain.txt "b/tab\there.txt"
similarity index 100%
rename from plain.txt
rename to "tab\there.txt"
`, []string{"plain.txt", "tab\there.txt"}},
		{"unquoted spaces in header", `diff --git a/with space.txt b/with space.txt
old mode 100644
new mode 100755
`, []string{"with space.txt"}},
		{"hunk content that looks like headers", `diff --git a/q.sql b/q.sql
--- a/q.sql
+++ b/q.sql
@@ -1,3 +1,3 @@
--- not a header
+++ not a header either
 keep
-x
+y
`, []string{"q.sql"}},
		{"binary", `diff --git a/img.png b/img.png
index 1..2 100644
Binary files a/img.png and b/img.png differ
`, []string{"img.png"}},
		{"plain unified diff with timestamps", `--- old/file.txt	2026-10-21 08:00:00.000000000 +0200
+++ new/file.txt	2026-10-21 08:01:00.000000000 +0200
@@ -1 +1 @@
-a
+b
`, []string{"new/file.txt", "old/file.txt"}},
		{"plain unified diff with a/ b/ prefixes", `--- a/x.txt
+++ b/x.txt
@@ -1 +1 @@
-a
+b
`, []string{"x.txt"}},
		{"absolute paths outside a repo", `diff --git a//tmp/out/f.txt b//tmp/out/f.txt
--- a//tmp/out/f.txt
+++ b//tmp/out/f.txt
@@ -1 +1 @@
-a
+b
`, []string{"/tmp/out/f.txt"}},
		{"no newline marker and crlf", "diff --git a/w.txt b/w.txt\r\n--- a/w.txt\r\n+++ b/w.txt\r\n@@ -1 +1 @@\r\n-a\r\n\\ No newline at end of file\r\n+b\r\n\\ No newline at end of file\r\n", []string{"w.txt"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ParseUnifiedDiffPaths(tc.diff)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestUnquoteC(t *testing.T) {
	v, n := unquoteC(`"a\\b\"c\303\251\n" rest`)
	if v != "a\\b\"cé\n" || n != len(`"a\\b\"c\303\251\n"`) {
		t.Fatalf("got %q %d", v, n)
	}
	if _, n := unquoteC(`"unterminated`); n != 0 {
		t.Fatalf("unterminated accepted")
	}
}
