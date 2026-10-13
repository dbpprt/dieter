package main

import "time"

// The showcase workspace: what a week of agent work across two machines looks
// like. Titles, prompts and answers are written like real tasks; nothing here
// describes Dieter itself.

const (
	showcaseOffice = "Office mini"
	showcaseHome   = "Home mini"
	showcaseLaptop = "MacBook Pro"
)

type showcaseTool struct {
	name          string
	input         map[string]any
	output        string
	commandOutput bool
}

func read(path, output string) showcaseTool {
	return showcaseTool{name: "read", input: map[string]any{"path": path}, output: output}
}

func grep(pattern, output string) showcaseTool {
	return showcaseTool{name: "grep", input: map[string]any{"pattern": pattern}, output: output}
}

func edit(path, summary string) showcaseTool {
	return showcaseTool{name: "edit", input: map[string]any{"path": path}, output: summary}
}

func sh(command, output string) showcaseTool {
	return showcaseTool{name: "bash", input: map[string]any{"command": command}, output: output, commandOutput: true}
}

// showcaseExchange is one completed turn: the user's message, the agent's
// reasoning and tools, and its answer.
type showcaseExchange struct {
	prompt, reasoning, answer string
	tools                     []showcaseTool
	tokens                    int
}

type showcaseCard struct {
	title, lane, machine    string
	provider, model, effort string
	labels                  []string
	ago                     time.Duration
	summary                 string
	exchanges               []showcaseExchange
	live                    string // a showcaseLiveTurns key
	unread, pinned          bool
}

var (
	codex  = [3]string{"codex", "gpt-5.6-sol", "high"}
	codexT = [3]string{"codex", "gpt-5.6-terra", "medium"}
	opus   = [3]string{"claude-code", "opus", "high"}
	sonnet = [3]string{"claude-code", "sonnet", "medium"}
	pi     = [3]string{"pi", "default", "medium"}
)

func agent(card showcaseCard, choice [3]string) showcaseCard {
	card.provider, card.model, card.effort = choice[0], choice[1], choice[2]
	return card
}

type showcaseLabel struct{ name, color string }

type showcaseBoard struct {
	project, name string
	labels        []showcaseLabel
	cards         []showcaseCard
}

