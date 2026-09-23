package harness

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func installDiscoveryTestCatalog(t *testing.T, discover func(context.Context, string) ([]Model, error)) {
	t.Helper()
	discoveryMu.Lock()
	catalogMu.Lock()
	previousConfigured := configuredCatalog
	previousSource := configuredCatalogSource
	previousDiscovered := discoveredCatalog
	previousUpdated := discoveryUpdated
	previousDiscover := discoverProvider
	configuredCatalog = []Adapter{{
		ID: "dynamic", Name: "Dynamic", Runtime: "dynamic", DefaultModel: "default",
		Models: []Model{{ID: "default", Name: "Configured default"}},
	}}
	configuredCatalogSource = "test"
	discoveredCatalog = nil
	discoveryUpdated = time.Time{}
	discoverProvider = discover
	catalogMu.Unlock()
	discoveryMu.Unlock()
	t.Cleanup(func() {
		discoveryMu.Lock()
		catalogMu.Lock()
		configuredCatalog = previousConfigured
		configuredCatalogSource = previousSource
		discoveredCatalog = previousDiscovered
		discoveryUpdated = previousUpdated
		discoverProvider = previousDiscover
		catalogMu.Unlock()
		discoveryMu.Unlock()
	})
}

func expireDiscoveryCache() {
	discoveryMu.Lock()
	discoveryUpdated = time.Time{}
	discoveryMu.Unlock()
}

func TestRefreshCatalogRetainsLastKnownGoodProviderModels(t *testing.T) {
	calls := 0
	installDiscoveryTestCatalog(t, func(context.Context, string) ([]Model, error) {
		calls++
		if calls == 1 {
			return []Model{{ID: "dynamic/model", Name: "Dynamic model", Efforts: []string{"high"}}}, nil
		}
		return nil, errors.New("provider temporarily unavailable")
	})

	RefreshCatalog(context.Background(), false)
	if _, _, err := ResolveSelection("dynamic", "dynamic/model", false); err != nil {
		t.Fatalf("initial dynamic selection: %v", err)
	}
	expireDiscoveryCache()
	RefreshCatalog(context.Background(), false)
	if _, _, err := ResolveSelection("dynamic", "dynamic/model", false); err != nil {
		t.Fatalf("selection after failed refresh: %v", err)
	}
	if calls != 2 {
		t.Fatalf("discovery calls=%d, want 2", calls)
	}
}

func TestResolveSelectionWithRefreshRecoversDynamicMiss(t *testing.T) {
	calls := 0
	installDiscoveryTestCatalog(t, func(_ context.Context, provider string) ([]Model, error) {
		calls++
		if provider != "dynamic" {
			t.Fatalf("provider=%q", provider)
		}
		return []Model{{ID: "dynamic/model", Name: "Dynamic model", DefaultEffort: "high", Efforts: []string{"high"}}}, nil
	})

	adapter, model, err := ResolveSelectionWithRefresh(context.Background(), "dynamic", "dynamic/model", false)
	if err != nil {
		t.Fatal(err)
	}
	if adapter.ID != "dynamic" || adapter.DefaultModel != "dynamic/model" || model.ID != "dynamic/model" {
		t.Fatalf("adapter=%#v model=%#v", adapter, model)
	}
	if calls != 1 {
		t.Fatalf("discovery calls=%d, want 1", calls)
	}
}

func TestResolveSelectionWithRefreshReportsDiscoveryFailureAsTemporary(t *testing.T) {
	installDiscoveryTestCatalog(t, func(context.Context, string) ([]Model, error) {
		return nil, errors.New("provider is starting")
	})

	_, _, err := ResolveSelectionWithRefresh(context.Background(), "dynamic", "dynamic/model", false)
	if !errors.Is(err, ErrCatalogUnavailable) {
		t.Fatalf("error=%v, want ErrCatalogUnavailable", err)
	}
}

