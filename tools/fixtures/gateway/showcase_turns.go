package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
)

// Showcase turns replay a believable agent run through the real daemon turn
// pipeline: reasoning, tool calls, a task plan, subagents and streamed text.
// They then hold a long-running command open, so screenshots show live work.
// No provider is contacted; the scripts only run in the showcase fixture.

// showcaseLiveTurn is a running conversation the fixture starts after both
// machines are online. Prompt is sent as the user's message; Key selects the
// script below.
type showcaseLiveTurn struct {
	Key, Prompt string
	Script      func(*showcaseStream) error
}

var showcaseLiveTurns = map[string]showcaseLiveTurn{
	"rate-limits": {
		Key:    "per-key rate limiting",
		Prompt: "Add per-key rate limiting to the public API. Use a token bucket per API key, return 429 with Retry-After, and make the limits configurable per plan.",
		Script: rateLimitTurn,
	},
	"postgres-sessions": {
		Key:    "session storage from Redis to Postgres 17",
		Prompt: "Move session storage from Redis to Postgres 17. Keep the existing session API, add a migration, and clean up expired sessions.",
		Script: postgresSessionsTurn,
	},
	"go-upgrade": {
		Key:    "module to Go 1.26",
		Prompt: "Upgrade the module to Go 1.26, refresh dependencies and fix anything vet or the tests flag.",
		Script: goUpgradeTurn,
	},
	"checkout-summary": {
		Key:    "Redesign the checkout summary",
		Prompt: "Redesign the checkout summary: group line items by shipment, show the delivery estimate, and keep it accessible.",
		Script: checkoutSummaryTurn,
	},
	"k3s-upgrade": {
		Key:    "upgrade our k3s cluster",
		Prompt: "What's the safest way to upgrade our k3s cluster from 1.32 to 1.34 without taking Home Assistant down?",
		Script: k3sUpgradeTurn,
	},
}

// showcaseScript returns the scripted turn for a showcase prompt, if any.
func showcaseScript(request harness.Request) func(*showcaseStream) error {
	for _, turn := range showcaseLiveTurns {
		if strings.Contains(request.Prompt, turn.Key) {
			return turn.Script
		}
	}
	return nil
}

func runShowcaseTurn(ctx context.Context, request harness.Request, emit func(harness.Output) error, script func(*showcaseStream) error) error {
	stream := &showcaseStream{ctx: ctx, emit: emit, request: request, beat: time.Now()}
	if err := stream.chunk(map[string]any{"type": "start", "messageId": request.ResponseMessageID, "messageMetadata": map[string]any{"createdAt": time.Now().UTC().Format(time.RFC3339Nano)}}); err != nil {
		return err
	}
	if err := stream.chunk(map[string]any{"type": "start-step"}); err != nil {
		return err
	}
	return script(stream)
}

type showcaseStream struct {
	ctx      context.Context
	emit     func(harness.Output) error
	request  harness.Request
	tools    int
	parts    int
	revision int
	beat     time.Time
}

type planTask struct{ content, status string }

func (s *showcaseStream) chunk(value map[string]any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return s.emit(harness.Output{Type: "chunk", Chunk: raw})
}

// pause waits like a working agent and keeps the worker heartbeat alive.
func (s *showcaseStream) pause(duration time.Duration) error {
	deadline := time.Now().Add(duration)
	for {
		if time.Since(s.beat) > 10*time.Second {
			if err := s.emit(harness.Output{Type: "heartbeat"}); err != nil {
				return err
			}
			s.beat = time.Now()
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil
		}
		timer := time.NewTimer(min(remaining, 2*time.Second))
		select {
		case <-s.ctx.Done():
			timer.Stop()
			return s.ctx.Err()
		case <-timer.C:
		}
	}
}

