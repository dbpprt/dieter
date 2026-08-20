package main

import (
	"os"

	"github.com/dbpprt/nauclio/internal/cli"
)

func main() { os.Exit(cli.Main(os.Args[1:])) }
