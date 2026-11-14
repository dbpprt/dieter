package replica_test

import (
	"testing"

	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/replica"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestSharedOrderingConcurrentInsertionsRemainAddressable(t *testing.T) {
	t.Parallel()
	first, err := replica.OrderBetween("", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := replica.OrderBetween("", "")
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("concurrent positions collide")
	}
	if first > second {
		first, second = second, first
	}
	middle, err := replica.OrderBetween(first, second)
	if err != nil || !(first < middle && middle < second) {
		t.Fatalf("%q < %q < %q: %v", first, middle, second, err)
	}
	for i := 0; i < 100; i++ {
		next, err := replica.OrderBetween(first, middle)
		if err != nil || !(first < next && next < middle) {
			t.Fatal(err)
		}
		middle = next
	}
}

func TestSharedOrderingTenThousandEndInsertions(t *testing.T) {
	t.Parallel()
	left := ""
	for i := 0; i < 10000; i++ {
		next, err := replica.OrderBetween(left, "")
		if err != nil || next <= left || len(next) > 32 {
			t.Fatalf("append %d %q: %v", i, next, err)
		}
		left = next
	}
}

func TestPeerWakeCoalescesCommittedChangesOnly(t *testing.T) {
	t.Parallel()
	s := testkit.PeerStore(t, "a")
	wake := s.Replica.PeerChangesAvailable()
	project, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: testkit.ProjectDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-wake:
	default:
		t.Fatal("commit did not wake replication")
	}
	name := "Renamed"
	for i := 0; i < 3; i++ {
		if _, err = s.Kanban.UpdateProject(project.ID, &name, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case <-wake:
	default:
		t.Fatal("edit did not wake replication")
	}
	select {
	case <-wake:
		t.Fatal("wakeup queue did not coalesce")
	default:
	}
}
