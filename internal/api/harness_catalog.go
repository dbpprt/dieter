package api

import (
	"context"

	"github.com/dbpprt/dieter/internal/harness"
)

func (s *Server) availableHarnesses(ctx context.Context) []harness.Adapter {
	return s.app.Catalog.Refresh(ctx)
}