// streamPart writes text or reasoning a few words at a time.
func (s *showcaseStream) streamPart(kind, text string, perWord time.Duration) error {
	s.parts++
	id := fmt.Sprintf("%s-%d", kind, s.parts)
	if err := s.chunk(map[string]any{"type": kind + "-start", "id": id}); err != nil {
		return err
	}
	words := strings.SplitAfter(text, " ")
	for start := 0; start < len(words); start += 4 {
		end := min(start+4, len(words))
		if err := s.chunk(map[string]any{"type": kind + "-delta", "id": id, "delta": strings.Join(words[start:end], "")}); err != nil {
			return err
		}
		if err := s.pause(perWord * time.Duration(end-start)); err != nil {
			return err
		}
	}
	return s.chunk(map[string]any{"type": kind + "-end", "id": id})
}

func (s *showcaseStream) think(text string) error {
	return s.streamPart("reasoning", text, 40*time.Millisecond)
}

func (s *showcaseStream) say(text string) error {
	return s.streamPart("text", text, 70*time.Millisecond)
}

func (s *showcaseStream) toolCall(name string, input any) (string, error) {
	s.tools++
	id := fmt.Sprintf("call_%s_%d", strings.ToLower(name), s.tools)
	return id, s.chunk(map[string]any{"type": "tool-input-available", "toolCallId": id, "toolName": name, "input": input})
}

func (s *showcaseStream) tool(name string, input, output any, duration time.Duration) error {
	id, err := s.toolCall(name, input)
	if err != nil {
		return err
	}
	if err = s.pause(duration); err != nil {
		return err
	}
	return s.chunk(map[string]any{"type": "tool-output-available", "toolCallId": id, "output": output})
}

func (s *showcaseStream) shell(command, output string, duration time.Duration) error {
	return s.tool("bash", map[string]any{"command": command}, map[string]any{"exitCode": 0, "output": output}, duration)
}

// hold starts a long-running command and keeps the turn live until the fixture stops.
func (s *showcaseStream) hold(command string) error {
	if _, err := s.toolCall("bash", map[string]any{"command": command}); err != nil {
		return err
	}
	return s.pause(24 * time.Hour)
}

func (s *showcaseStream) plan(tasks ...planTask) error {
	s.revision++
	phase := make([]map[string]any, len(tasks))
	for index, task := range tasks {
		phase[index] = map[string]any{"content": task.content, "status": task.status, "order": index}
	}
	return s.capability(map[string]any{"id": "task-plan", "operation": "replace", "plan": map[string]any{
		"id": s.request.Harness + ":" + s.request.ResponseMessageID, "provider": s.request.Harness, "messageId": s.request.ResponseMessageID,
		"revision": s.revision, "state": "active", "phases": []map[string]any{{"name": "", "tasks": phase}},
		"updatedAt": time.Now().UTC().Format(time.RFC3339Nano),
	}})
}

func (s *showcaseStream) subagent(id, name, agentType, status, activity string, tokens int, output ...string) error {
	return s.capability(map[string]any{"id": "subagents", "operation": "upsert", "subagent": map[string]any{
		"id": id, "provider": s.request.Harness, "messageId": s.request.ResponseMessageID, "name": name, "agentType": agentType,
		"status": status, "activity": activity, "tokens": tokens, "recentOutput": output,
	}})
}

func (s *showcaseStream) capability(value map[string]any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return s.emit(harness.Output{Type: "capability", Capability: raw})
}

