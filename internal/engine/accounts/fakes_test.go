//go:build unix

package accounts

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// fakeClaude imitates the parts of the Claude Code CLI the engine runs:
// `auth status --json`, `auth logout` and `auth login --claudeai` over plain
// pipes with a $BROWSER hook, a localhost callback listener and a paste
// prompt.
func fakeClaude(args []string) int {
	scenario := os.Getenv("FAKE_SCENARIO")
	dir := os.Getenv("CLAUDE_CONFIG_DIR")
	if dir == "" {
		dir = filepath.Join(os.Getenv("HOME"), ".claude")
	}
	marker := filepath.Join(dir, ".fake-login.json")
	email := "alice@example.com"
	if strings.Contains(scenario, "bob") {
		email = "bob@example.com"
	}
	command := strings.Join(args, " ")
	switch {
	case command == "auth status --json":
		raw, err := os.ReadFile(marker)
		if err != nil {
			fmt.Println(`{"loggedIn":false,"authMethod":"none"}`)
			return 1
		}
		fmt.Println(string(raw))
		return 0
	case command == "auth logout":
		_ = os.Remove(marker)
		_ = os.WriteFile(filepath.Join(dir, ".logged-out"), []byte("1"), 0o600)
		return 0
	case strings.HasPrefix(command, "auth login --claudeai"):
	default:
		fmt.Fprintln(os.Stderr, "fake claude: unsupported", command)
		return 2
	}
	if len(args) == 5 && args[3] == "--email" {
		_ = os.WriteFile(filepath.Join(dir, ".login-email"), []byte(args[4]), 0o600)
	}
	signIn := func() {
		raw, _ := json.Marshal(map[string]any{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
			"email": email, "orgId": "org_1", "orgName": "Org One", "subscriptionType": "max"})
		_ = os.WriteFile(marker, raw, 0o600)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 3
	}
	port := listener.Addr().(*net.TCPAddr).Port
	done := make(chan int, 2)
	http.HandleFunc("/callback", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("state") != "S1" || r.URL.Query().Get("code") != "good" {
			http.Error(w, "bad state", http.StatusBadRequest)
			return
		}
		signIn()
		http.Redirect(w, r, "https://platform.claude.com/oauth/code/success", http.StatusFound)
		done <- 0
	})
	go func() { _ = http.Serve(listener, nil) }()
	local := "https://claude.ai/oauth/authorize?code=true&state=S1&redirect_uri=" + url.QueryEscape(fmt.Sprintf("http://localhost:%d/callback", port))
	if browser := os.Getenv("BROWSER"); browser != "" {
		_ = exec.Command(browser, local).Run()
	}
	fmt.Println("Opening browser to sign in…")
	fmt.Println("If the browser didn't open, visit: https://claude.ai/oauth/authorize?code=true&state=S1&redirect_uri=" + url.QueryEscape("https://platform.claude.com/oauth/code/callback"))
	fmt.Print("Paste code here if prompted > ")
	go func() {
		reader := bufio.NewReader(os.Stdin)
		line, err := reader.ReadString('\n')
		if err != nil {
			return
		}
		if strings.TrimRight(line, "\n") == "FIXTURE-CODE#S1" {
			signIn()
			done <- 0
			return
		}
		fmt.Println("OAuth error: Invalid code")
		done <- 1
	}()
	code := <-done
	time.Sleep(50 * time.Millisecond)
	return code
}

