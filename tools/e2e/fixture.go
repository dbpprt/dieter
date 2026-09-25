package main

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// Readiness and endpoint validation are shared by Android and Mac fixtures.
func awaitGateway(ctx context.Context, p *ownedProcess) (map[string]string, error) {
	ready, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		output := p.out.String()
		if strings.Contains(output, "\nREADY\n") {
			values := map[string]string{}
			for _, line := range strings.Split(output, "\n") {
				if strings.HasPrefix(line, "DIETER_ISOLATED_") {
					key, value, ok := strings.Cut(line, "=")
					if ok {
						values[key] = value
					}
				}
			}
			if !strings.HasPrefix(values["DIETER_ISOLATED_ADDR"], "127.0.0.1:") || values["DIETER_ISOLATED_TOKEN"] == "" {
				return nil, fmt.Errorf("invalid fixture readiness")
			}
			return values, nil
		}
		select {
		case <-ready.Done():
			return nil, fmt.Errorf("fixture readiness: %w", ready.Err())
		case <-p.done:
			return nil, fmt.Errorf("fixture exited before readiness")
		case <-tick.C:
		}
	}
}
