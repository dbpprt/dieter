package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCodeReviewHostCallReplies(t *testing.T) {
	t.Parallel()
	call := ProcessCall{ID: "call-1", Operation: "review", Arguments: json.RawMessage(`{}`)}
	reply := func(handler CodeReviewHandler) map[string]any {
		t.Helper()
		var out bytes.Buffer
		replyCodeReview(context.Background(), &out, handler, call)
		var decoded map[string]any
		if err := json.Unmarshal(out.Bytes(), &decoded); err != nil {
			t.Fatalf("reply %q: %v", out.String(), err)
		}
		if decoded["type"] != "code-review-result" || decoded["id"] != "call-1" || !strings.HasSuffix(out.String(), "\n") {
			t.Fatalf("reply frame=%q", out.String())
		}
		return decoded
	}
	if got := reply(func(context.Context, ProcessCall) (json.RawMessage, error) {
		return json.RawMessage(`"2 findings"`), nil
	}); got["result"] != "2 findings" || got["error"] != nil {
		t.Fatalf("result reply=%#v", got)
	}
	if got := reply(nil); !strings.Contains(got["error"].(string), "not available") {
		t.Fatalf("nil handler reply=%#v", got)
	}
	if got := reply(func(context.Context, ProcessCall) (json.RawMessage, error) { return nil, errors.New("busy") }); got["error"] != "busy" {
		t.Fatalf("error reply=%#v", got)
	}
	if got := reply(func(context.Context, ProcessCall) (json.RawMessage, error) { return json.RawMessage(`{not json`), nil }); got["error"] != "invalid code review result" {
		t.Fatalf("invalid result reply=%#v", got)
	}
	huge := json.RawMessage(`"` + strings.Repeat("x", maxCodeReviewResultBytes) + `"`)
	if got := reply(func(context.Context, ProcessCall) (json.RawMessage, error) { return huge, nil }); got["error"] != "invalid code review result" {
		t.Fatalf("oversized result reply=%#v", got)
	}

	ctx, cancel := context.WithCancel(context.Background())
	var out bytes.Buffer
	replyCodeReview(ctx, &out, func(ctx context.Context, _ ProcessCall) (json.RawMessage, error) {
		cancel()
		return nil, ctx.Err()
	}, call)
	if out.Len() != 0 {
		t.Fatalf("a reply was written after the worker went away: %q", out.String())
	}
}

func TestCodeReviewHostCallValidation(t *testing.T) {
	t.Parallel()
	for name, call := range map[string]*ProcessCall{
		"nil":      nil,
		"no id":    {Arguments: json.RawMessage(`{}`)},
		"long id":  {ID: strings.Repeat("x", 129)},
		"too long": {ID: "x", Arguments: json.RawMessage(`"` + strings.Repeat("a", maxCodeReviewInputBytes) + `"`)},
	} {
		if validCodeReviewCall(call) == nil {
			t.Errorf("%s: invalid call accepted", name)
		}
	}
	if err := validCodeReviewCall(&ProcessCall{ID: "ok", Arguments: json.RawMessage(`{"focus":"x"}`)}); err != nil {
		t.Fatal(err)
	}
}

// A code review call is answered off the read loop: the worker keeps
// streaming (here a heartbeat-like chunk) while the review runs, and the
// reply arrives on the private stdin pipe.
func TestSubprocessCodeReviewIsAnsweredAsynchronously(t *testing.T) {
	dir := t.TempDir()
	script := `import readline from 'node:readline';
const input = readline.createInterface({input:process.stdin});
let first = true;
input.on('line', line => {
 if (first) {
  first=false;
  process.stdout.write(JSON.stringify({type:'code-review',reviewCall:{id:'review-1',operation:'review',arguments:{focus:'locks'}}})+'\n');
  process.stdout.write(JSON.stringify({type:'chunk',chunk:{type:'while-reviewing'}})+'\n');
 } else {
  const reply=JSON.parse(line);
  process.stdout.write(JSON.stringify({type:'chunk',chunk:{type:'reply',id:reply.id,result:reply.result}})+'\n');
  input.close(); process.stdin.destroy();
 }
});`
	if err := os.WriteFile(filepath.Join(dir, "runner.mjs"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	runner := NewSubprocessRunner(t.TempDir(), Environment{RuntimeDir: dir})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	streamed := make(chan struct{})
	var chunks []string
	err := runner.Run(ctx, Request{SessionID: "own-card", ProjectPath: t.TempDir(), RuntimeRoot: t.TempDir(), CodeReviewEnabled: true,
		CodeReview: func(ctx context.Context, call ProcessCall) (json.RawMessage, error) {
			if call.ID != "review-1" || !strings.Contains(string(call.Arguments), "locks") {
				return nil, errors.New("unexpected call")
			}
			// The read loop must deliver the chunk that follows the call
			// before the review answers.
			select {
			case <-streamed:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
			return json.RawMessage(`"no findings"`), nil
		},
	}, func(output Output) error {
		chunks = append(chunks, string(output.Chunk))
		if strings.Contains(string(output.Chunk), "while-reviewing") {
			close(streamed)
		}
		return nil
	})
	if err != nil || len(chunks) != 2 || !strings.Contains(chunks[1], `"result":"no findings"`) || !strings.Contains(chunks[1], `"id":"review-1"`) {
		t.Fatalf("chunks=%q err=%v", chunks, err)
	}
}
