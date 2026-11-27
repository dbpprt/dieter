package main

import (
	"fmt"

	hostmemory "github.com/dbpprt/dieter/internal/host/memory"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/schema"
	boardstore "github.com/dbpprt/dieter/internal/store"
)

// seedMemoryFixture prepares agent memory for the memory flows (mobile and
// Mac memory.yaml): one saved memory of the project, and a memory setting on
// the mock harness whose extra instructions make every dream stage one batch
// (it verifies that memory; the mock harness answers "mock-memory-dream"
// lines). The project's memory is left off, so other flows see no memory
// controls; the flows turn it on and off themselves.
func seedMemoryFixture(data *boardstore.Store, project model.Project) error {
	if _, err := data.Kanban.SetProjectMemory(project.ID, true); err != nil {
		return err
	}
	memory := hostmemory.New(hostmemory.Options{Store: data, Name: "Isolated E2E machine"})
	defer memory.Index().Close()
	saved, err := memory.Save(hostmemory.SaveInput{
		Project: project.ID, Kind: schema.MemoryKindDecision,
		Content: "The mobile workspace keeps one durable conversation across Android and iOS; client rules live in the shared Kotlin core.",
	})
	if err != nil {
		return err
	}
	settings := schema.DefaultMemorySettings()
	settings.Harness, settings.Model, settings.Apply, settings.Window = "mock", "mock", "review", ""
	settings.Instructions = fmt.Sprintf(`mock-memory-dream [{"op":"verify","targets":[%q],"reason":"The E2E fixture checks this memory."}]`, saved.Memory.ID)
	if _, err = data.KV.PutMemorySettings(settings, ""); err != nil {
		return err
	}
	_, err = data.Kanban.SetProjectMemory(project.ID, false)
	return err
}
