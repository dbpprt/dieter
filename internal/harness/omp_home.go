package harness

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fsx"
)

// OMPAgentDir is the Oh My Pi agent directory every Dieter OMP process uses
// (PI_CODING_AGENT_DIR): its sessions, settings and caches, machine-local and
// never replicated. It holds no login (ADR 0007). Its models.yml makes OMP ask
// the daemon, through the running turn's token, for the access token of the
// account the turn uses for each provider.
func OMPAgentDir(dieterHome string) string {
	return filepath.Join(dieterHome, "omp", "agent")
}

// ensureManagedOMPHome prepares the managed agent directory and its
// models.yml, rewriting the file only when its content changes. baseURLs
// (tests only, Environment.OMPProviderBaseURLs) points providers at other
// endpoints.
func ensureManagedOMPHome(dieterHome, dieterExecutable string, baseURLs map[string]string) (string, error) {
	if dieterHome == "" {
		return "", fmt.Errorf("Oh My Pi needs a Dieter home")
	}
	if dieterExecutable == "" {
		executable, err := os.Executable()
		if err != nil {
			return "", fmt.Errorf("locate the dieter executable for Oh My Pi: %w", err)
		}
		dieterExecutable = executable
	}
	dir := OMPAgentDir(dieterHome)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "models.yml")
	content := renderOMPModels(dieterExecutable, baseURLs)
	if current, err := os.ReadFile(path); err == nil && bytes.Equal(current, content) {
		return dir, nil
	}
	if err := fsx.WriteFile(path, content, 0o600); err != nil {
		return "", fmt.Errorf("write Oh My Pi models.yml: %w", err)
	}
	return dir, nil
}

// renderOMPModels points OMP's subscription providers at the turn token
// helper. OMP runs `!command` keys with /bin/sh, caches the output for the
// process and reruns the command after a 401, so a token that expires
// mid-turn is replaced by a fresh one from the daemon. A models.yml key beats
// any login OMP might store, and Dieter offers OMP no other models.
func renderOMPModels(dieterExecutable string, baseURLs map[string]string) []byte {
	var out strings.Builder
	out.WriteString("# Rendered by Dieter: Oh My Pi asks the running turn for each provider's\n" +
		"# access token. Do not edit; Dieter rewrites this file.\n" +
		"providers:\n")
	for _, provider := range []struct{ omp, dieter string }{{"anthropic", "claude"}, {"openai-codex", "chatgpt"}} {
		out.WriteString("  " + provider.omp + ":\n")
		if base := strings.TrimSpace(baseURLs[provider.omp]); base != "" {
			out.WriteString("    baseUrl: " + strconv.Quote(base) + "\n")
		}
		command := "!" + shellQuote(dieterExecutable) + " provider token --turn --provider " + provider.dieter
		out.WriteString("    apiKey: " + strconv.Quote(command) + "\n")
	}
	return []byte(out.String())
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

// ompMaskedEnvironment lists host variables an OMP worker must not inherit:
// provider credentials and routing (OMP's only credentials are the turn's
// accounts) and OMP's or Claude Code's own profile selection, which would
// pull in foreign logins, models and settings. ompMaskedPrefixes covers the
// providers' whole families, also when DIETER_HARNESS_ENV forwards one.
var ompMaskedEnvironment = map[string]bool{
	"OMP_PROFILE": true, "PI_AGENT_DIR": true, "PI_CODING_AGENT_DIR": true, "CLAUDE_CONFIG_DIR": true,
	"CLAUDE_CODE_OAUTH_TOKEN": true, "AI_GATEWAY_API_KEY": true, "AI_GATEWAY_BASE_URL": true, "VERCEL_OIDC_TOKEN": true,
}

var ompMaskedPrefixes = []string{"ANTHROPIC_", "OPENAI_", "CODEX_"}

func ompMasked(name string) bool {
	if ompMaskedEnvironment[name] {
		return true
	}
	for _, prefix := range ompMaskedPrefixes {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}
