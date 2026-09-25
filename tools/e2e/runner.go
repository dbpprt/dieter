package main

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// Platforms own native execution; admission, deadlines, incremental reports and
// required-case qualification are identical for every native client.
func runCases(ctx context.Context, output string, started time.Time, report *Report, cases []Case, run func(context.Context, Case) Result) error {
	for index, c := range cases {
		if ctx.Err() != nil {
			interruptRemaining(report, cases[index:], ctx.Err().Error())
			break
		}
		fmt.Printf("Running %s (%s, fresh app state)\n", c.ID, c.Fixture)
		duration, _ := time.ParseDuration(c.Timeout)
		caseCtx, cancel := context.WithTimeout(ctx, duration)
		result := run(caseCtx, c)
		if caseCtx.Err() != nil {
			result.Status = "interrupted"
			result.Reason = caseCtx.Err().Error()
		}
		cancel()
		result.ID = c.ID
		if result.Status == "" {
			result.Status = "failed"
			result.Reason = "native driver returned no result"
		}
		if result.CleanupError != "" {
			result.Status = "failed"
		}
		report.Results = append(report.Results, result)
		fmt.Printf("%s %s: %d ms %s %s\n", strings.ToUpper(result.Status), c.ID, result.DurationMS, result.Reason, result.CleanupError)
		report.DurationMS = time.Since(started).Milliseconds()
		if err := writeReport(output, *report); err != nil {
			return err
		}
		if ctx.Err() != nil || result.CleanupError != "" {
			interruptRemaining(report, cases[index+1:], "previous case interrupted or cleanup failed")
			break
		}
	}
	report.DurationMS = time.Since(started).Milliseconds()
	if err := writeReport(output, *report); err != nil {
		return err
	}
	failed := 0
	for _, result := range report.Results {
		if result.Status != "passed" || result.CleanupError != "" {
			failed++
		}
	}
	fmt.Printf("%d requested, %d passed, %d failed/unavailable; build=%d ms install=%d ms total=%d ms\n", len(cases), len(cases)-failed, failed, report.BuildMS, report.InstallMS, report.DurationMS)
	if failed > 0 {
		return fmt.Errorf("%d required cases did not pass; %s", failed, output)
	}
	return nil
}

func interruptRemaining(report *Report, cases []Case, reason string) {
	for _, c := range cases {
		report.Results = append(report.Results, Result{ID: c.ID, Status: "interrupted", Reason: reason})
	}
}