var atlasBoard = showcaseBoard{project: "Atlas API", name: "Roadmap", labels: []showcaseLabel{
	{"API", "#3b82f6"}, {"Performance", "#f59e0b"}, {"Security", "#ef4444"}, {"Docs", "#8b5cf6"}, {"Bug", "#ec4899"},
}, cards: []showcaseCard{
	agent(showcaseCard{title: "Add OpenAPI examples for the billing endpoints", lane: "todo", machine: showcaseOffice, labels: []string{"Docs"}, ago: 26 * time.Hour,
		exchanges: []showcaseExchange{{prompt: "Add request and response examples to every billing endpoint in openapi.yaml, generated from the integration test fixtures."}}}, sonnet),
	agent(showcaseCard{title: "Rotate webhook signing secrets without downtime", lane: "todo", machine: showcaseHome, labels: []string{"Security"}, ago: 2 * day,
		exchanges: []showcaseExchange{{prompt: "Support two active signing secrets per endpoint so customers can rotate without dropping deliveries."}}}, opus),
	agent(showcaseCard{title: "Paginate the audit log export", lane: "todo", machine: showcaseOffice, labels: []string{"API"}, ago: 3 * day,
		exchanges: []showcaseExchange{{prompt: "The audit log CSV export times out for large workspaces. Stream it with cursor pagination."}}}, codexT),
	agent(showcaseCard{title: "Investigate the p99 spike on /v2/search", lane: "todo", machine: showcaseHome, labels: []string{"Performance"}, ago: 5 * time.Hour,
		exchanges: []showcaseExchange{{prompt: "p99 on /v2/search jumped from 80 ms to 400 ms after Tuesday's deploy. Find out why."}}}, codex),

	agent(showcaseCard{title: "Add per-key rate limiting to the public API", lane: "running", machine: showcaseOffice, labels: []string{"API", "Performance"}, live: "rate-limits",
		summary: "Running the race tests across the limiter and the HTTP middleware."}, codex),
	agent(showcaseCard{title: "Migrate session storage to Postgres 17", lane: "running", machine: showcaseHome, labels: []string{"API"}, live: "postgres-sessions",
		summary: "Running the integration suite against Postgres 17."}, opus),
	agent(showcaseCard{title: "Upgrade to Go 1.26 and refresh dependencies", lane: "running", machine: showcaseOffice, live: "go-upgrade",
		summary: "Running the full test suite with the race detector."}, codex),
	agent(showcaseCard{title: "Fix flaky TestWebhookRetry under -race", lane: "running", machine: showcaseHome, labels: []string{"Bug"}, ago: 14 * time.Minute, unread: true,
		summary: "Found the race. Needs a decision on the retry clock.",
		exchanges: []showcaseExchange{{
			prompt:    "TestWebhookRetry fails about one run in twenty with -race. Find the cause and fix it.",
			reasoning: "A one-in-twenty failure under -race usually means a data race on shared state or a timing assumption. I'll run it many times with the race detector first.",
			tools: []showcaseTool{
				sh("go test -race -run TestWebhookRetry -count=200 ./internal/webhooks/", "--- FAIL: TestWebhookRetry (0.31s)\n    retry_test.go:58: delivery 3 sent after 29.98s, want >= 30s\nWARNING: DATA RACE\nWrite at 0x00c0001a40f8 by goroutine 41:\n  example.com/atlas/internal/webhooks.(*Retrier).schedule()\n      retry.go:74 +0x1c4\nFAIL\tok 191, failed 9"),
				read("internal/webhooks/retry.go", "func (r *Retrier) schedule(d Delivery) {\n\tr.next = time.Now().Add(r.backoff(d.Attempt))\n\tgo r.wait(d)\n}"),
			},
			answer: "Found it. `Retrier.schedule` writes `r.next` from the delivery goroutine while `wait` reads it, and the test compares against the wall clock, so a slow scheduler makes the 30 s backoff look like 29.98 s.\n\nTwo ways to fix it:\n\n1. **Inject a fake clock** into `Retrier` and advance it in the test. Deterministic and fast, but it touches the constructor used in four places.\n2. **Keep the real clock** and only fix the race with a mutex, then allow 50 ms of slack in the assertion.\n\nI'd go with **option 1**. Which do you prefer?",
			tokens: 38200,
		}}}, pi),

	agent(showcaseCard{title: "Return RFC 9457 problem details from every handler", lane: "review", machine: showcaseOffice, labels: []string{"API"}, ago: 47 * time.Minute, unread: true,
		summary: "Every handler now returns application/problem+json on errors. 31 tests pass.",
		exchanges: []showcaseExchange{{
			prompt:    "Make every error response an RFC 9457 problem document. Keep the existing error codes as the type URIs.",
			reasoning: "Handlers write errors three different ways today: http.Error, a JSON helper and a few hand-written bodies. One WriteProblem helper and a lint rule against http.Error will keep it consistent.",
			tools: []showcaseTool{
				grep("http.Error\\(", "internal/httpapi/billing.go:44\ninternal/httpapi/billing.go:91\ninternal/httpapi/keys.go:37\ninternal/httpapi/search.go:22\ninternal/httpapi/webhooks.go:68"),
				edit("internal/httpapi/problem.go", "Created internal/httpapi/problem.go (+24)"),
				edit("internal/httpapi/billing.go", "Updated internal/httpapi/billing.go (+8 −6)"),
				sh("go test ./internal/httpapi/...", "ok  \texample.com/atlas/internal/httpapi\t0.412s"),
			},
			answer: "Every handler now returns `application/problem+json` on errors.\n\n- Added `WriteProblem` and a `Problem` type in `internal/httpapi/problem.go`.\n- Replaced all **11** `http.Error` calls; the old error codes became type URIs like `https://atlas.example.com/problems/missing-query`.\n- Added a `forbidigo` rule so new code can't call `http.Error` again.\n\n```json\n{\n  \"type\": \"https://atlas.example.com/problems/missing-query\",\n  \"title\": \"Missing query\",\n  \"status\": 400\n}\n```\n\n31 tests pass. Ready for review.",
			tokens: 61400,
		}}}, codex),
	agent(showcaseCard{title: "Cache tenant lookups in the auth middleware", lane: "review", machine: showcaseHome, labels: []string{"Performance"}, ago: 3 * time.Hour,
		summary: "Tenant lookups are cached for 60 s. Auth p50 dropped from 4.1 ms to 0.3 ms.",
		exchanges: []showcaseExchange{{
			prompt:    "Every request hits Postgres to load the tenant in the auth middleware. Cache it safely.",
			reasoning: "Tenants change rarely, but a suspended tenant must lose access quickly. A short TTL plus explicit invalidation on suspension covers both.",
			tools: []showcaseTool{
				read("internal/auth/middleware.go", "tenant, err := m.tenants.Get(r.Context(), key.TenantID)"),
				edit("internal/auth/tenant_cache.go", "Created internal/auth/tenant_cache.go (+58)"),
				sh("go test -bench=BenchmarkAuth -benchmem ./internal/auth/", "BenchmarkAuth/uncached-12   \t  290112\t      4127 ns/op\nBenchmarkAuth/cached-12     \t 3871204\t       309 ns/op"),
			},
			answer: "Tenant lookups are now cached for **60 seconds**, and suspending a tenant evicts it immediately through the existing `tenant.suspended` event.\n\n| | p50 | Allocations |\n| --- | ---: | ---: |\n| Before | 4.1 ms | 38 |\n| After | 0.3 ms | 4 |\n\nThe cache is bounded at 10,000 tenants with LRU eviction.",
			tokens: 44800,
		}}}, opus),
	agent(showcaseCard{title: "Write the self-hosting guide", lane: "review", machine: showcaseOffice, labels: []string{"Docs"}, ago: 20 * time.Hour,
		summary: "Draft covers Docker Compose, Postgres and TLS. Linked from the README.",
		exchanges: []showcaseExchange{{
			prompt:    "Write docs/self-hosting.md: Docker Compose, Postgres, TLS and upgrades.",
			reasoning: "The guide should work from a fresh VPS. I'll follow the steps in a scratch directory to make sure every command runs.",
			tools: []showcaseTool{
				sh("docker compose -f deploy/compose.yaml config --quiet && echo valid", "valid"),
				edit("docs/self-hosting.md", "Created docs/self-hosting.md (+142)"),
			},
			answer: "The draft is in `docs/self-hosting.md` and linked from the README. It covers Compose, managed or bundled Postgres, TLS with Caddy, and zero-downtime upgrades.",
			tokens: 27300,
		}}}, sonnet),

	agent(showcaseCard{title: "Add structured request logging with slog", lane: "done", machine: showcaseOffice, ago: 2 * day,
		summary: "One JSON log line per request with the request ID, key and latency.",
		exchanges: []showcaseExchange{{prompt: "Replace the ad hoc log.Printf calls with structured slog logging, one line per request.", reasoning: "A middleware can log once per request with the request ID that is already in the context.",
			tools:  []showcaseTool{edit("internal/httpapi/logging.go", "Created internal/httpapi/logging.go (+46)"), sh("go test ./...", "ok  \texample.com/atlas/internal/httpapi\t0.388s\nok  \texample.com/atlas/internal/search\t0.112s")},
			answer: "Requests now log one JSON line each with `request_id`, `key`, `status` and `duration_ms`. All `log.Printf` calls are gone.", tokens: 22100}}}, codexT),
	agent(showcaseCard{title: "Ship the v2 search endpoint", lane: "done", machine: showcaseHome, labels: []string{"API"}, ago: 3 * day,
		summary: "GET /v2/search is live behind the index with tests.",
		exchanges: []showcaseExchange{{prompt: "Expose the new search index as GET /v2/search with pagination.", reasoning: "The index is already built; the endpoint only needs query parsing and a cursor.",
			tools:  []showcaseTool{edit("internal/httpapi/search.go", "Created internal/httpapi/search.go (+71)"), sh("go test ./internal/...", "ok  \texample.com/atlas/internal/httpapi\t0.402s\nok  \texample.com/atlas/internal/search\t0.109s")},
			answer: "`GET /v2/search?q=…&cursor=…` is live with tests for empty, multi-term and paginated queries.", tokens: 35600}}}, opus),
	agent(showcaseCard{title: "Harden CORS defaults", lane: "done", machine: showcaseOffice, labels: []string{"Security"}, ago: 4 * day,
		summary: "Only configured origins are allowed; credentials are never sent to wildcards.",
		exchanges: []showcaseExchange{{prompt: "Our CORS middleware reflects any Origin. Lock it down.", reasoning: "Reflecting Origin with credentials is effectively a wildcard with cookies. An allowlist from config fixes it.",
			tools:  []showcaseTool{edit("internal/httpapi/cors.go", "Updated internal/httpapi/cors.go (+19 −12)"), sh("go test ./internal/httpapi/ -run CORS", "ok  \texample.com/atlas/internal/httpapi\t0.091s")},
			answer: "CORS now allows only origins from `ATLAS_ALLOWED_ORIGINS` and never combines credentials with a wildcard.", tokens: 18900}}}, codex),
	agent(showcaseCard{title: "Remove the legacy v1 auth flow", lane: "done", machine: showcaseHome, labels: []string{"Security"}, ago: 6 * day,
		summary: "v1 tokens are gone; 1,200 lines removed.",
		exchanges: []showcaseExchange{{prompt: "No customer has used v1 tokens in 90 days. Remove the flow and its tables.", reasoning: "I'll confirm usage from the metrics export first, then remove code, routes and the migration.",
			tools:  []showcaseTool{grep("v1token", "internal/auth/v1.go\ninternal/auth/v1_test.go\nmigrations/0007_v1_tokens.sql"), sh("go build ./... && go test ./...", "ok  \texample.com/atlas/internal/auth\t0.233s")},
			answer: "Removed the v1 token flow, its routes and tests, and added migration `0043` to drop the table. **1,204 lines** deleted.", tokens: 31700}}}, pi),
}}

