//go:build e2e

package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/testkit/topology"
)

func TestDaemonRecoverThroughGatewayRestoresOriginalIdentity(t *testing.T) {
	t.Parallel()
	g := topology.StartGateway(t, topology.GatewayOptions{})
	root := t.TempDir()
	// Enrolling the same home again after revocation reuses its key, like a
	// reinstalled machine.
	enroll := func() *link.Identity {
		t.Helper()
		identity, err := g.Enroll(t.Context(), root, "Original", topology.Account)
		if err != nil {
			t.Fatal(err)
		}
		return identity
	}
	original := enroll()
	originalID, originalGeneration, originalCertificate := original.ID, original.Generation, original.CertificatePEM
	if _, err := g.Store.RevokeDaemon(originalID, topology.Account); err != nil {
		t.Fatal(err)
	}
	if err := original.ClearCredential(); err != nil {
		t.Fatal(err)
	}
	replacement := enroll()
	if originalID == replacement.ID {
		t.Fatal("reenrollment reused the original ID")
	}
	client := New(root)
	defer client.Close()
	var output bytes.Buffer
	client.Out, client.Err = &output, &output
	if err := client.Run([]string{"daemon", "recover", "--old-id", originalID, "--confirm", "RECOVER"}); err != nil {
		t.Fatal(err)
	}
	recovered, err := link.LoadIdentity(root)
	if err != nil || recovered.ID != originalID || recovered.Generation != originalGeneration+1 ||
		!bytes.Equal(recovered.CertificatePEM, originalCertificate) {
		t.Fatalf("local original identity not restored: %+v: %v", recovered, err)
	}
	oldRecord, err := g.Store.Daemon(originalID)
	if err != nil || oldRecord.Revoked || oldRecord.Generation != recovered.Generation {
		t.Fatalf("gateway original identity not restored: %+v: %v", oldRecord, err)
	}
	newRecord, err := g.Store.Daemon(replacement.ID)
	if err != nil || newRecord.Revoked {
		t.Fatalf("replacement revoked before verification: %+v: %v", newRecord, err)
	}
	client.Close()
	reconnected := New(root)
	defer reconnected.Close()
	reconnected.Out, reconnected.Err = &output, &output
	output.Reset()
	if err := reconnected.Run([]string{"machine", "list", "--format", "jsonl"}); err != nil ||
		!strings.Contains(output.String(), originalID) ||
		!strings.Contains(output.String(), replacement.ID) {
		t.Fatalf("restored credential cannot access gateway directory: %v, %q", err, output.String())
	}
}
