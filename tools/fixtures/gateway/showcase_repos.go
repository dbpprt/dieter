package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Showcase repositories are small but real: the Go service builds and its
// tests pass, so the terminal and Git surfaces show genuine output.

type repoCommit struct {
	message string
	ago     time.Duration
	files   map[string]string
}

// createShowcaseRepo commits history with backdated dates, then leaves
// pending as uncommitted work in the checkout.
func createShowcaseRepo(ctx context.Context, dir string, commits []repoCommit, pending map[string]string) error {
	if err := showcaseGit(ctx, "", time.Time{}, "init", "-b", "main", dir); err != nil {
		return err
	}
	for _, commit := range commits {
		if err := writeRepoFiles(dir, commit.files); err != nil {
			return err
		}
		at := time.Now().Add(-commit.ago)
		if err := showcaseGit(ctx, dir, at, "add", "-A"); err != nil {
			return err
		}
		if err := showcaseGit(ctx, dir, at, "-c", "commit.gpgsign=false", "commit", "-q", "-m", commit.message); err != nil {
			return err
		}
	}
	return writeRepoFiles(dir, pending)
}

func showcaseGit(ctx context.Context, dir string, at time.Time, args ...string) error {
	if dir != "" {
		args = append([]string{"-C", dir}, args...)
	}
	process := exec.CommandContext(ctx, "git", args...)
	environment := append(isolatedGitEnvironment(os.Environ()), "GIT_AUTHOR_NAME=Alex Morgan", "GIT_AUTHOR_EMAIL=alex@example.com", "GIT_COMMITTER_NAME=Alex Morgan", "GIT_COMMITTER_EMAIL=alex@example.com")
	if !at.IsZero() {
		stamp := at.Format(time.RFC3339)
		environment = append(environment, "GIT_AUTHOR_DATE="+stamp, "GIT_COMMITTER_DATE="+stamp)
	}
	process.Env = environment
	if output, err := process.CombinedOutput(); err != nil {
		return fmt.Errorf("git %s: %s: %w", strings.Join(args, " "), output, err)
	}
	return nil
}

func writeRepoFiles(dir string, files map[string]string) error {
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		path := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, []byte(strings.TrimLeft(files[name], "\n")), 0o644); err != nil {
			return err
		}
	}
	return nil
}

const day = 24 * time.Hour

