package cli

import (
	"errors"
	"fmt"
)

func (c *CLI) daemonService(args []string) error {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprint(c.Out, `Usage: dieter daemon service <action>

Install and manage Dieter's per-user daemon service. Service commands never
delete DIETER_HOME or project data.

Actions:
  install    Install or refresh the service definition and enable it
  start      Start the installed service
  restart    Gracefully restart the installed service
  stop       Stop the installed service
  status     Show the native service-manager status
  uninstall  Disable and remove the service definition, preserving all data
`)
		return nil
	}
	switch args[0] {
	case "install", "start", "restart", "stop", "status", "uninstall":
		return platformServiceCommand(c, args[0], args[1:])
	default:
		return fmt.Errorf("unknown daemon service action %q", args[0])
	}
}

func parseNoArgs(outUsage string, args []string) error {
	for _, arg := range args {
		if arg == "--help" || arg == "-h" {
			return errHelpRequested{usage: outUsage}
		}
	}
	if len(args) != 0 {
		return errors.New(outUsage)
	}
	return nil
}

type errHelpRequested struct{ usage string }

func (e errHelpRequested) Error() string { return e.usage }
