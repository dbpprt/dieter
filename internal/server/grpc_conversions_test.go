package server

import (
	"reflect"
	"testing"

	"github.com/dbpprt/dieter/internal/harness"
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

func TestProtoHarnessCatalogPreservesMutableProviderOptions(t *testing.T) {
	catalog := protoHarnessCatalog([]harness.Adapter{{
		ID: "codex",
		Options: []harness.ProviderOption{{
			ID: "fast_mode", Name: "Fast mode", Type: "boolean", Default: "false", Mutable: true, Models: []string{"gpt-5.6-sol"},
		}},
	}})
	options := catalog.GetHarnesses()[0].GetOptions()
	if len(options) != 1 || options[0].GetId() != "fast_mode" || !options[0].GetMutable() || !reflect.DeepEqual(options[0].GetModels(), []string{"gpt-5.6-sol"}) {
		t.Fatalf("provider options=%#v", options)
	}
}
