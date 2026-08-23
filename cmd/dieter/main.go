package main

import (
	"os"

	"github.com/dbpprt/dieter/internal/cli"
)

func main() { os.Exit(cli.Main(os.Args[1:])) }