var storefrontBoard = showcaseBoard{project: "Storefront", name: "Sprint 42", labels: []showcaseLabel{
	{"Checkout", "#10b981"}, {"UI", "#6366f1"}, {"Accessibility", "#f59e0b"},
}, cards: []showcaseCard{
	agent(showcaseCard{title: "Redesign the checkout summary", lane: "running", machine: showcaseOffice, labels: []string{"Checkout", "UI"}, live: "checkout-summary",
		summary: "Running the Playwright checkout flow."}, sonnet),
	agent(showcaseCard{title: "Add Apple Pay to checkout", lane: "todo", machine: showcaseOffice, labels: []string{"Checkout"}, ago: 30 * time.Hour,
		exchanges: []showcaseExchange{{prompt: "Offer Apple Pay through the payment request API when the browser supports it."}}}, codex),
	agent(showcaseCard{title: "Lazy-load product images below the fold", lane: "review", machine: showcaseOffice, labels: []string{"UI"}, ago: 5 * time.Hour,
		summary: "LCP improved from 2.8 s to 1.6 s on the category page.",
		exchanges: []showcaseExchange{{prompt: "Category pages load every product image up front. Lazy-load what's below the fold.", reasoning: "next/image already supports lazy loading; the grid passes priority to every item.",
			tools:  []showcaseTool{edit("components/ProductGrid.tsx", "Updated components/ProductGrid.tsx (+4 −2)"), sh("pnpm lighthouse /category/shoes --only=performance", "Largest Contentful Paint  1.6 s\nTotal Blocking Time       90 ms\nPerformance               96")},
			answer: "Only the first row gets `priority` now. **LCP 2.8 s → 1.6 s** on the shoes category, performance score 96.", tokens: 21400}}}, codex),
	agent(showcaseCard{title: "Fix focus order in the address form", lane: "done", machine: showcaseOffice, labels: []string{"Accessibility"}, ago: 2 * day,
		summary: "Tab order follows the visual order; errors are announced.",
		exchanges: []showcaseExchange{{prompt: "Keyboard users jump from postcode to the submit button. Fix the focus order.", reasoning: "A CSS grid reorder moved city visually but not in the DOM.",
			tools:  []showcaseTool{edit("components/AddressForm.tsx", "Updated components/AddressForm.tsx (+12 −10)")},
			answer: "The DOM order now matches the layout, and validation errors use `aria-describedby` so they are announced.", tokens: 15800}}}, sonnet),
}}

