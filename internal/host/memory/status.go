package memory

import (
	"github.com/dbpprt/dieter/internal/model"
)

// ProjectStatus is a project's memory state on this daemon.
type ProjectStatus struct {
	ProjectID, Name            string
	Enabled                    bool
	Cards                      int
	Observations               int64
	Saved                      int
	LastIndexed                string
	Backlog                    int
	LastDreamAt, LastDreamCard string
	NextDream                  string
	FinishedSince              int
}

// Status is this daemon's agent memory state.
type Status struct {
	MachineID, Machine string
	IndexBytes         int64
	Projects           []ProjectStatus
	LastError          string
}

// Status reports a project, or every project with memory on.
func (s *Service) Status(projectID string) (Status, error) {
	status := Status{Machine: s.name, IndexBytes: s.index.Size()}
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return status, err
	}
	status.MachineID = identity.DaemonID
	var projects []model.Project
	if projectID != "" {
		project, err := s.store.Kanban.ResolveProject(projectID)
		if err != nil {
			return status, err
		}
		projects = []model.Project{project}
	} else {
		all, err := s.store.Kanban.ListProjects()
		if err != nil {
			return status, err
		}
		for _, project := range all {
			if project.MemoryEnabled && !project.Archived {
				projects = append(projects, project)
			}
		}
	}
	settings, err := s.store.KV.MemorySettings()
	if err != nil {
		return status, err
	}
	for _, project := range projects {
		entry := ProjectStatus{ProjectID: project.ID, Name: project.Name, Enabled: project.MemoryEnabled, Backlog: s.backlog()}
		stats, err := s.index.Stats(project.ID)
		if err != nil {
			status.LastError = err.Error()
		}
		entry.Cards, entry.Observations, entry.LastIndexed = stats.Cards, stats.Observations, stats.LastIndexed
		if active, err := s.activeMemories(project.ID); err == nil {
			entry.Saved = len(active)
		}
		gate := s.dreamGate(settings.Record, project, identity.DaemonID)
		entry.LastDreamAt, entry.LastDreamCard, entry.FinishedSince, entry.NextDream = gate.LastDreamAt, gate.LastDreamCard, gate.FinishedSince, gate.Reason
		status.Projects = append(status.Projects, entry)
	}
	return status, nil
}
