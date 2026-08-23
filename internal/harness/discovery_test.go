package harness

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestLiveProviderDiscovery(t *testing.T) {
	if os.Getenv("DIETER_TEST_LIVE_DISCOVERY") != "1" {
		t.Skip("set DIETER_TEST_LIVE_DISCOVERY=1 to query installed provider integrations")
	}
	for _, provider := range []string{"codex", "claude-code", "pi", "omp"} {
		t.Run(provider, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
			defer cancel()
			models, err := discoverModels(ctx, provider)
			if err != nil {
				t.Fatal(err)
			}
			if len(models) == 0 {
				t.Fatal("integration returned no models")
			}
			for _, model := range models {
				if model.ID == "default" {
					t.Fatal("integration exposed a synthetic default model")
				}
			}
		})
	}
}

func TestParseOMPModelsUsesIntegrationSelectorsAndThinking(t *testing.T) {
	models, err := parseOMPModels([]byte(`{"models":[{"provider":"tailscale","id":"deepseek","selector":"tailscale/deepseek","name":"DeepSeek","contextWindow":1048576,"thinking":["high","max"]}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 1 || models[0].ID != "tailscale/deepseek" || models[0].ContextWindow != 1048576 {
		t.Fatalf("unexpected models: %#v", models)
	}
	if got := models[0].Efforts; len(got) != 2 || got[0] != "high" || got[1] != "max" {
		t.Fatalf("unexpected thinking levels: %#v", got)
	}
}

func TestParseClaudeHelpUsesAdvertisedAliasesAndEfforts(t *testing.T) {
	models, err := parseClaudeHelp([]byte(`
  --effort <level> Effort level for the current session
                   (low, medium, high, xhigh, max)
  --model <model>  Model for the current session. Provide an alias for the
                   latest model (e.g. 'fable', 'opus', or 'sonnet') or a
                   model's full name (e.g. 'claude-fable-5').
`))
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 3 || models[0].ID != "fable" || len(models[0].Efforts) != 5 || models[0].Efforts[4] != "max" {
		t.Fatalf("unexpected models: %#v", models)
	}
}

func TestMergeDiscoveredCatalogHidesCompatibilityModels(t *testing.T) {
	adapter := Adapter{ID: "pi", DefaultModel: "default", Models: []Model{{ID: "default"}, {ID: "old"}}}
	merged := mergeDiscoveredAdapter(adapter, []Model{{ID: "box/current", Efforts: []string{"low"}}})
	if merged.DefaultModel != "box/current" || len(merged.Models) != 3 || merged.Models[1].Hidden != true {
		t.Fatalf("unexpected merged adapter: %#v", merged)
	}
	if merged.Effort == nil || len(merged.Effort.Options) != 1 || merged.Effort.Options[0].ID != "low" {
		t.Fatalf("unexpected effort catalog: %#v", merged.Effort)
	}
}

func TestMergeDiscoveredCatalogSurvivesAnEmptyDiscovery(t *testing.T) {
	adapter := Adapter{ID: "pi", DefaultModel: "default"}
	merged := mergeDiscoveredAdapter(adapter, nil)
	if merged.DefaultModel != "default" || len(merged.Models) != 0 || merged.Effort != nil {
		t.Fatalf("unexpected merged adapter: %#v", merged)
	}
}
