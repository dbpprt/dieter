package cli

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"google.golang.org/protobuf/types/known/emptypb"
)

const authHelp = `Usage: dieter auth <action>

Actions:
  login [--gateway URL] [--no-open]  Sign in with GitHub using PKCE
  status [--gateway URL]             Show the signed-in account and machines
  logout [--gateway URL]             Revoke and remove the CLI session
`

func randomURLToken(size int) (string, error) {
	raw := make([]byte, size)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func openBrowser(rawURL string) error {
	command := "xdg-open"
	arguments := []string{rawURL}
	switch runtime.GOOS {
	case "darwin":
		command = "open"
	case "windows":
		command, arguments = "rundll32", []string{"url.dll,FileProtocolHandler", rawURL}
	}
	return exec.Command(command, arguments...).Start()
}

func (c *CLI) auth(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, authHelp)
		return nil
	}
	switch args[0] {
	case "login":
		return c.authLogin(args[1:])
	case "status":
		return c.authStatus(args[1:])
	case "logout":
		return c.authLogout(args[1:])
	default:
		return fmt.Errorf("unknown auth action %q; run `dieter auth --help`", args[0])
	}
}

func (c *CLI) authLogin(args []string) error {
	const usage = `Usage: dieter auth login [--gateway URL] [--no-open]

Open GitHub in a browser, receive the PKCE callback on 127.0.0.1, and store
the resulting Dieter gateway session under DIETER_HOME with mode 0600.
`
	set := flags("auth login")
	gatewayURL := set.String("gateway", c.GatewayURL, "gateway origin")
	noOpen := set.Bool("no-open", false, "print the authorization URL without opening it")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("auth login does not accept positional arguments")
	}
	if strings.TrimSpace(*gatewayURL) != "" {
		c.GatewayURL = *gatewayURL
	}
	origin, err := c.gatewayOrigin()
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("listen for Dieter login callback: %w", err)
	}
	defer listener.Close()
	verifier, err := randomURLToken(48)
	if err != nil {
		return err
	}
	digest := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(digest[:])
	redirect := "http://" + listener.Addr().String() + "/auth/callback"
	query := url.Values{"native_redirect_uri": {redirect}, "native_code_challenge": {challenge}}
	authorizationURL := origin + "/auth/github/start?" + query.Encode()

	codeResult := make(chan string, 1)
	errorResult := make(chan error, 1)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /auth/callback", func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Cache-Control", "no-store")
		writer.Header().Set("Content-Type", "text/html; charset=utf-8")
		if message := strings.TrimSpace(request.URL.Query().Get("error")); message != "" {
			http.Error(writer, "Dieter authorization failed. Return to the terminal.", http.StatusBadRequest)
			select {
			case errorResult <- fmt.Errorf("Dieter authorization failed: %s", message):
			default:
			}
			return
		}
		code := strings.TrimSpace(request.URL.Query().Get("code"))
		if code == "" {
			http.Error(writer, "Dieter authorization code is missing.", http.StatusBadRequest)
			select {
			case errorResult <- errors.New("Dieter authorization code is missing"):
			default:
			}
			return
		}
		_, _ = io.WriteString(writer, "<!doctype html><title>Dieter</title><p>Dieter CLI is signed in. Return to the terminal; this window can be closed.</p>")
		select {
		case codeResult <- code:
		default:
		}
	})
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if serveErr := server.Serve(listener); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			select {
			case errorResult <- serveErr:
			default:
			}
		}
	}()
	defer server.Close()
	fmt.Fprintf(c.Out, "Authorize Dieter CLI with GitHub:\n%s\n", authorizationURL)
	if !*noOpen {
		if err := openBrowser(authorizationURL); err != nil {
			fmt.Fprintf(c.Err, "Could not open a browser: %v\n", err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	var code string
	select {
	case code = <-codeResult:
	case err := <-errorResult:
		return err
	case <-ctx.Done():
		return errors.New("Dieter CLI authorization timed out")
	}
	body, _ := json.Marshal(map[string]string{"code": code, "verifier": verifier})
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, origin+"/auth/native/exchange", bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return fmt.Errorf("exchange Dieter authorization: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("exchange Dieter authorization: %s: %s", response.Status, strings.TrimSpace(string(raw)))
	}
	var payload struct {
		AccessToken string `json:"accessToken"`
		ExpiresAt   string `json:"expiresAt"`
		Login       string `json:"login"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		return err
	}
	configuration, err := loadClientConfig(c.Store.Root)
	if err != nil {
		return err
	}
	configuration.DefaultGateway = origin
	configuration.Sessions[origin] = clientSession(payload)
	if err := saveClientConfig(c.Store.Root, configuration); err != nil {
		return err
	}
	c.GatewayURL = origin
	fmt.Fprintf(c.Out, "Signed in to %s as @%s.\n", origin, payload.Login)
	return nil
}

func (c *CLI) authStatus(args []string) error {
	const usage = "Usage: dieter auth status [--gateway URL]\n"
	set := flags("auth status")
	gatewayURL := set.String("gateway", c.GatewayURL, "gateway origin")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("auth status does not accept positional arguments")
	}
	if strings.TrimSpace(*gatewayURL) != "" {
		c.GatewayURL = *gatewayURL
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	gateway, err := c.dialGateway(ctx)
	if err != nil {
		return err
	}
	account, err := gateway.client.GetAccount(ctx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	daemons, err := gateway.client.ListDaemons(ctx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, map[string]any{"gateway": gateway.url, "account": account, "machines": daemons.GetDaemons()})
}

func (c *CLI) authLogout(args []string) error {
	const usage = "Usage: dieter auth logout [--gateway URL]\n"
	set := flags("auth logout")
	gatewayURL := set.String("gateway", c.GatewayURL, "gateway origin")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("auth logout does not accept positional arguments")
	}
	if strings.TrimSpace(*gatewayURL) != "" {
		c.GatewayURL = *gatewayURL
	}
	origin, err := c.gatewayOrigin()
	if err != nil {
		return err
	}
	configuration, err := loadClientConfig(c.Store.Root)
	if err != nil {
		return err
	}
	session, ok := configuration.Sessions[origin]
	if !ok {
		return fmt.Errorf("not signed in to %s", origin)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	request, requestErr := http.NewRequestWithContext(ctx, http.MethodPost, origin+"/auth/native/revoke", nil)
	if requestErr == nil {
		request.Header.Set("Authorization", "Bearer "+session.AccessToken)
		if response, revokeErr := http.DefaultClient.Do(request); revokeErr == nil {
			_ = response.Body.Close()
		}
	}
	delete(configuration.Sessions, origin)
	if configuration.DefaultGateway == origin {
		configuration.DefaultGateway = ""
	}
	if err := saveClientConfig(c.Store.Root, configuration); err != nil {
		return err
	}
	c.Close()
	fmt.Fprintf(c.Out, "Signed out of %s.\n", origin)
	return nil
}