func TestRefreshCatalogPublishesAtomicallyAcrossFailure(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	calls := 0
	installDiscoveryTestCatalog(t, func(context.Context, string) ([]Model, error) {
		calls++
		if calls == 1 {
			return []Model{{ID: "dynamic/model", Name: "Dynamic model"}}, nil
		}
		close(started)
		<-release
		return nil, errors.New("provider temporarily unavailable")
	})

	RefreshCatalog(context.Background(), false)
	expireDiscoveryCache()
	done := make(chan struct{})
	go func() {
		RefreshCatalog(context.Background(), false)
		close(done)
	}()
	<-started
	if _, _, err := ResolveSelection("dynamic", "dynamic/model", false); err != nil {
		t.Fatalf("selection during refresh: %v", err)
	}
	close(release)
	<-done
	if _, _, err := ResolveSelection("dynamic", "dynamic/model", false); err != nil {
		t.Fatalf("selection after failed refresh: %v", err)
	}
}

func TestTargetedRefreshDoesNotWaitForStalledFullCatalogRefresh(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	installDiscoveryTestCatalog(t, func(context.Context, string) ([]Model, error) {
		if calls.Add(1) == 1 {
			close(started)
			<-release
			return nil, errors.New("full refresh stalled and failed")
		}
		return []Model{{ID: "dynamic/model", Name: "Dynamic model"}}, nil
	})

	done := make(chan struct{})
	go func() {
		RefreshCatalog(context.Background(), false)
		close(done)
	}()
	<-started
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	_, model, resolveErr := ResolveSelectionWithRefresh(ctx, "dynamic", "dynamic/model", false)
	cancel()
	close(release)
	<-done

	if resolveErr != nil {
		t.Fatal(resolveErr)
	}
	if model.ID != "dynamic/model" {
		t.Fatalf("model=%#v", model)
	}
	if _, _, err := ResolveSelection("dynamic", "dynamic/model", false); err != nil {
		t.Fatalf("full refresh overwrote targeted recovery: %v", err)
	}
}

func TestLiveProviderDiscovery(t *testing.T) {
	if os.Getenv("DIETER_TEST_LIVE_DISCOVERY") != "1" {
		t.Skip("set DIETER_TEST_LIVE_DISCOVERY=1 to query installed provider integrations")
	}
	for _, provider := range []string{"codex", "claude-code", "pi", "omp", "dsh"} {
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
			if provider == "omp" {
				want := []string{
					"tailscale/glm-5.3-flash-exl3",
					"openai-codex/gpt-6-luna",
					"openai-codex/gpt-6-sol",
					"openai-codex/gpt-6-astra",
				}
				if len(models) != len(want) {
					t.Fatalf("OMP models=%#v, want %v", models, want)
				}
				for index := range want {
					if models[index].ID != want[index] {
						t.Fatalf("OMP model %d=%q, want %q", index, models[index].ID, want[index])
					}
				}
			}
		})
	}
}

func TestDiscoverCodexModelsIncludesVisibleAstra(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CODEX_HOME", root)
	cache := `{
  "models": [
    {
      "slug": "gpt-6-astra",
      "display_name": "GPT-6-Astra",
      "visibility": "list",
      "supported_in_api": true,
      "context_window": 272000,
      "default_reasoning_level": "medium",
      "supported_reasoning_levels": [
        {"effort": "low"},
        {"effort": "medium"},
        {"effort": "high"},
        {"effort": "xhigh"},
        {"effort": "max"},
        {"effort": "ultra"}
      ]
    },
    {
      "slug": "internal-only",
      "display_name": "Internal only",
      "visibility": "hide",
      "context_window": 1
    }
  ]
}`
	if err := os.WriteFile(filepath.Join(root, "models_cache.json"), []byte(cache), 0o600); err != nil {
		t.Fatal(err)
	}

	models, err := discoverCodexModels()
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 1 {
		t.Fatalf("models=%#v, want only visible Astra", models)
	}
	astra := models[0]
	if astra.ID != "gpt-6-astra" || astra.Name != "GPT-6-Astra" || astra.ContextWindow != 272000 || astra.DefaultEffort != "medium" {
		t.Fatalf("Astra=%#v", astra)
	}
	if got, want := strings.Join(astra.Efforts, ","), "low,medium,high,xhigh,max,ultra"; got != want {
		t.Fatalf("Astra efforts=%q want %q", got, want)
	}
}

