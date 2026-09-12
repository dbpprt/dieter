package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestBackgroundProcessHostReplyAcknowledgesAdmissionAndErrors(t *testing.T) {
	call := &ProcessCall{ID: "tool-1", Operation: "start", Arguments: json.RawMessage(`{"argv":["echo","hi"]}`)}
	for _, fails := range []bool{false, true} {
		var output bytes.Buffer
		err := replyProcessCall(context.Background(), &output, func(ctx context.Context, got ProcessCall) (json.RawMessage, error) {
			if _, ok := ctx.Deadline(); !ok {
				t.Fatal("host call has no deadline")
			}
			if got.ID != call.ID {
				t.Fatal("host call lost correlation")
			}
			if fails {
				return nil, errors.New("admission rejected")
			}
			return json.RawMessage(`{"id":"exec-real","status":"running"}`), nil
		}, call)
		if err != nil {
			t.Fatal(err)
		}
		var response struct {
			ID     string
			Result json.RawMessage
			Error  string
		}
		if err := json.Unmarshal(output.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if response.ID != call.ID || (fails && response.Error != "admission rejected") || (!fails && !bytes.Contains(response.Result, []byte("exec-real"))) {
			t.Fatalf("response=%s", output.Bytes())
		}
	}
	if err := replyProcessCall(context.Background(), &bytes.Buffer{}, nil, &ProcessCall{}); err == nil {
		t.Fatal("accepted an uncorrelated host call")
	}
}

func TestSubprocessBackgroundProcessUsesPrivateReplyPipe(t *testing.T) {
	dir := t.TempDir()
	script := `import readline from 'node:readline';
const input = readline.createInterface({input:process.stdin});
let first = true;
input.on('line', line => {
 if (first) { first=false; process.stdout.write(JSON.stringify({type:'background-process',processCall:{id:'call',operation:'start',arguments:{argv:['echo','hello']}}})+'\n'); }
 else { const reply=JSON.parse(line); process.stdout.write(JSON.stringify({type:'chunk',chunk:reply.result})+'\n'); input.close(); process.stdin.destroy(); }
});`
	if err := os.WriteFile(filepath.Join(dir, "runner.mjs"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", dir)
	runner := NewSubprocessRunner(t.TempDir())
	var result json.RawMessage
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	err := runner.Run(ctx, Request{SessionID: "own-card", ProjectPath: t.TempDir(), RuntimeRoot: t.TempDir(), BackgroundProcessesEnabled: true,
		BackgroundProcess: func(_ context.Context, call ProcessCall) (json.RawMessage, error) {
			return json.RawMessage(`{"id":"registered-process"}`), nil
		},
	}, func(output Output) error { result = output.Chunk; return nil })
	if err != nil || !bytes.Contains(result, []byte("registered-process")) {
		t.Fatalf("result=%s err=%v", result, err)
	}
}
