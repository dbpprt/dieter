package server

import (
	"context"
	"os"

	"github.com/dbpprt/dieter/internal/harness"
)

func (s *Server) availableHarnesses(ctx context.Context) []harness.Adapter {
	catalog := harness.RefreshCatalog
	if s.harnessCatalog != nil {
		catalog = s.harnessCatalog
	}
	return catalog(ctx, os.Getenv("DIETER_ENABLE_MOCK_HARNESS") == "1")
}