var pocketBoard = showcaseBoard{project: "Pocket", name: "Release 2.4", labels: []showcaseLabel{
	{"Android", "#22c55e"}, {"iOS", "#64748b"}, {"Sync", "#0ea5e9"},
}, cards: []showcaseCard{
	agent(showcaseCard{title: "Offline drafts survive app restarts", lane: "review", machine: showcaseOffice, labels: []string{"Sync"}, ago: 7 * time.Hour,
		summary: "Drafts persist to SQLite and resync on launch.",
		exchanges: []showcaseExchange{{prompt: "Unsent edits are lost if the app is killed offline. Persist them.", reasoning: "Pending changes live in memory in SyncEngine. Writing them through the existing SQLDelight store keeps one source of truth.",
			tools:  []showcaseTool{read("shared/src/commonMain/kotlin/pocket/sync/SyncEngine.kt", "val changes = store.pendingChanges()"), sh("./gradlew :shared:allTests", "BUILD SUCCESSFUL in 41s\n128 tests completed")},
			answer: "Pending edits are written to SQLite before they're sent and replayed on the next launch. 128 shared tests pass on JVM, Android and iOS.", tokens: 40200}}}, codex),
	agent(showcaseCard{title: "Widgets for pinned notes", lane: "todo", machine: showcaseOffice, labels: []string{"Android", "iOS"}, ago: 4 * day,
		exchanges: []showcaseExchange{{prompt: "Add home screen widgets that show pinned notes on both platforms."}}}, opus),
	agent(showcaseCard{title: "Crash when rotating during note export", lane: "done", machine: showcaseOffice, labels: []string{"Android"}, ago: 3 * day,
		summary: "Export survives configuration changes.",
		exchanges: []showcaseExchange{{prompt: "Fix the crash when the device rotates while exporting a note to PDF.", reasoning: "The export job holds an Activity reference that is gone after rotation.",
			tools:  []showcaseTool{edit("androidApp/src/main/kotlin/pocket/export/ExportViewModel.kt", "Updated ExportViewModel.kt (+18 −9)")},
			answer: "Export now runs in the ViewModel scope and survives rotation.", tokens: 19700}}}, codexT),
}}

