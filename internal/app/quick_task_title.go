package app

import (
	"context"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

const (
	quickTaskTitleConcurrency = 2
	quickTaskTitleJobLimit    = 32
	quickTaskTitleTimeout     = 45 * time.Second
)

type quickTitleJob struct {
	cancel context.CancelFunc
	done   chan struct{}
}

// Title generation is an optional, bounded metadata improvement. A full queue,
// unavailable provider or daemon shutdown leaves the saved fallback title intact.
func (s *Service) scheduleQuickTaskTitle(card model.Card, story string) {
	s.mu.Lock()
	if s.shuttingDown || len(s.quickTitleJobs) >= quickTaskTitleJobLimit || s.quickTitleJobs[card.ID] != nil {
		s.mu.Unlock()
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), quickTaskTitleTimeout)
	job := &quickTitleJob{cancel: cancel, done: make(chan struct{})}
	s.quickTitleJobs[card.ID] = job
	s.mu.Unlock()
	go func() {
		defer func() {
			cancel()
			s.mu.Lock()
			delete(s.quickTitleJobs, card.ID)
			close(job.done)
			s.mu.Unlock()
		}()
		select {
		case s.quickTitleSlots <- struct{}{}:
			defer func() { <-s.quickTitleSlots }()
		case <-ctx.Done():
			return
		}
		title, err := s.generateQuickTaskTitle(ctx, story)
		if err != nil || ctx.Err() != nil {
			return
		}
		// Compare the durable revision as well as the text: changing a title and
		// then restoring it must still take precedence over the generated title.
		_, _ = s.Store.ApplyGeneratedCardTitle(card.ID, card.Title, card.TitleRevision, title)
	}()
}

func quickTaskFallbackTitle(story string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(story), "\n")
	line = strings.Join(strings.Fields(line), " ")
	runes := []rune(line)
	if len(runes) <= quickTaskTitleMaxRunes {
		return line
	}
	line = string(runes[:quickTaskTitleMaxRunes])
	if index := strings.LastIndexByte(line, ' '); index >= quickTaskTitleMaxRunes/2 {
		line = line[:index]
	}
	return strings.TrimSpace(line)
}
