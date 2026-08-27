package scm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/gitexec"
	"github.com/dbpprt/dieter/internal/model"
)

type CommandRunner interface {
	Run(context.Context, string, string, ...string) ([]byte, error)
}

type commandRunner struct{}

func (commandRunner) Run(ctx context.Context, directory, name string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = directory
	command.Env = append(command.Environ(), "GH_PROMPT_DISABLED=1", "GIT_TERMINAL_PROMPT=0")
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	if err := command.Run(); err != nil {
		return output.Bytes(), fmt.Errorf("%s: %w", gitexec.Redact(strings.TrimSpace(output.String())), err)
	}
	return output.Bytes(), nil
}

type GitHub struct {
	Commands CommandRunner
	LookPath func(string) (string, error)
}

func NewGitHub() *GitHub { return &GitHub{Commands: commandRunner{}, LookPath: exec.LookPath} }

func (g *GitHub) Capabilities(ctx context.Context, directory, remote string) model.SCMCapabilities {
	if strings.TrimSpace(remote) == "" {
		remote = "origin"
	}
	result := model.SCMCapabilities{Provider: "github", Remote: remote}
	remoteURL, err := g.Commands.Run(ctx, directory, "git", "remote", "get-url", remote)
	if err != nil {
		result.UnavailableReason = "Git remote is unavailable"
		return result
	}
	result.RemoteAvailable, result.PushAvailable = true, true
	host, owner, repository, err := parseGitHubRemote(strings.TrimSpace(string(remoteURL)))
	if err != nil {
		result.UnavailableReason = err.Error()
		return result
	}
	result.Host, result.Owner, result.Repository = host, owner, repository
	lookPath := g.LookPath
	if lookPath == nil {
		lookPath = exec.LookPath
	}
	if _, err := lookPath("gh"); err != nil {
		result.UnavailableReason = "GitHub CLI is not installed on the daemon host"
		return result
	}
	result.ProviderAPIAvailable = true
	if _, err := g.Commands.Run(ctx, directory, "gh", "auth", "status", "--hostname", host); err != nil {
		result.UnavailableReason = "GitHub CLI is not authenticated for " + host
		return result
	}
	result.Authenticated = true
	return result
}

func parseGitHubRemote(value string) (string, string, string, error) {
	value = strings.TrimSpace(value)
	host, repositoryPath := "", ""
	if strings.Contains(value, "://") {
		parsed, err := url.Parse(value)
		if err != nil {
			return "", "", "", errors.New("Git remote URL is invalid")
		}
		host, repositoryPath = parsed.Hostname(), strings.TrimPrefix(parsed.Path, "/")
	} else if at := strings.LastIndex(value, "@"); at >= 0 {
		remaining := value[at+1:]
		colon := strings.Index(remaining, ":")
		if colon < 1 {
			return "", "", "", errors.New("Git remote URL is not a supported GitHub remote")
		}
		host, repositoryPath = remaining[:colon], remaining[colon+1:]
	} else {
		return "", "", "", errors.New("Git remote URL is not a supported GitHub remote")
	}
	repositoryPath = strings.TrimSuffix(strings.Trim(repositoryPath, "/"), ".git")
	parts := strings.Split(repositoryPath, "/")
	if host == "" || len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", "", errors.New("Git remote does not identify one GitHub repository")
	}
	return host, parts[0], parts[1], nil
}

func (g *GitHub) CreatePullRequest(ctx context.Context, directory, remote string, input CreatePullRequestInput) (model.PullRequest, error) {
	capabilities := g.Capabilities(ctx, directory, remote)
	if !capabilities.Authenticated {
		return model.PullRequest{}, errors.New(capabilities.UnavailableReason)
	}
	repo := capabilities.Owner + "/" + capabilities.Repository
	list, err := g.Commands.Run(ctx, directory, "gh", "pr", "list", "--repo", repo, "--head", input.Head, "--state", "open", "--limit", "1", "--json", "number")
	if err == nil {
		var existing []struct {
			Number int `json:"number"`
		}
		if json.Unmarshal(list, &existing) == nil && len(existing) > 0 {
			return g.PullRequest(ctx, directory, remote, existing[0].Number)
		}
	}
	args := []string{"pr", "create", "--repo", repo, "--base", input.Base, "--head", input.Head, "--title", input.Title, "--body", input.Body}
	if input.Draft {
		args = append(args, "--draft")
	}
	created, err := g.Commands.Run(ctx, directory, "gh", args...)
	if err != nil {
		return model.PullRequest{}, err
	}
	createdURL := strings.TrimSpace(string(created))
	parts := strings.Split(strings.Trim(createdURL, "/"), "/")
	if len(parts) == 0 {
		return model.PullRequest{}, errors.New("GitHub did not return a pull request URL")
	}
	number, err := strconv.Atoi(parts[len(parts)-1])
	if err != nil {
		return model.PullRequest{}, errors.New("GitHub returned an invalid pull request URL")
	}
	return g.PullRequest(ctx, directory, remote, number)
}