var atlasCommits = []repoCommit{
	{"Initial Atlas API service", 41 * day, map[string]string{
		"go.mod": "module example.com/atlas\n\ngo 1.26\n",
		"README.md": `
# Atlas API

The public API behind Atlas: search, webhooks and billing for every workspace.

| Command | What it does |
| --- | --- |
| ` + "`make run`" + ` | Start the API on :8080 |
| ` + "`make test`" + ` | Unit tests with the race detector |
| ` + "`make test-integration`" + ` | Tests against a disposable Postgres |

See [docs/architecture.md](docs/architecture.md) for how requests flow.
`,
		"Makefile": "run:\n\tgo run ./cmd/atlas\n\ntest:\n\tgo test -race ./...\n\ntest-integration:\n\tgo test -tags integration ./...\n",
		"cmd/atlas/main.go": `
package main

import (
	"log/slog"
	"net/http"
	"os"

	"example.com/atlas/internal/httpapi"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	router := httpapi.NewRouter(httpapi.Dependencies{Logger: logger})
	logger.Info("atlas listening", "addr", ":8080")
	if err := http.ListenAndServe(":8080", router); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}
`,
		"internal/httpapi/router.go": `
// Package httpapi serves the public Atlas API.
package httpapi

import (
	"log/slog"
	"net/http"
)

// Dependencies are the services the router mounts.
type Dependencies struct {
	Logger *slog.Logger
}

// NewRouter returns the public API handler.
func NewRouter(deps Dependencies) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /v2/search", search)
	return mux
}

func search(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("q") == "" {
		WriteProblem(w, Problem{Type: "https://atlas.example.com/problems/missing-query", Title: "Missing query", Status: http.StatusBadRequest, Detail: "Pass a search term in q."})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(` + "`" + `{"results":[]}` + "`" + `))
}
`,
	}},
	{"Add the v2 search index", 30 * day, map[string]string{
		"internal/search/index.go": `
// Package search keeps an in-memory inverted index of workspace documents.
package search

import (
	"sort"
	"strings"
)

// Document is one searchable record.
type Document struct {
	ID, Title, Body string
}

// Index maps lowercase terms to document IDs.
type Index struct {
	terms map[string]map[string]struct{}
}

// Build indexes every word of each document's title and body.
func Build(docs []Document) *Index {
	index := &Index{terms: map[string]map[string]struct{}{}}
	for _, doc := range docs {
		for _, word := range strings.Fields(strings.ToLower(doc.Title + " " + doc.Body)) {
			word = strings.Trim(word, ".,:;!?()")
			if index.terms[word] == nil {
				index.terms[word] = map[string]struct{}{}
			}
			index.terms[word][doc.ID] = struct{}{}
		}
	}
	return index
}

// Search returns the IDs of documents that contain every term, sorted.
func (i *Index) Search(query string) []string {
	var result map[string]struct{}
	for _, term := range strings.Fields(strings.ToLower(query)) {
		matches := i.terms[term]
		if result == nil {
			result = map[string]struct{}{}
			for id := range matches {
				result[id] = struct{}{}
			}
			continue
		}
		for id := range result {
			if _, ok := matches[id]; !ok {
				delete(result, id)
			}
		}
	}
	ids := make([]string, 0, len(result))
	for id := range result {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}
`,
		"internal/search/index_test.go": `
package search

import (
	"slices"
	"testing"
)

func TestSearchMatchesEveryTerm(t *testing.T) {
	index := Build([]Document{
		{ID: "a", Title: "Webhook retries", Body: "Retries use exponential backoff."},
		{ID: "b", Title: "Rate limits", Body: "Limits apply per API key."},
		{ID: "c", Title: "Webhook signing", Body: "Signatures use HMAC with a per key secret."},
	})
	if got := index.Search("webhook key"); !slices.Equal(got, []string{"c"}) {
		t.Fatalf("Search() = %v", got)
	}
}

func TestSearchIsCaseInsensitive(t *testing.T) {
	index := Build([]Document{{ID: "a", Title: "Billing", Body: "Invoices"}})
	if got := index.Search("BILLING"); !slices.Equal(got, []string{"a"}) {
		t.Fatalf("Search() = %v", got)
	}
}
`,
	}},
	{"Return RFC 9457 problem details", 19 * day, map[string]string{
		"internal/httpapi/problem.go": `
package httpapi

import (
	"encoding/json"
	"net/http"
)

// Problem is an RFC 9457 problem details response.
type Problem struct {
	Type   string ` + "`json:\"type\"`" + `
	Title  string ` + "`json:\"title\"`" + `
	Status int    ` + "`json:\"status\"`" + `
	Detail string ` + "`json:\"detail,omitempty\"`" + `
}

// WriteProblem writes p as application/problem+json.
func WriteProblem(w http.ResponseWriter, p Problem) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(p.Status)
	_ = json.NewEncoder(w).Encode(p)
}
`,
		"internal/httpapi/problem_test.go": `
package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestMissingQueryReturnsProblem(t *testing.T) {
	recorder := httptest.NewRecorder()
	NewRouter(Dependencies{}).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/v2/search", nil))
	if recorder.Code != http.StatusBadRequest || recorder.Header().Get("Content-Type") != "application/problem+json" {
		t.Fatalf("status %d, content type %q", recorder.Code, recorder.Header().Get("Content-Type"))
	}
	var problem Problem
	if err := json.NewDecoder(recorder.Body).Decode(&problem); err != nil || problem.Title != "Missing query" {
		t.Fatalf("problem %+v, error %v", problem, err)
	}
}
`,
	}},
	{"Add a fixed-rate limiter for the public API", 9 * day, map[string]string{
		"internal/ratelimit/limiter.go": `
// Package ratelimit implements token buckets for the public API.
package ratelimit

import (
	"sync"
	"time"
)

// Limiter allows a fixed number of requests per minute across all callers.
type Limiter struct {
	mu        sync.Mutex
	perMinute int
	tokens    float64
	last      time.Time
}

// New returns a limiter with a full bucket.
func New(perMinute int) *Limiter {
	return &Limiter{perMinute: perMinute, tokens: float64(perMinute), last: time.Now()}
}

// Allow takes one token if one is available.
func (l *Limiter) Allow() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	l.tokens = min(float64(l.perMinute), l.tokens+now.Sub(l.last).Minutes()*float64(l.perMinute))
	l.last = now
	if l.tokens < 1 {
		return false
	}
	l.tokens--
	return true
}
`,
		"docs/architecture.md": `
# Architecture

Requests pass through a small middleware chain before they reach a handler.

1. **Request ID** tags every log line and response.
2. **Logging** writes one structured line per request with ` + "`slog`" + `.
3. **Authentication** resolves the API key and its workspace.
4. **Handlers** return JSON, or RFC 9457 problem details on errors.

Search runs against an in-memory index that is rebuilt from Postgres every
five minutes. Webhooks are delivered by a separate worker with exponential
backoff.
`,
	}},
	{"Document webhook retries and signing", 2 * day, map[string]string{
		"docs/webhooks.md": `
# Webhooks

Atlas signs every delivery with HMAC-SHA256. Verify the ` + "`Atlas-Signature`" + `
header before trusting a payload.

| Attempt | Delay |
| --- | ---: |
| 1 | immediately |
| 2 | 30 s |
| 3 | 5 min |
| 4 | 30 min |
| 5 | 2 h |

After the fifth failure the endpoint is paused and the workspace owner is
notified.
`,
	}},
}

