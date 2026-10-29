package kanban

import (
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/crdt"
)

func TestSharedBoardLifecycleFixture(t *testing.T) {
	t.Parallel()
	raw, err := os.ReadFile("../../../tests/fixtures/board-lifecycle.tsv")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		columns := strings.Split(line, "\t")
		t.Run(columns[0], func(t *testing.T) {
			var record crdt.Record
			for _, observation := range strings.Split(columns[1], ";") {
				if observation == "-" {
					continue
				}
				pair := strings.Split(observation, "=")
				clock := crdt.Clock{}
				for _, entry := range strings.Split(pair[0], ",") {
					parts := strings.Split(entry, ":")
					clock[parts[0]], err = strconv.ParseUint(parts[1], 10, 64)
					if err != nil {
						t.Fatal(err)
					}
				}
				incoming := crdt.Record{Kind: "board", ID: "b_fixture.retired", Versions: []crdt.Version{{Clock: clock, Value: []byte(pair[1])}}}
				record, err = crdt.Merge(record, incoming)
				if err != nil {
					t.Fatal(err)
				}
			}
			var refs []string
			if columns[2] == "true" {
				refs = []string{"item/card"}
			}
			board := model.Board{}
			projectBoardRetirement(&board, record, refs)
			if board.Retired != (columns[3] == "true") || board.RetirementBlocked != (columns[4] == "true") {
				t.Fatalf("projection: %+v", board)
			}
		})
	}
}
