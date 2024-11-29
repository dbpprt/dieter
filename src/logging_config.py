"""Logging configuration for the application."""

import logging
import os

from rich.logging import RichHandler


def configure_logging(verbose: bool = False) -> None:
    """Configure logging with different verbosity levels."""
    # Set YOLO environment variable to suppress its output
    os.environ["YOLO_VERBOSE"] = "False"

    # Set up root logger
    root_logger = logging.getLogger()
    root_logger.setLevel(logging.WARNING)  # Default to WARNING for all loggers

    # Remove any existing handlers
    for handler in root_logger.handlers[:]:
        root_logger.removeHandler(handler)

    # Create and configure rich handler
    rich_handler = RichHandler(
        rich_tracebacks=True,
        markup=True,
        show_time=False,
        show_path=verbose,
        enable_link_path=verbose,
        level=logging.DEBUG if verbose else logging.WARNING,
    )
    rich_handler.setFormatter(logging.Formatter("%(message)s"))
    root_logger.addHandler(rich_handler)

    # Configure app loggers - only these will be verbose when enabled
    app_namespaces = [
        "src",
        "src.browser_agent",
        "src.omniparser",
        "src.utils",
    ]

    for namespace in app_namespaces:
        logger = logging.getLogger(namespace)
        logger.setLevel(logging.DEBUG if verbose else logging.WARNING)

    # Disable matplotlib font manager logging as it's particularly noisy
    logging.getLogger("matplotlib.font_manager").disabled = True
