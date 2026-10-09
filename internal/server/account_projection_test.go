package server

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/proto"
)

// Clients project the account view themselves from every machine's change
// stream. This fixture holds the records of machines that diverged and the
// projection a daemon materializes once it has merged them all; the Kotlin
// core projects the same records and must agree. Regenerate it with
// DIETER_UPDATE_PROJECTION_FIXTURE=1 go test ./internal/server -run TestAccountProjectionFixture
var accountProjectionFixture = filepath.Join("..", "..", "apps", "core", "shared", "src", "jvmTest", "resources", "account-projection.json")

type projectionFixture struct {
	// Machine ID → base64 dieter.v1.ChangesFrame with that machine's records:
	// two diverged machines and the observer that merged both.
	Machines map[string]string `json:"machines"`
	// base64 dieter.v1.State: GetState(all_projects) on a daemon holding every record.
	State string `json:"state"`
	// base64 dieter.v1.ListRetiredBoardsResponse from that daemon.
	RetiredBoards string `json:"retiredBoards"`
}

func TestAccountProjectionFixture(t *testing.T) {
	if os.Getenv("DIETER_UPDATE_PROJECTION_FIXTURE") == "1" {
		raw, err := json.MarshalIndent(generateProjectionFixture(t), "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(accountProjectionFixture, append(raw, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := os.ReadFile(accountProjectionFixture)
	if err != nil {
		t.Fatal(err)
	}
	var fixture projectionFixture
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	// The daemon's own projection of the fixture's records must still be the
	// one the fixture holds, so the clients' agreement means agreement today.
	observer := projectionStore(t, "observer")
	identity, err := observer.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	machines := make([]string, 0, len(fixture.Machines))
	for machine := range fixture.Machines {
		machines = append(machines, machine)
	}
	sort.Strings(machines)
	for _, machine := range machines {
		var frame dieterv1.ChangesFrame
		decodeFixture(t, fixture.Machines[machine], &frame)
		records := make([]peerstore.Record, 0, len(frame.GetRecords()))
		for _, record := range frame.GetRecords() {
			records = append(records, fixtureRecord(record))
		}
		mergeRecords(t, observer, identity, records)
	}
	state, retired := observedProjection(t, observer)
	var expectedState dieterv1.State
	var expectedRetired dieterv1.ListRetiredBoardsResponse
	decodeFixture(t, fixture.State, &expectedState)
	decodeFixture(t, fixture.RetiredBoards, &expectedRetired)
	if !proto.Equal(state, &expectedState) || !proto.Equal(retired, &expectedRetired) {
		t.Fatalf("the daemon's projection of the fixture changed; regenerate it with DIETER_UPDATE_PROJECTION_FIXTURE=1\nstate=%v\nretired=%v", state, retired)
	}
}

// generateProjectionFixture scripts two machines that share a project and
// then diverge: concurrent renames, labels assigned and deleted, moves,
// pins, an archived project, a consolidated project, retired boards, and a
// project only one machine knows. A third daemon merges both.
func generateProjectionFixture(t *testing.T) projectionFixture {
	t.Helper()
	a, b := projectionStore(t, "machine_a"), projectionStore(t, "machine_b")
	project, err := a.CreateProject(store.CreateProjectInput{Name: "Atlas", Path: projectionRepository(t), InitialBoardName: "Main", InitialWorkflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	main, err := a.InitialBoard(project.ID)
	if err != nil {
		t.Fatal(err)
	}
	direct := must(a.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Ops", Workflow: model.WorkflowDirect, DoneArchivePolicy: model.DoneArchiveNever}))(t)
	retired := must(a.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Old"}))(t)
	if _, err := a.SetBoardRetired(store.BoardRetirementInput{BoardID: retired.ID, Retired: true, ExpectedRevision: "absent", OperationID: "retire-old"}); err != nil {
		t.Fatal(err)
	}
	must(a.CreateBoardLabel(main.ID, "bug", "#d1242f", "Reproduce first"))(t)
	labeled := must(a.CreateBoardLabel(main.ID, "chore", "#6e7781"))(t)
	var bug, chore string
	for _, label := range labeled.Labels {
		if label.Name == "bug" {
			bug = label.ID
		} else {
			chore = label.ID
		}
	}
	docs := must(a.CreateCard(store.CreateCardInput{Project: project.ID, Board: main.ID, Title: "Write docs", Prompt: "Owner-only prompt"}))(t)
	fix := must(a.CreateCard(store.CreateCardInput{Project: project.ID, Board: main.ID, Title: "Fix bug", LabelIDs: []string{bug}}))(t)
	ops := must(a.CreateCard(store.CreateCardInput{Project: project.ID, Board: direct.ID, Title: "Rotate keys"}))(t)
	question := must(a.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Question"}))(t)
	pinned := must(a.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Pinned"}))(t)
	if _, err := a.PinChat(pinned.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := a.UpdateCardCache(fix.ID, store.CardCacheInput{Runtime: model.RuntimeFailed, Provider: "codex", Model: "gpt-5"}); err != nil {
		t.Fatal(err)
	}
	archived := must(a.CreateProject(store.CreateProjectInput{Name: "Shelved", Path: projectionRepository(t)}))(t)
	must(a.CreateChat(store.CreateCardInput{Project: archived.ID, Title: "Shelved chat"}))(t)
	if _, err := a.ArchiveProject(archived.ID, true); err != nil {
		t.Fatal(err)
	}
	sidecar := must(a.CreateProject(store.CreateProjectInput{Name: "Sidecar", Path: projectionRepository(t)}))(t)
	must(a.CreateChat(store.CreateCardInput{Project: sidecar.ID, Title: "Sidecar chat"}))(t)
	if _, err := a.ConsolidateProject(sidecar.ID, project.ID); err != nil {
		t.Fatal(err)
	}
	joinProjectionStores(t, a, b)

	// From here the machines diverge; neither sees the other's edits.
	if _, err := a.RenameCard(docs.ID, "Docs"); err != nil {
		t.Fatal(err)
	}
	if _, err := b.RenameCard(docs.ID, "Write the docs"); err != nil {
		t.Fatal(err)
	}
	if _, err := b.SetCardLabels(fix.ID, []string{bug, chore}); err != nil {
		t.Fatal(err)
	}
	if _, err := a.DeleteBoardLabel(main.ID, chore); err != nil {
		t.Fatal(err)
	}
	if _, err := b.MoveCard(ops.ID, model.LaneDone, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := b.ArchiveCard(question.ID, true); err != nil {
		t.Fatal(err)
	}
	beacon := must(b.CreateProject(store.CreateProjectInput{Name: "Beacon", Path: projectionRepository(t), InitialBoardName: "Main", InitialWorkflow: model.WorkflowReview}))(t)
	beaconBoard, err := b.InitialBoard(beacon.ID)
	if err != nil {
		t.Fatal(err)
	}
	must(b.CreateCard(store.CreateCardInput{Project: beacon.ID, Board: beaconBoard.ID, Title: "Ship it"}))(t)
	must(b.CreateChat(store.CreateCardInput{Project: beacon.ID, Title: "Beacon chat"}))(t)

	observer := projectionStore(t, "observer")
	joinProjectionStores(t, a, observer)
	joinProjectionStores(t, b, observer)
	state, retiredBoards := observedProjection(t, observer)
	fixture := projectionFixture{Machines: map[string]string{}, State: encodeFixture(t, state), RetiredBoards: encodeFixture(t, retiredBoards)}
	for name, machine := range map[string]*store.Store{"machine_a": a, "machine_b": b, "observer": observer} {
		identity, err := machine.PeerIdentity()
		if err != nil {
			t.Fatal(err)
		}
		data, err := machine.PeerData(identity.Account)
		if err != nil {
			t.Fatal(err)
		}
		frame := &dieterv1.ChangesFrame{DaemonId: identity.DaemonID, Account: identity.Account}
		for _, record := range data.Sorted() {
			frame.Records = append(frame.Records, fixtureProto(record))
		}
		fixture.Machines[name] = encodeFixture(t, frame)
	}
	return fixture
}

func projectionStore(t *testing.T, daemon string) *store.Store {
	t.Helper()
	data := store.New(t.TempDir())
	if _, err := data.BindPeerAccount("account", "subject", daemon, "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	return data
}

func projectionRepository(t *testing.T) string {
	t.Helper()
	path := t.TempDir()
	if err := os.Mkdir(filepath.Join(path, ".git"), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func joinProjectionStores(t *testing.T, from, to *store.Store) {
	t.Helper()
	identity, err := to.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	source, err := from.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	mergeRecords(t, to, identity, source.Sorted())
}

func mergeRecords(t *testing.T, to *store.Store, identity store.PeerIdentity, records []peerstore.Record) {
	t.Helper()
	for len(records) > 0 {
		n := min(len(records), peerstore.PageSize)
		if err := to.MergePeerRecords(identity, records[:n]); err != nil {
			t.Fatal(err)
		}
		records = records[n:]
	}
}

func observedProjection(t *testing.T, observer *store.Store) (*dieterv1.State, *dieterv1.ListRetiredBoardsResponse) {
	t.Helper()
	api := &grpcAPI{server: NewWithRunner(observer, nil, &fakeRunner{})}
	state, err := api.GetState(t.Context(), &dieterv1.GetStateRequest{AllProjects: true})
	if err != nil {
		t.Fatal(err)
	}
	state.StorePath = ""
	retired, err := api.ListRetiredBoards(t.Context(), &dieterv1.ListRetiredBoardsRequest{PageSize: 100})
	if err != nil {
		t.Fatal(err)
	}
	return state, retired
}

// fixtureProto is a streamed record that keeps its proofs, so a daemon can
// merge it again.
func fixtureProto(record peerstore.Record) *dieterv1.PeerRecord {
	result := changeRecord(record)
	for i, version := range record.Versions {
		result.Versions[i].ProvenanceJson = version.Provenance
	}
	return result
}

func fixtureRecord(record *dieterv1.PeerRecord) peerstore.Record {
	result := peerstore.Record{Kind: record.GetKind(), ID: record.GetId()}
	for _, version := range record.GetVersions() {
		result.Versions = append(result.Versions, peerstore.Version{
			Clock: version.GetClock(), Value: version.GetValueJson(), Deleted: version.GetDeleted(), Provenance: version.GetProvenanceJson(),
		})
	}
	return result
}

func encodeFixture(t *testing.T, message proto.Message) string {
	t.Helper()
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(raw)
}

func decodeFixture(t *testing.T, value string, message proto.Message) {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := proto.Unmarshal(raw, message); err != nil {
		t.Fatal(err)
	}
}

// must returns a fixture step's value, failing the test on its error.
func must[T any](value T, err error) func(*testing.T) T {
	return func(t *testing.T) T {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
}
