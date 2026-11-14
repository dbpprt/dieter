// Package scenarios is the spike's catalog of scripted agent turns. Each
// scenario stresses one way an agent can change files. Edit steps replace
// whole lines because Codex's patch tool rejects partial-line context.
package scenarios

import (
	"fmt"
	"runtime"

	"dieter.spike/workspaces/core"
)

// Env carries the absolute paths a scenario may reference.
type Env struct {
	GOOS     string // "darwin" or "linux"; default runtime.GOOS
	Source   string // the operator checkout the view was created from
	Sentinel string // a spike-owned directory outside every view
	Tmp      string // spike-owned scratch directory
	Assets   string // fixture assets (dep.tgz)
}

// Scenario is one or more scripted turns in a fresh view.
type Scenario struct {
	ID    string
	Title string
	Turns [][]core.Step
	// Late marks scenarios that leave a background writer behind.
	Late bool
	// Escape marks scenarios that write outside the view on purpose.
	Escape bool
}

func edit(path, old, new string) core.Step {
	return core.Step{Tool: "edit", Path: path, Old: old, New: new}
}

func create(path, content string) core.Step {
	return core.Step{Tool: "edit", Path: path, Create: true, Content: content}
}

func sh(cmd string) core.Step { return core.Step{Tool: "shell", Command: cmd} }