func rateLimitTurn(s *showcaseStream) error {
	steps := []func() error{
		func() error {
			return s.plan(planTask{"Read the middleware chain and API key resolution", "in_progress"}, planTask{"Add a token bucket per API key", "pending"},
				planTask{"Return 429 with Retry-After and RateLimit headers", "pending"}, planTask{"Make limits configurable per plan", "pending"}, planTask{"Run the race tests", "pending"})
		},
		func() error {
			return s.think("The public router mounts middleware in internal/httpapi/router.go. API keys are resolved by WithAuth before handlers run, so the limiter can key off the authenticated key instead of the client IP. That also keeps customers behind one NAT from throttling each other.")
		},
		func() error {
			return s.tool("read", map[string]any{"path": "internal/httpapi/router.go"}, map[string]any{"output": "func NewRouter(deps Dependencies) http.Handler {\n\tmux := http.NewServeMux()\n\tmux.Handle(\"GET /v2/search\", deps.Search)\n\tmux.Handle(\"POST /v2/webhooks\", deps.Webhooks)\n\treturn WithRequestID(WithLogging(WithAuth(deps.Keys, mux)))\n}"}, 1200*time.Millisecond)
		},
		func() error {
			return s.tool("grep", map[string]any{"pattern": "Plan\\b", "path": "internal"}, map[string]any{"output": "internal/billing/plan.go:12:type Plan struct {\ninternal/auth/keys.go:31:\tPlan billing.Plan\ninternal/auth/keys.go:58:func (k Key) Plan() billing.Plan {"}, 900*time.Millisecond)
		},
		func() error {
			return s.plan(planTask{"Read the middleware chain and API key resolution", "completed"}, planTask{"Add a token bucket per API key", "in_progress"},
				planTask{"Return 429 with Retry-After and RateLimit headers", "pending"}, planTask{"Make limits configurable per plan", "pending"}, planTask{"Run the race tests", "pending"})
		},
		func() error {
			return s.tool("edit", map[string]any{"path": "internal/ratelimit/limiter.go", "old_string": "type Limiter struct {\n\tmu      sync.Mutex\n\tbuckets map[string]*bucket\n}", "new_string": "type Limiter struct {\n\tmu      sync.Mutex\n\tbuckets map[string]*bucket\n\tlimits  func(key string) Limit\n\tnow     func() time.Time\n}"}, map[string]any{"output": "Updated internal/ratelimit/limiter.go (+38 −6)"}, 1500*time.Millisecond)
		},
		func() error {
			return s.tool("edit", map[string]any{"path": "internal/httpapi/middleware.go", "old_string": "return WithRequestID(WithLogging(WithAuth(deps.Keys, mux)))", "new_string": "return WithRequestID(WithLogging(WithAuth(deps.Keys, WithRateLimit(deps.Limiter, mux))))"}, map[string]any{"output": "Updated internal/httpapi/middleware.go (+29)"}, 1300*time.Millisecond)
		},
		func() error {
			return s.plan(planTask{"Read the middleware chain and API key resolution", "completed"}, planTask{"Add a token bucket per API key", "completed"},
				planTask{"Return 429 with Retry-After and RateLimit headers", "completed"}, planTask{"Make limits configurable per plan", "in_progress"}, planTask{"Run the race tests", "pending"})
		},
		func() error {
			return s.shell("go test ./internal/ratelimit/ -run TestBucket -count=1", "ok  \texample.com/atlas/internal/ratelimit\t0.214s", 2500*time.Millisecond)
		},
		func() error {
			return s.say("Each API key now gets its own token bucket, sized by the key's plan:\n\n| Plan | Requests / min | Burst |\n| --- | ---: | ---: |\n| Free | 60 | 20 |\n| Team | 600 | 120 |\n| Scale | 3,000 | 600 |\n\nRejected requests return `429 Too Many Requests` with `Retry-After` and the draft `RateLimit` headers, so SDKs can back off without guessing. Next I'm running the race tests across the limiter and the HTTP middleware.")
		},
		func() error {
			return s.plan(planTask{"Read the middleware chain and API key resolution", "completed"}, planTask{"Add a token bucket per API key", "completed"},
				planTask{"Return 429 with Retry-After and RateLimit headers", "completed"}, planTask{"Make limits configurable per plan", "completed"}, planTask{"Run the race tests", "in_progress"})
		},
		func() error { return s.hold("go test -race -count=1 ./internal/ratelimit/... ./internal/httpapi/...") },
	}
	return s.run(steps, 900*time.Millisecond)
}

