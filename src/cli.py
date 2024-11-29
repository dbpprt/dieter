"""Command line interface for the browser agent."""

import argparse
import logging

from rich.console import Console

from .browser_agent.agent import BrowserAgent
from .browser_agent.config import load_config
from .logging_config import configure_logging


def parse_args() -> argparse.Namespace:
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description="Browser automation agent using LLM guidance")
    parser.add_argument("--config", type=str, default="config.yaml", help="Path to configuration file")
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        default=False,  # Explicitly set default to False
        help="Enable verbose logging (default: False)",
    )
    return parser.parse_args()


def main() -> None:
    """Main entry point for the CLI."""
    args = parse_args()
    configure_logging(args.verbose)
    logger = logging.getLogger(__name__)
    console = Console()

    try:
        logger.debug("Loading configuration from: %s", args.config)
        config = load_config(args.config)

        logger.debug("Initializing browser agent")
        agent = BrowserAgent(config)
        logger.info("Starting browser agent session")
        agent.run()
    except KeyboardInterrupt:
        logger.info("Received keyboard interrupt, shutting down...")
    except Exception as e:
        logger.exception("Unexpected error occurred")
        console.print(f"[red]Error: {str(e)}[/red]")
    finally:
        logger.debug("Cleanup complete")


if __name__ == "__main__":
    main()