// All returns the catalog for env.
func All(env Env) []Scenario {
	goos := env.GOOS
	if goos == "" {
		goos = runtime.GOOS
	}
	sedI := "sed -i ''"
	xattr := "xattr -w com.dieter.spike yes docs/guide.md"
	nfd := `python3 -c "open('docs/Café.txt','w').write('nfd\n')" && python3 -c "open('docs/Café.txt','a').write('nfc\n')"`
	if goos == "linux" {
		sedI = "sed -i"
		xattr = "setfattr -n user.spike -v yes docs/guide.md"
		// Linux keeps both spellings as separate names; create only NFD.
		nfd = `python3 -c "open('docs/Café.txt','w').write('nfd\n')"`
	}
	return []Scenario{
		{ID: "S01", Title: "edit tool modifies a tracked file", Turns: [][]core.Step{{
			edit("docs/guide.md", "Guide version: 1", "Guide version: 2")}}},
		{ID: "S02", Title: "edit tool creates a file", Turns: [][]core.Step{{
			create("docs/new-page.md", "# New page\n\nCreated by the edit tool.\n")}}},
		{ID: "S03", Title: "sed -i on a tracked file", Turns: [][]core.Step{{
			sh(sedI + ` 's/const Greeting = "hello"/const Greeting = "hi"/' src/app/main.go`)}}},
		{ID: "S04", Title: "shell creates files", Turns: [][]core.Step{{
			sh(`mkdir -p notes && printf 'from shell\n' > notes/shell.txt && python3 -c "open('notes/py.txt','w').write('from python\n')"`)}}},
		{ID: "S05", Title: "rm a tracked file", Turns: [][]core.Step{{sh("rm Makefile")}}},
		{ID: "S06", Title: "mv a tracked file", Turns: [][]core.Step{{sh("mv src/app/util.go src/app/helpers.go")}}},
		{ID: "S07", Title: "mv a directory", Turns: [][]core.Step{{sh("mv src/lib src/library")}}},
		{ID: "S08", Title: "chmod +x only", Turns: [][]core.Step{{sh("chmod +x docs/guide.md")}}},
		{ID: "S09", Title: "touch and identical rewrite (no net change)", Turns: [][]core.Step{{
			sh(fmt.Sprintf("touch docs/guide.md && cp src/app/util.go %s/util.copy && cat %s/util.copy > src/app/util.go", env.Tmp, env.Tmp))}}},
		{ID: "S10", Title: "create and retarget symlinks", Turns: [][]core.Step{{
			sh("ln -s docs/guide.md guide-link && ln -sfn Makefile link-to-readme")}}},
		{ID: "S11", Title: "1 MiB and 50 MiB binaries", Turns: [][]core.Step{{
			sh("dd if=/dev/urandom of=assets/blob1m.bin bs=1048576 count=1 2>/dev/null && dd if=/dev/urandom of=assets/blob50m.bin bs=1048576 count=50 2>/dev/null")}}},
		{ID: "S12", Title: "bulk in-place rewrite of 200 files", Turns: [][]core.Step{{
			sh("perl -pi -e 's/OLD_TOKEN/NEW_TOKEN/g' src/lib/*")}}},
		{ID: "S13", Title: "codegen into ignored gen/ and tracked api/", Turns: [][]core.Step{{sh("sh scripts/gen.sh")}}},
		{ID: "S14", Title: "dependency install: 10k files into node_modules", Turns: [][]core.Step{{
			sh(fmt.Sprintf("mkdir -p node_modules && tar -xzf %s/dep.tgz -C node_modules", env.Assets))}}},
		{ID: "S15", Title: "edit ignored .env", Turns: [][]core.Step{{sh("printf 'API_KEY=rotated-not-a-secret\\n' > .env")}}},
		{ID: "S16", Title: "agent commits, then edits again", Turns: [][]core.Step{{
			sh("printf 'commit me\\n' >> Readme.md && git commit -qam 'agent commit' && printf 'after commit\\n' >> docs/guide.md")}}},
		{ID: "S17", Title: "branch switch and stash round trip", Turns: [][]core.Step{{
			sh("git checkout -q -b spike-x && printf 'stash me\\n' >> Readme.md && git stash -q && git stash pop -q")}}},
		{ID: "S18", Title: "case-only rename", Turns: [][]core.Step{{sh("mv Readme.md README.md")}}},
		{ID: "S19", Title: "NFD and NFC filenames", Turns: [][]core.Step{{sh(nfd)}}},
		{ID: "S20", Title: "background writer after the turn", Late: true, Turns: [][]core.Step{{
			sh("(sleep 5; printf 'late\\n' > late.txt) >/dev/null 2>&1 &")}}},
		{ID: "S21", Title: "writes outside the view", Escape: true, Turns: [][]core.Step{{
			sh(fmt.Sprintf("printf 'escaped\\n' > %s/escape.txt && printf 'escaped\\n' > %s/escape-into-source.txt", env.Sentinel, env.Source))}}},
		{ID: "S22", Title: "hard link", Turns: [][]core.Step{{sh("ln docs/guide.md docs/guide-hardlink.md")}}},
		{ID: "S23", Title: "xattr-only change", Turns: [][]core.Step{{sh(xattr)}}},
		{ID: "S24", Title: "rm -rf ignored build/", Turns: [][]core.Step{{sh("rm -rf build")}}},
		{ID: "S25", Title: "busy turn: three edits and three shell commands", Turns: [][]core.Step{{
			edit("src/app/main.go", `const Greeting = "hello"`, `const Greeting = "howdy"`),
			sh("printf 'one\\n' > busy-1.txt"),
			create("docs/busy.md", "busy\n"),
			sh("rm api/schema.json"),
			edit("Readme.md", "Project readme", "Project readme (busy)"),
			sh(sedI + " 's/Guide version: 1/Guide version: 3/' docs/guide.md"),
		}}},
		{ID: "M01", Title: "three turns in one session", Late: true, Turns: [][]core.Step{
			{edit("docs/guide.md", "Guide version: 1", "Guide version: 2"), sh("printf 'turn one\\n' > turn1.txt")},
			{sh("rm Makefile && sh scripts/gen.sh")},
			{create("turn3.md", "turn three\n"), sh("(sleep 5; printf 'late\\n' > late-m01.txt) >/dev/null 2>&1 &")},
		}},
	}
}

// Select returns the scenarios whose IDs are listed (all when ids is empty).
func Select(all []Scenario, ids map[string]bool) []Scenario {
	if len(ids) == 0 {
		return all
	}
	var out []Scenario
	for _, s := range all {
		if ids[s.ID] {
			out = append(out, s)
		}
	}
	return out
}