type githubPullRequest struct {
	Number         int    `json:"number"`
	URL            string `json:"url"`
	State          string `json:"state"`
	IsDraft        bool   `json:"isDraft"`
	Mergeable      string `json:"mergeable"`
	ReviewDecision string `json:"reviewDecision"`
	Additions      int    `json:"additions"`
	Deletions      int    `json:"deletions"`
	ChangedFiles   int    `json:"changedFiles"`
	HeadRefName    string `json:"headRefName"`
	HeadRefOID     string `json:"headRefOid"`
	BaseRefName    string `json:"baseRefName"`
	BaseRefOID     string `json:"baseRefOid"`
	Checks         []struct {
		Conclusion string `json:"conclusion"`
		Status     string `json:"status"`
	} `json:"statusCheckRollup"`
}

func (g *GitHub) PullRequest(ctx context.Context, directory, remote string, number int) (model.PullRequest, error) {
	capabilities := g.Capabilities(ctx, directory, remote)
	if !capabilities.Authenticated {
		return model.PullRequest{}, errors.New(capabilities.UnavailableReason)
	}
	repo := capabilities.Owner + "/" + capabilities.Repository
	fields := "number,url,state,isDraft,mergeable,reviewDecision,additions,deletions,changedFiles,headRefName,headRefOid,baseRefName,baseRefOid,statusCheckRollup"
	raw, err := g.Commands.Run(ctx, directory, "gh", "pr", "view", strconv.Itoa(number), "--repo", repo, "--json", fields)
	if err != nil {
		return model.PullRequest{}, err
	}
	var item githubPullRequest
	if err := json.Unmarshal(raw, &item); err != nil {
		return model.PullRequest{}, fmt.Errorf("decode GitHub pull request: %w", err)
	}
	checks := "passed"
	for _, check := range item.Checks {
		if check.Status != "COMPLETED" {
			checks = "running"
			continue
		}
		switch check.Conclusion {
		case "SUCCESS", "NEUTRAL", "SKIPPED":
		default:
			checks = "failed"
		}
	}
	return model.PullRequest{
		Provider: "github", Host: capabilities.Host, Owner: capabilities.Owner, Repository: capabilities.Repository,
		Number: item.Number, URL: item.URL, State: strings.ToLower(item.State), Draft: item.IsDraft,
		Mergeable: item.Mergeable == "MERGEABLE", ReviewDecision: strings.ToLower(item.ReviewDecision), ChecksState: checks,
		Additions: item.Additions, Deletions: item.Deletions, ChangedFiles: item.ChangedFiles,
		HeadRef: item.HeadRefName, HeadSHA: item.HeadRefOID, BaseRef: item.BaseRefName, BaseSHA: item.BaseRefOID,
		LastSyncedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}, nil
}

func (g *GitHub) MergePullRequest(ctx context.Context, directory, remote string, number int, strategy, expectedHeadSHA string) (model.PullRequest, error) {
	capabilities := g.Capabilities(ctx, directory, remote)
	if !capabilities.Authenticated {
		return model.PullRequest{}, errors.New(capabilities.UnavailableReason)
	}
	switch strategy {
	case "merge", "squash", "rebase":
	default:
		return model.PullRequest{}, errors.New("pull request merge strategy must be merge, squash, or rebase")
	}
	repo := capabilities.Owner + "/" + capabilities.Repository
	endpoint := fmt.Sprintf("repos/%s/pulls/%d/merge", repo, number)
	args := []string{"api", "--method", "PUT", endpoint, "-f", "merge_method=" + strategy}
	if expectedHeadSHA != "" {
		args = append(args, "-f", "sha="+expectedHeadSHA)
	}
	if _, err := g.Commands.Run(ctx, directory, "gh", args...); err != nil {
		return model.PullRequest{}, err
	}
	return g.PullRequest(ctx, directory, remote, number)
}