// fakeCodex imitates `codex app-server`'s account methods over JSON lines.
func fakeCodex(args []string) int {
	home := os.Getenv("CODEX_HOME")
	scenario := os.Getenv("FAKE_SCENARIO")
	_ = os.WriteFile(filepath.Join(home, "args.log"), []byte(strings.Join(args, " ")), 0o600)
	if len(args) == 0 || args[len(args)-1] != "app-server" {
		return 2
	}
	var writeMu sync.Mutex
	out := bufio.NewWriter(os.Stdout)
	send := func(value any) {
		raw, _ := json.Marshal(value)
		writeMu.Lock()
		_, _ = out.Write(append(raw, '\n'))
		_ = out.Flush()
		writeMu.Unlock()
	}
	authPath := filepath.Join(home, "auth.json")
	writeAuth := func() {
		expiry := time.Now().Add(240 * time.Hour)
		if strings.Contains(scenario, "expiring") {
			expiry = time.Now().Add(time.Hour)
		}
		raw, _ := json.Marshal(map[string]any{
			"OPENAI_API_KEY": nil,
			"tokens": map[string]any{
				"id_token":      testJWT(map[string]any{"email": "carol@example.com", "https://api.openai.com/auth": map[string]any{"chatgpt_account_id": "acct-carol", "chatgpt_plan_type": "pro"}}),
				"access_token":  testJWT(map[string]any{"exp": expiry.Unix(), "n": time.Now().UnixNano()}),
				"refresh_token": "refresh",
				"account_id":    "acct-carol",
			},
			"last_refresh": time.Now().UTC().Format(time.RFC3339Nano),
		})
		_ = os.WriteFile(authPath, raw, 0o600)
	}
	completed := func(loginID string, success bool, failure string) {
		params := map[string]any{"loginId": loginID, "success": success}
		if failure != "" {
			params["error"] = failure
		}
		send(map[string]any{"method": "account/login/completed", "params": params})
	}
	logins := 0
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	for scanner.Scan() {
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(scanner.Bytes(), &request) != nil || len(request.ID) == 0 {
			continue
		}
		reply := func(result any) { send(map[string]any{"id": request.ID, "result": result}) }
		switch request.Method {
		case "initialize":
			reply(map[string]any{"codexHome": home, "platformFamily": "unix", "platformOs": "macos", "userAgent": "fake"})
		case "account/login/start":
			var params struct{ Type string }
			_ = json.Unmarshal(request.Params, &params)
			logins++
			loginID := "login-" + strconv.Itoa(logins)
			if params.Type == "chatgptDeviceCode" {
				reply(map[string]any{"type": "chatgptDeviceCode", "loginId": loginID, "verificationUrl": "https://auth.openai.com/codex/device", "userCode": "CODE-" + strconv.Itoa(logins)})
				expire := strings.Contains(scenario, "device-timeout") && logins == 1
				go func() {
					time.Sleep(50 * time.Millisecond)
					if expire {
						completed(loginID, false, "device auth timed out after 15 minutes")
						return
					}
					writeAuth()
					completed(loginID, true, "")
				}()
				continue
			}
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				return 3
			}
			port := listener.Addr().(*net.TCPAddr).Port
			mux := http.NewServeMux()
			mux.HandleFunc("/auth/callback", func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Query().Get("code") != "good" {
					http.Error(w, "bad code", http.StatusBadRequest)
					return
				}
				writeAuth()
				http.Redirect(w, r, fmt.Sprintf("http://localhost:%d/success", port), http.StatusFound)
			})
			mux.HandleFunc("/success", func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte("Signed in"))
				// Codex reports completion only once /success is fetched.
				completed(loginID, true, "")
			})
			go func() { _ = http.Serve(listener, mux) }()
			reply(map[string]any{"type": "chatgpt", "loginId": loginID, "authUrl": "https://auth.openai.com/oauth/authorize?client_id=app_x&state=S&redirect_uri=" + url.QueryEscape(fmt.Sprintf("http://localhost:%d/auth/callback", port))})
		case "account/login/cancel":
			reply(map[string]any{})
		case "account/read":
			var params struct {
				RefreshToken bool `json:"refreshToken"`
			}
			_ = json.Unmarshal(request.Params, &params)
			if _, err := os.Stat(authPath); err != nil {
				reply(map[string]any{"account": nil, "requiresOpenaiAuth": true})
				continue
			}
			if params.RefreshToken {
				count, _ := os.ReadFile(filepath.Join(home, "refresh-count"))
				n, _ := strconv.Atoi(string(count))
				_ = os.WriteFile(filepath.Join(home, "refresh-count"), []byte(strconv.Itoa(n+1)), 0o600)
				scenario = strings.ReplaceAll(scenario, "expiring", "")
				writeAuth()
			}
			reply(map[string]any{"account": map[string]any{"type": "chatgpt", "email": "carol@example.com", "planType": "pro"}, "requiresOpenaiAuth": true})
		case "account/logout":
			_ = os.Remove(authPath)
			reply(map[string]any{})
		case "account/rateLimits/read":
			reply(map[string]any{
				"rateLimits": map[string]any{
					"limitId": "codex", "planType": "pro",
					"primary":   map[string]any{"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1794661675},
					"secondary": map[string]any{"usedPercent": 7, "windowDurationMins": 10080, "resetsAt": 1795000000},
					"credits":   map[string]any{"hasCredits": true, "unlimited": false, "balance": "12.50"},
				},
				"rateLimitsByLimitId": map[string]any{
					"codex":       map[string]any{"limitId": "codex"},
					"codex_spark": map[string]any{"limitId": "codex_spark", "limitName": "Spark", "primary": map[string]any{"usedPercent": 3, "windowDurationMins": 300}},
				},
				"rateLimitResetCredits": map[string]any{"availableCount": 2},
			})
		case "account/rateLimitResetCredit/consume":
			_ = os.WriteFile(filepath.Join(home, "consume.json"), request.Params, 0o600)
			reply(map[string]any{"outcome": "reset"})
		default:
			send(map[string]any{"id": request.ID, "error": map[string]any{"code": -32601, "message": "unknown method " + request.Method}})
		}
	}
	return 0
}

func testJWT(claims map[string]any) string {
	payload, _ := json.Marshal(claims)
	return base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`)) + "." + base64.RawURLEncoding.EncodeToString(payload) + ".sig"
}