func TestDiscoverDSHModelsPreservesOpaqueACPSelectors(t *testing.T) {
	previous := runDSHDiscovery
	runDSHDiscovery = func(context.Context) ([]byte, error) {
		return []byte(`{"models":[{"id":"local/fast","name":"Fast · Local","runtimeModel":"[\"local\",\"fast\"]"}]}`), nil
	}
	t.Cleanup(func() { runDSHDiscovery = previous })
	models, err := discoverModels(context.Background(), "dsh")
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 1 || models[0].ID != "local/fast" || models[0].RuntimeModel == nil || *models[0].RuntimeModel != `["local","fast"]` {
		t.Fatalf("unexpected DSH models: %#v", models)
	}
}

func TestDiscoverDSHModelsRejectsInvalidCatalog(t *testing.T) {
	previous := runDSHDiscovery
	runDSHDiscovery = func(context.Context) ([]byte, error) {
		return []byte(`{"models":[{"id":"","name":"Broken","runtimeModel":""}]}`), nil
	}
	t.Cleanup(func() { runDSHDiscovery = previous })
	if _, err := discoverModels(context.Background(), "dsh"); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("unexpected error: %v", err)
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

func TestDiscoverOMPModelsUsesPinnedCatalog(t *testing.T) {
	previous := runOMPDiscovery
	runOMPDiscovery = func(context.Context) ([]byte, error) {
		return []byte(`{"models":[{"selector":"openrouter/openai/gpt-6-sol","name":"GPT-6 Sol","thinking":["max"]}]}`), nil
	}
	t.Cleanup(func() { runOMPDiscovery = previous })
	models, err := discoverModels(context.Background(), "omp")
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 1 || models[0].ID != "openrouter/openai/gpt-6-sol" {
		t.Fatalf("unexpected pinned OMP models: %#v", models)
	}
}

func TestParseOMPModelsSelectsTheExactConfiguredModelAndEffort(t *testing.T) {
	models, err := parseOMPModels([]byte(`{"defaultModel":"openrouter/model:free:high","models":[{"selector":"openrouter/model","name":"Base","thinking":["high"]},{"selector":"openrouter/model:free","name":"Free","thinking":["low","high"]}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 2 || models[0].ID != "openrouter/model:free" || models[0].DefaultEffort != "high" {
		t.Fatalf("unexpected configured OMP model: %#v", models)
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

func TestMergeDiscoveredCatalogPrefersSupportedConfiguredDefaultEffort(t *testing.T) {
	adapter := Adapter{ID: "codex", DefaultModel: "sol", Models: []Model{{ID: "sol", DefaultEffort: "xhigh"}}}
	merged := mergeDiscoveredAdapter(adapter, []Model{
		{ID: "sol", DefaultEffort: "low", Efforts: []string{"low", "high", "xhigh"}},
		{ID: "spark", DefaultEffort: "high", Efforts: []string{"low", "high"}},
	})
	if got := merged.Models[0].DefaultEffort; got != "xhigh" {
		t.Fatalf("configured default effort=%q want xhigh", got)
	}
	if got := merged.Models[1].DefaultEffort; got != "high" {
		t.Fatalf("discovered default effort=%q want high", got)
	}
}

func TestMergeDiscoveredCatalogKeepsProviderDefaultWhenConfiguredValueIsUnsupported(t *testing.T) {
	adapter := Adapter{ID: "codex", DefaultModel: "sol", Models: []Model{{ID: "sol", DefaultEffort: "xhigh"}}}
	merged := mergeDiscoveredAdapter(adapter, []Model{{ID: "sol", DefaultEffort: "low", Efforts: []string{"low", "high"}}})
	if got := merged.Models[0].DefaultEffort; got != "low" {
		t.Fatalf("unsupported configured default replaced provider default with %q", got)
	}
}

func TestMergeDiscoveredCatalogSurvivesAnEmptyDiscovery(t *testing.T) {
	adapter := Adapter{ID: "pi", DefaultModel: "default"}
	merged := mergeDiscoveredAdapter(adapter, nil)
	if merged.DefaultModel != "default" || len(merged.Models) != 0 || merged.Effort != nil {
		t.Fatalf("unexpected merged adapter: %#v", merged)
	}
}