func postgresSessionsTurn(s *showcaseStream) error {
	steps := []func() error{
		func() error {
			return s.plan(planTask{"Map the Redis session payload", "in_progress"}, planTask{"Write the 0042 sessions migration", "pending"},
				planTask{"Implement the Postgres session store", "pending"}, planTask{"Sweep expired sessions", "pending"}, planTask{"Run integration tests on Postgres 17", "pending"})
		},
		func() error {
			return s.think("Sessions are read on every authenticated request, so the Postgres store needs a primary-key lookup and an index on expires_at for the sweeper. I'll ask a subagent to compare the Redis payload with the columns while I read the store interface.")
		},
		func() error {
			return s.subagent("schema-scout", "Schema scout", "Explore", "running", "Comparing the Redis session payload with the planned columns", 18400,
				"sessions:{id} stores user_id, tenant_id, scopes and a 30 day TTL", "csrf_token is only read by the web handlers")
		},
		func() error {
			return s.tool("Read", map[string]any{"file_path": "internal/session/store.go"}, map[string]any{"output": "type Store interface {\n\tGet(ctx context.Context, id string) (Session, error)\n\tPut(ctx context.Context, s Session) error\n\tDelete(ctx context.Context, id string) error\n}"}, 1100*time.Millisecond)
		},
		func() error {
			return s.tool("Write", map[string]any{"file_path": "migrations/0042_sessions.sql", "content": "CREATE TABLE sessions (\n  id text PRIMARY KEY,\n  user_id uuid NOT NULL,\n  tenant_id uuid NOT NULL,\n  scopes text[] NOT NULL,\n  csrf_token text NOT NULL,\n  expires_at timestamptz NOT NULL\n);\nCREATE INDEX sessions_expires_at ON sessions (expires_at);"}, map[string]any{"output": "Created migrations/0042_sessions.sql"}, 1400*time.Millisecond)
		},
		func() error {
			return s.subagent("schema-scout", "Schema scout", "Explore", "completed", "Payload and columns match", 23100,
				"All six fields map to columns", "TTL becomes expires_at; no data needs backfilling")
		},
		func() error {
			return s.plan(planTask{"Map the Redis session payload", "completed"}, planTask{"Write the 0042 sessions migration", "completed"},
				planTask{"Implement the Postgres session store", "in_progress"}, planTask{"Sweep expired sessions", "pending"}, planTask{"Run integration tests on Postgres 17", "pending"})
		},
		func() error {
			return s.tool("Edit", map[string]any{"file_path": "internal/session/postgres.go", "old_string": "", "new_string": "func (p *Postgres) Get(ctx context.Context, id string) (Session, error) {\n\trow := p.db.QueryRowContext(ctx, getSession, id)\n\t..."}, map[string]any{"output": "Created internal/session/postgres.go (+112)"}, 1800*time.Millisecond)
		},
		func() error {
			return s.subagent("sweeper", "Expiry sweeper", "general-purpose", "running", "Writing a batched DELETE with SKIP LOCKED", 9600, "Batches of 500 keep each transaction under 50 ms")
		},
		func() error {
			return s.say("The migration and the Postgres store are in place behind the existing `session.Store` interface, so handlers don't change. A sweeper deletes expired rows in batches of 500 with `FOR UPDATE SKIP LOCKED`, which keeps it safe to run on both API replicas.\n\nRunning the integration suite against a disposable Postgres 17 container now.")
		},
		func() error {
			return s.plan(planTask{"Map the Redis session payload", "completed"}, planTask{"Write the 0042 sessions migration", "completed"},
				planTask{"Implement the Postgres session store", "completed"}, planTask{"Sweep expired sessions", "completed"}, planTask{"Run integration tests on Postgres 17", "in_progress"})
		},
		func() error { return s.hold("make test-integration PG_VERSION=17") },
	}
	return s.run(steps, 1100*time.Millisecond)
}