var homelabBoard = showcaseBoard{project: "Homelab", name: "Ops", labels: []showcaseLabel{{"Cluster", "#14b8a6"}, {"Backups", "#a855f7"}}, cards: []showcaseCard{
	agent(showcaseCard{title: "Verify last night's restic backup", lane: "done", machine: showcaseHome, labels: []string{"Backups"}, ago: 6 * time.Hour,
		summary: "Snapshot 4f2a91c restored to a scratch volume and checked.",
		exchanges: []showcaseExchange{{prompt: "Check that last night's restic snapshot restores cleanly.", reasoning: "A real restore into a scratch volume is the only meaningful check.",
			tools:  []showcaseTool{sh("restic snapshots --latest 1", "ID        Time                 Host    Tags\n4f2a91c3  2026-10-13 03:00:12  mini-1  nightly"), sh("restic restore 4f2a91c3 --target /tmp/restore-check --verify", "verifying files in /tmp/restore-check\nfinished verifying 18342 files, 21.7 GiB in 4:12")},
			answer: "Snapshot `4f2a91c3` restored and verified: **18,342 files, 21.7 GiB**, no errors.", tokens: 12600}}}, sonnet),
	agent(showcaseCard{title: "Move Home Assistant to mini-2", lane: "todo", machine: showcaseHome, labels: []string{"Cluster"}, ago: 9 * time.Hour,
		exchanges: []showcaseExchange{{prompt: "Pin Home Assistant to mini-2 so mini-1 can be drained for upgrades."}}}, opus),
}}

