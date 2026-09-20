package cli

import "errors"

func (c *CLI) importStore(args []string) error {
	const usage = `Usage: dieter --root PATH daemon import-store --backup PATH [--apply]

Offline maintenance only. The default reports the legacy project/board/card counts
without converting data. --apply creates a complete backup, upgrades this root in
place to the shared project schema, and preserves conversation and schedule IDs.
Stop the source daemon explicitly first; this command never stops a process.
An interrupted import resumes from the same backup. Normal operations reject an
unfinished import. Restore the backup only while stopped; rollback loses all
post-import changes. Backups must be outside the source root.
`
	set := flags("daemon import-store")
	backup := set.String("backup", "", "new backup directory outside the source root")
	apply := set.Bool("apply", false, "apply the reviewed offline import")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if c.Machine != "" {
		return errors.New("offline store import cannot target a remote machine")
	}
	if set.NArg() != 0 {
		return errors.New("import-store accepts only --backup and --apply")
	}
	report, err := c.Store.ImportLegacy(*backup, *apply)
	if err != nil {
		return err
	}
	return jsonOut(c.Out, report)
}
