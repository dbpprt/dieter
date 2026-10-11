//go:build race

package testkit

// raceScale stretches wall-clock budgets under the race detector, which
// slows execution several times over.
const raceScale = 4