func goUpgradeTurn(s *showcaseStream) error {
	steps := []func() error{
		func() error {
			return s.plan(planTask{"Bump the go directive", "in_progress"}, planTask{"Refresh dependencies", "pending"}, planTask{"Fix vet findings", "pending"}, planTask{"Run the full test suite", "pending"})
		},
		func() error {
			return s.shell("go mod edit -go=1.26 && go mod tidy", "", 1600*time.Millisecond)
		},
		func() error {
			return s.shell("go list -m -u all | grep '\\['", "github.com/jackc/pgx/v5 v5.7.2 [v5.8.0]\ngolang.org/x/sync v0.12.0 [v0.16.0]\ngolang.org/x/time v0.9.0 [v0.12.0]", 2100*time.Millisecond)
		},
		func() error {
			return s.plan(planTask{"Bump the go directive", "completed"}, planTask{"Refresh dependencies", "in_progress"}, planTask{"Fix vet findings", "pending"}, planTask{"Run the full test suite", "pending"})
		},
		func() error {
			return s.shell("go get -u ./... && go mod tidy", "go: upgraded github.com/jackc/pgx/v5 v5.7.2 => v5.8.0\ngo: upgraded golang.org/x/sync v0.12.0 => v0.16.0\ngo: upgraded golang.org/x/time v0.9.0 => v0.12.0", 3200*time.Millisecond)
		},
		func() error {
			return s.shell("go vet ./...", "# example.com/atlas/internal/search\ninternal/search/index.go:88:2: loop variable doc captured by func literal", 2400*time.Millisecond)
		},
		func() error {
			return s.think("That loop-variable capture is harmless since Go 1.22 changed loop scoping, but vet still flags the explicit copy pattern here. Removing the shadow copy keeps the code idiomatic.")
		},
		func() error {
			return s.tool("apply_patch", map[string]any{"path": "internal/search/index.go", "patch": "*** Begin Patch\n*** Update File: internal/search/index.go\n@@\n-\tfor _, doc := range docs {\n-\t\tdoc := doc\n+\tfor _, doc := range docs {\n*** End Patch"}, map[string]any{"output": "Success. Updated internal/search/index.go"}, 1200*time.Millisecond)
		},
		func() error {
			return s.plan(planTask{"Bump the go directive", "completed"}, planTask{"Refresh dependencies", "completed"}, planTask{"Fix vet findings", "completed"}, planTask{"Run the full test suite", "in_progress"})
		},
		func() error {
			return s.say("The module now targets Go 1.26, three dependencies moved forward and `go vet` is clean. Running the full suite with the race detector before I hand it over for review.")
		},
		func() error { return s.hold("go test -race ./...") },
	}
	return s.run(steps, 1000*time.Millisecond)
}