// Standalone chats keyed by project.
var showcaseChats = []struct {
	project string
	card    showcaseCard
}{
	{"Atlas API", agent(showcaseCard{title: "Why is the search index rebuild slow?", machine: showcaseOffice, ago: 35 * time.Minute, unread: true, pinned: true,
		summary: "The rebuild reads every document twice. A single pass halves it.",
		exchanges: []showcaseExchange{{prompt: "The search index rebuild takes 40 seconds now. Why?", reasoning: "I'll profile the rebuild before guessing.",
			tools:  []showcaseTool{sh("go test -run XXX -bench BenchmarkBuild -cpuprofile cpu.out ./internal/search/ && go tool pprof -top cpu.out | head -6", "flat  flat%   sum%   cum   cum%\n4.81s 41.2% 41.2% 4.81s 41.2%  strings.ToLower\n2.97s 25.4% 66.6% 7.78s 66.6%  strings.Fields\n1.12s  9.6% 76.2% 1.12s  9.6%  runtime.mapassign_faststr")},
			answer: "Most of the time goes to lowercasing and splitting text, twice per document: once for the title and once for the body, and then again for the combined string.\n\n**Fix:** tokenize once with a reusable `strings.Builder` and lowercase per word. In the benchmark that takes the rebuild from **40 s to 17 s**. Want me to open a task for it?", tokens: 26300}}}, opus)},
	{"Atlas API", agent(showcaseCard{title: "Compare Postgres connection poolers", machine: showcaseHome, ago: 2 * day,
		summary: "PgBouncer in transaction mode fits; pgcat only if we shard.",
		exchanges: []showcaseExchange{{prompt: "PgBouncer, pgcat or Supavisor for Atlas? We run two API replicas and one Postgres 17 primary.", reasoning: "With one primary and short transactions the main question is prepared statement support in transaction mode.",
			answer: "For two replicas and one primary, **PgBouncer 1.24 in transaction mode** is the simplest fit. It now supports protocol-level prepared statements, which pgx uses.\n\n| | PgBouncer | pgcat | Supavisor |\n| --- | --- | --- | --- |\n| Prepared statements | Yes | Yes | Yes |\n| Sharding | No | Yes | No |\n| Ops overhead | Low | Medium | High |\n\nRevisit pgcat if you shard by tenant.", tokens: 14100}}}, pi)},
	{"Pocket", agent(showcaseCard{title: "Draft the 2.4 release notes", machine: showcaseOffice, ago: 25 * time.Minute, unread: true,
		summary: "Draft ready; asks whether to headline the sync fix.",
		exchanges: []showcaseExchange{{prompt: "Draft the 2.4 release notes from the merged changes since 2.3.", reasoning: "I'll read the changelog and the merged commits since the 2.3 tag.",
			tools:  []showcaseTool{sh("git log --oneline v2.3.0..main", "b41e2d0 Resolve sync conflicts per field\n8c7a1f3 Persist offline drafts\n2d9e6b4 Fix crash when rotating during export")},
			answer: "## Pocket 2.4\n\n- **Edits never get lost.** Notes you change offline are saved and sent when you're back online.\n- **Smarter sync.** When two devices edit the same note, Pocket keeps the newest title and body separately.\n- Fixed a crash when rotating your phone during a PDF export.\n\nShould the sync change be the headline, or the offline drafts?", tokens: 9800}}}, codex)},
	{"Homelab", agent(showcaseCard{title: "Plan the k3s 1.34 upgrade", machine: showcaseHome, live: "k3s-upgrade",
		summary: "Checking workloads for deprecated APIs."}, opus)},
	{"Storefront", agent(showcaseCard{title: "Plan the holiday sale banner", machine: showcaseOffice, ago: 28 * time.Hour,
		summary: "One dismissible banner, scheduled by a feature flag.",
		exchanges: []showcaseExchange{{prompt: "We need a holiday sale banner from Nov 28 to Dec 2. What's the least risky way?",
			answer: "Use one dismissible banner component behind the existing `holiday_sale` flag with a start and end time. That keeps the deploy independent of the sale and lets you end it early without a release.", tokens: 6400}}}, sonnet)},
}

var showcaseSchedules = []struct {
	project, board, name, description, cron, action, title, prompt string
	agent                                                          [3]string
	enabled                                                        bool
}{
	{"Atlas API", "Roadmap", "Nightly dependency audit", "Check for vulnerable or outdated modules", "0 2 * * *", "run", "Dependency audit {{date}}", "Run govulncheck and list outdated modules. Open a task for anything with a known vulnerability.", codexT, true},
	{"Atlas API", "Roadmap", "Morning triage", "Summarize new issues and failing checks", "30 8 * * 1-5", "draft", "Triage {{date}}", "Summarize new issues, failing CI runs and anything waiting for review.", sonnet, true},
	{"Pocket", "Release 2.4", "Weekly release notes", "Draft notes from merged changes", "0 16 * * 5", "draft", "Release notes {{date}}", "Draft release notes from everything merged this week.", codex, true},
}
