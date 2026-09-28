package cli

import (
	"errors"
	"fmt"
	"strings"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func (c *CLI) rpcBoardRetirement(args []string, retired bool) error {
	action := "restore"
	if retired {
		action = "retire"
	}
	usage := "Usage: dieter board " + action + " --revision REV --operation ID BOARD\n\nUse an exact board ID and its retirementRevision from board show. Retirement refuses active, archived, pending card or schedule references. Records and labels are retained; restore is reversible. A late peer reference makes retirement blocked and the board visible.\nThe operation ID is a durable local replay receipt: retry identical input only on the same daemon. Success means local durability, not acknowledgement by every replica.\n"
	set := flags("board " + action)
	revision := set.String("revision", "", "observed retirementRevision")
	operation := set.String("operation", "", "stable operation ID for replay on this daemon")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || !strings.HasPrefix(set.Arg(0), "b_") || *revision == "" || *operation == "" {
		return errors.New("exact BOARD ID, --revision and --operation are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	board, err := client.SetBoardRetired(rpcCtx, &dieterv1.SetBoardRetiredRequest{BoardId: set.Arg(0), Retired: retired, ExpectedRevision: *revision, OperationId: *operation})
	if err != nil {
		return fmt.Errorf("board %s operation %s: %w; inspect board show before retrying on this same daemon", action, *operation, err)
	}
	return protoJSONOut(c.Out, board)
}