// The per-key limiter is the live rate-limiting task's uncommitted work.
var atlasPending = map[string]string{
	"internal/ratelimit/limiter.go": `
// Package ratelimit implements per-key token buckets for the public API.
package ratelimit

import (
	"sync"
	"time"
)

// Limit is the sustained rate and burst of one API key.
type Limit struct {
	PerMinute int
	Burst     int
}

type bucket struct {
	tokens float64
	last   time.Time
}

// Limiter keeps one token bucket per API key, sized by the key's plan.
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	limits  func(key string) Limit
	now     func() time.Time
}

// New returns a limiter that sizes each key's bucket with limits.
func New(limits func(key string) Limit) *Limiter {
	return &Limiter{buckets: map[string]*bucket{}, limits: limits, now: time.Now}
}

// Allow takes one token for key. When the bucket is empty it also reports
// how long the caller should wait before retrying.
func (l *Limiter) Allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	limit := l.limits(key)
	rate := float64(limit.PerMinute) / 60
	now := l.now()
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: float64(limit.Burst), last: now}
		l.buckets[key] = b
	}
	b.tokens = min(float64(limit.Burst), b.tokens+now.Sub(b.last).Seconds()*rate)
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	return false, time.Duration((1 - b.tokens) / rate * float64(time.Second))
}
`,
	"internal/ratelimit/limiter_test.go": `
package ratelimit

import (
	"testing"
	"time"
)

func fixed(limit Limit) func(string) Limit { return func(string) Limit { return limit } }

func TestBucketAllowsBurst(t *testing.T) {
	limiter := New(fixed(Limit{PerMinute: 60, Burst: 3}))
	for range 3 {
		if ok, _ := limiter.Allow("key"); !ok {
			t.Fatal("burst request rejected")
		}
	}
	if ok, wait := limiter.Allow("key"); ok || wait <= 0 {
		t.Fatalf("fourth request allowed=%v wait=%v", ok, wait)
	}
}

func TestBucketRefills(t *testing.T) {
	now := time.Unix(0, 0)
	limiter := New(fixed(Limit{PerMinute: 60, Burst: 1}))
	limiter.now = func() time.Time { return now }
	limiter.Allow("key")
	now = now.Add(time.Second)
	if ok, _ := limiter.Allow("key"); !ok {
		t.Fatal("bucket did not refill after one second")
	}
}

func TestKeysAreIndependent(t *testing.T) {
	limiter := New(fixed(Limit{PerMinute: 60, Burst: 1}))
	limiter.Allow("team")
	if ok, _ := limiter.Allow("scale"); !ok {
		t.Fatal("one key throttled another")
	}
}

func TestRetryAfterMatchesRate(t *testing.T) {
	limiter := New(fixed(Limit{PerMinute: 30, Burst: 1}))
	limiter.now = func() time.Time { return time.Unix(0, 0) }
	limiter.Allow("key")
	if _, wait := limiter.Allow("key"); wait != 2*time.Second {
		t.Fatalf("wait = %v, want 2s", wait)
	}
}
`,
	"internal/httpapi/ratelimit.go": `
package httpapi

import (
	"math"
	"net/http"
	"strconv"

	"example.com/atlas/internal/ratelimit"
)

// WithRateLimit rejects requests whose API key has no tokens left.
func WithRateLimit(limiter *ratelimit.Limiter, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("Atlas-Key")
		if ok, wait := limiter.Allow(key); !ok {
			w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(wait.Seconds()))))
			WriteProblem(w, Problem{Type: "https://atlas.example.com/problems/rate-limited", Title: "Too many requests", Status: http.StatusTooManyRequests, Detail: "This API key is over its plan's rate limit."})
			return
		}
		next.ServeHTTP(w, r)
	})
}
`,
	"docs/rate-limits.md": `
# Rate limits

Every API key has its own token bucket. The bucket's size and refill rate
come from the workspace plan, so one busy integration never slows down
another.

| Plan | Requests per minute | Burst |
| --- | ---: | ---: |
| Free | 60 | 20 |
| Team | 600 | 120 |
| Scale | 3,000 | 600 |

## When you hit the limit

Atlas answers with ` + "`429 Too Many Requests`" + ` and an RFC 9457 problem
document. The ` + "`Retry-After`" + ` header says how many seconds to wait:

` + "```http" + `
HTTP/1.1 429 Too Many Requests
Content-Type: application/problem+json
Retry-After: 2

{
  "type": "https://atlas.example.com/problems/rate-limited",
  "title": "Too many requests",
  "status": 429
}
` + "```" + `

The official SDKs retry automatically with jitter. If you call the API
directly, wait at least ` + "`Retry-After`" + ` seconds and add a random delay.

## Raising a limit

Scale workspaces can request a custom limit from **Settings → API keys**.
Limits change within a minute and never reset an existing bucket.
`,
}

