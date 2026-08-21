package server

import (
	"testing"

	"github.com/dbpprt/nauclio/internal/harness"
)

// Discovered catalogs can repeat effort values; duplicates crash the Mac
// client's identity-keyed effort menu, so the conversion must drop them.
func TestProtoHarnessCatalogDeduplicatesModelEfforts(t *testing.T) {
	catalog := protoHarnessCatalog([]harness.Adapter{{
		ID: "pi",
		Models: []harness.Model{{
			ID:      "box/current",
			Efforts: []string{"low", "medium", "low", "", "high", "medium"},
		}},
	}})
	if len(catalog.Harnesses) != 1 || len(catalog.Harnesses[0].Models) != 1 {
		t.Fatalf("unexpected catalog: %#v", catalog)
	}
	efforts := catalog.Harnesses[0].Models[0].Efforts
	if len(efforts) != 3 || efforts[0] != "low" || efforts[1] != "medium" || efforts[2] != "high" {
		t.Fatalf("unexpected efforts: %#v", efforts)
	}
}
