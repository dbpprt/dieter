package scm

import (
	"context"

	"github.com/dbpprt/dieter/internal/model"
)

type CreatePullRequestInput struct {
	Title, Body, Base, Head string
	Draft                   bool
}

type Provider interface {
	Capabilities(context.Context, string, string) model.SCMCapabilities
	CreatePullRequest(context.Context, string, string, CreatePullRequestInput) (model.PullRequest, error)
	PullRequest(context.Context, string, string, int) (model.PullRequest, error)
	MergePullRequest(context.Context, string, string, int, string, string) (model.PullRequest, error)
}