// The home machine's clone carries the session migration in progress.
var atlasMiniPending = map[string]string{
	"migrations/0042_sessions.sql": `
CREATE TABLE sessions (
  id text PRIMARY KEY,
  user_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  scopes text[] NOT NULL,
  csrf_token text NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE INDEX sessions_expires_at ON sessions (expires_at);
`,
	"internal/session/store.go": `
// Package session stores authenticated web sessions.
package session

import (
	"context"
	"time"
)

// Session is one signed-in browser.
type Session struct {
	ID, UserID, TenantID, CSRFToken string
	Scopes                          []string
	ExpiresAt                       time.Time
}

// Store persists sessions.
type Store interface {
	Get(ctx context.Context, id string) (Session, error)
	Put(ctx context.Context, s Session) error
	Delete(ctx context.Context, id string) error
}
`,
}

var storefrontCommits = []repoCommit{
	{"Bootstrap the storefront", 60 * day, map[string]string{
		"package.json": `
{
  "name": "storefront",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "test": "vitest run",
    "e2e": "playwright test"
  },
  "dependencies": {
    "next": "16.0.3",
    "react": "19.2.0",
    "react-dom": "19.2.0"
  },
  "devDependencies": {
    "@playwright/test": "1.56.1",
    "typescript": "5.9.3",
    "vitest": "4.0.8"
  }
}
`,
		"README.md":    "# Storefront\n\nThe web shop: catalog, cart and checkout. `pnpm dev` starts it on :3000.\n",
		"app/page.tsx": "import { FeaturedGrid } from \"@/components/FeaturedGrid\";\n\nexport default function Home() {\n  return <FeaturedGrid />;\n}\n",
	}},
	{"Checkout with saved addresses", 12 * day, map[string]string{
		"components/CartSummary.tsx": `
import { LineItem } from "./LineItem";
import type { Cart } from "@/lib/cart";

type Props = { cart: Cart };

export function CartSummary({ cart }: Props) {
  return (
    <section aria-labelledby="summary">
      <h2 id="summary">Order summary</h2>
      {cart.items.map((item) => <LineItem key={item.id} item={item} />)}
      <dl>
        <dt>Subtotal</dt>
        <dd>{cart.subtotal}</dd>
        <dt>Shipping</dt>
        <dd>{cart.shipping}</dd>
      </dl>
    </section>
  );
}
`,
		"app/checkout/page.tsx": "import { CartSummary } from \"@/components/CartSummary\";\nimport { getCart } from \"@/lib/cart\";\n\nexport default async function Checkout() {\n  const cart = await getCart();\n  return <CartSummary cart={cart} />;\n}\n",
	}},
}