func checkoutSummaryTurn(s *showcaseStream) error {
	steps := []func() error{
		func() error {
			return s.plan(planTask{"Review the current CartSummary", "in_progress"}, planTask{"Group line items by shipment", "pending"}, planTask{"Show the delivery estimate", "pending"}, planTask{"Check keyboard and screen reader flow", "pending"})
		},
		func() error {
			return s.tool("Read", map[string]any{"file_path": "components/CartSummary.tsx"}, map[string]any{"output": "export function CartSummary({ cart }: Props) {\n  return (\n    <section aria-labelledby=\"summary\">\n      <h2 id=\"summary\">Order summary</h2>\n      {cart.items.map((item) => <LineItem key={item.id} item={item} />)}\n    </section>\n  );\n}"}, 1000*time.Millisecond)
		},
		func() error {
			return s.think("Shipments already come back from the cart API with a carrier and an estimate, so grouping is a presentation change. Each group should be its own list with a heading, so screen readers announce \"Shipment 1 of 2, arrives Thursday\".")
		},
		func() error {
			return s.tool("Edit", map[string]any{"file_path": "components/CartSummary.tsx", "old_string": "{cart.items.map((item) => <LineItem key={item.id} item={item} />)}", "new_string": "{cart.shipments.map((shipment, index) => (\n  <ShipmentGroup key={shipment.id} shipment={shipment} position={index + 1} total={cart.shipments.length} />\n))}"}, map[string]any{"output": "Updated components/CartSummary.tsx (+41 −9)"}, 1500*time.Millisecond)
		},
		func() error {
			return s.shell("pnpm vitest run components/CartSummary", " ✓ components/CartSummary.test.tsx (6 tests) 412ms\n\n Test Files  1 passed (1)\n      Tests  6 passed (6)", 2600*time.Millisecond)
		},
		func() error {
			return s.plan(planTask{"Review the current CartSummary", "completed"}, planTask{"Group line items by shipment", "completed"}, planTask{"Show the delivery estimate", "completed"}, planTask{"Check keyboard and screen reader flow", "in_progress"})
		},
		func() error {
			return s.say("Line items are now grouped per shipment, each with its carrier and a delivery estimate like **Arrives Thu, Oct 16**. Every group is a labelled list, and totals stay in one `<dl>` so screen readers read them as pairs.\n\nRunning the Playwright checkout flow with the accessibility checks.")
		},
		func() error { return s.hold("pnpm exec playwright test checkout.spec.ts --project=chromium") },
	}
	return s.run(steps, 900*time.Millisecond)
}

func k3sUpgradeTurn(s *showcaseStream) error {
	steps := []func() error{
		func() error {
			return s.think("Home Assistant runs as a single replica with a hostPath volume on mini-1, so draining that node is the only disruptive step. The safe path is one minor version at a time with the system-upgrade-controller, upgrading the server first and agents after.")
		},
		func() error {
			return s.shell("kubectl get nodes -o wide", "NAME     STATUS   ROLES                  AGE    VERSION        OS-IMAGE\nmini-1   Ready    control-plane,master   412d   v1.32.6+k3s1   Ubuntu 24.04.3 LTS\nmini-2   Ready    <none>                 388d   v1.32.6+k3s1   Ubuntu 24.04.3 LTS\nnas      Ready    <none>                 201d   v1.32.6+k3s1   Debian 13", 1800*time.Millisecond)
		},
		func() error {
			return s.say("Short answer: go **1.32 → 1.33 → 1.34**, one minor at a time, server first. Kubernetes only supports skipping one minor version for the kubelet, and k3s follows that.\n\n## Plan\n\n1. **Back up etcd** on `mini-1` with `k3s etcd-snapshot save --name pre-1.33`.\n2. **Pin Home Assistant** to `mini-2` before you start, so draining `mini-1` doesn't restart it. Its config lives on the NAS share, so the move is safe.\n3. Apply a `Plan` for the **server** with `version: v1.33.5+k3s1` and `concurrency: 1`.\n4. When `mini-1` reports Ready, apply the **agent** plan. `mini-2` and `nas` drain one at a time.\n5. Repeat with `v1.34.1+k3s1`.\n\n## What can break\n\n- **Traefik CRDs** moved to `traefik.io/v1alpha1` in your manifests already, so nothing to do there.\n- The `servicelb` DaemonSet briefly restarts. Your Home Assistant ingress uses MetalLB, so it isn't affected.\n\nI'm checking which workloads still use deprecated APIs before you start.")
		},
		func() error { return s.hold("kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis") },
	}
	return s.run(steps, 1200*time.Millisecond)
}

func (s *showcaseStream) run(steps []func() error, gap time.Duration) error {
	for _, step := range steps {
		if err := step(); err != nil {
			return err
		}
		if err := s.pause(gap); err != nil {
			return err
		}
	}
	return nil
}
