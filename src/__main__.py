"""Main entry point for the application."""
import logging

from .cli import main

logger = logging.getLogger(__name__)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logger.info("Application terminated by user")
    except Exception:
        logger.exception("Unexpected error occurred")
        raise