// The live checkout-summary task's uncommitted work.
var storefrontPending = map[string]string{
	"components/CartSummary.tsx": `
import { ShipmentGroup } from "./ShipmentGroup";
import type { Cart } from "@/lib/cart";

type Props = { cart: Cart };

export function CartSummary({ cart }: Props) {
  return (
    <section aria-labelledby="summary">
      <h2 id="summary">Order summary</h2>
      {cart.shipments.map((shipment, index) => (
        <ShipmentGroup
          key={shipment.id}
          shipment={shipment}
          position={index + 1}
          total={cart.shipments.length}
        />
      ))}
      <dl>
        <dt>Subtotal</dt>
        <dd>{cart.subtotal}</dd>
        <dt>Shipping</dt>
        <dd>{cart.shipping}</dd>
      </dl>
    </section>
  );
}
`,
	"components/ShipmentGroup.tsx": `
import { LineItem } from "./LineItem";
import { formatDelivery } from "@/lib/delivery";
import type { Shipment } from "@/lib/cart";

type Props = { shipment: Shipment; position: number; total: number };

export function ShipmentGroup({ shipment, position, total }: Props) {
  const heading = ` + "`Shipment ${position} of ${total}, arrives ${formatDelivery(shipment.estimate)}`" + `;
  return (
    <section aria-label={heading} className="shipment">
      <header>
        <h3>{shipment.carrier}</h3>
        <p className="estimate">{formatDelivery(shipment.estimate)}</p>
      </header>
      <ul>
        {shipment.items.map((item) => (
          <li key={item.id}>
            <LineItem item={item} />
          </li>
        ))}
      </ul>
    </section>
  );
}
`,
}

var pocketCommits = []repoCommit{
	{"Pocket 2.3", 34 * day, map[string]string{
		"README.md":    "# Pocket\n\nOffline-first notes for Android and iOS, one Kotlin Multiplatform core.\n",
		"CHANGELOG.md": "# Changelog\n\n## 2.3.0\n\n- Pin notes to the top of a notebook.\n- Faster search on large notebooks.\n",
		"shared/src/commonMain/kotlin/pocket/sync/SyncEngine.kt": "package pocket.sync\n\n/** Merges local edits with the server using last-writer-wins per field. */\nclass SyncEngine(private val api: SyncApi, private val store: NoteStore) {\n    suspend fun sync() {\n        val changes = store.pendingChanges()\n        val merged = api.push(changes)\n        store.apply(merged)\n    }\n}\n",
	}},
	{"Resolve sync conflicts per field", 3 * day, map[string]string{
		"shared/src/commonMain/kotlin/pocket/sync/Conflicts.kt": "package pocket.sync\n\n/** Keeps the newest value of each field when two devices edit one note. */\nfun merge(local: Note, remote: Note): Note =\n    local.copy(\n        title = if (local.titleEditedAt > remote.titleEditedAt) local.title else remote.title,\n        body = if (local.bodyEditedAt > remote.bodyEditedAt) local.body else remote.body,\n    )\n",
	}},
}

var homelabCommits = []repoCommit{
	{"k3s cluster on two Mac minis and the NAS", 90 * day, map[string]string{
		"README.md":                       "# Homelab\n\nk3s on `mini-1`, `mini-2` and the NAS. Ansible provisions the nodes; Flux deploys the apps.\n",
		"ansible/site.yml":                "- hosts: k3s\n  become: true\n  roles:\n    - common\n    - k3s\n",
		"apps/home-assistant/values.yaml": "image:\n  tag: \"2026.10.1\"\npersistence:\n  config:\n    existingClaim: home-assistant-config\nnodeSelector:\n  kubernetes.io/hostname: mini-1\n",
	}},
	{"Nightly restic backups to the NAS", 6 * day, map[string]string{
		"apps/backups/cronjob.yaml": "apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: restic\nspec:\n  schedule: \"0 3 * * *\"\n",
	}},
}
