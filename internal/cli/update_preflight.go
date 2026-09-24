package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"io"
	"path/filepath"

	"github.com/dbpprt/dieter/internal/protocol"
	"github.com/dbpprt/dieter/internal/store"
)

// updatePreflight is an offline installer probe, not a normal data operation.
// It must never Ensure a store, load credentials, start workers, or migrate data.
func updatePreflight(args []string, out io.Writer) error {
	flags := flag.NewFlagSet("update preflight", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	root := flags.String("root", "", "existing absolute DIETER_HOME")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || !filepath.IsAbs(*root) {
		return errors.New("update preflight requires --root ABSOLUTE_PATH")
	}
	if err := store.New(*root).CheckUpdateCompatibility(); err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(struct {
		Protocol int    `json:"protocol"`
		Version  string `json:"version"`
		API      string `json:"apiVersion"`
	}{1, Version, protocol.Version})
}
