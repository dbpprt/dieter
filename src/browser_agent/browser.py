"""Browser setup and lifecycle management."""

import logging
from pathlib import Path
from typing import Dict, Optional

from playwright.sync_api import BrowserContext, Error as PlaywrightError, Page, sync_playwright
from rich.console import Console

from .browser_extensions import ExtensionManager
from .config import Config


class BrowserManager:
    """Manages browser lifecycle and configuration."""

    def __init__(self, config: Config):
        self.logger = logging.getLogger(__name__)
        self.config = config
        self.console = Console()
        self.page: Optional[Page] = None
        self.context: Optional[BrowserContext] = None
        self.playwright = None
        self.current_url: str = "about:blank"

    def setup(self) -> None:
        """Initialize and configure the browser."""
        self.logger.debug("Setting up browser environment")
        data_dir = Path(self.config.browser.data_dir)
        data_dir.mkdir(parents=True, exist_ok=True)

        self.playwright = sync_playwright().start()
        browser_type = getattr(self.playwright, self.config.browser.browser_type)

        self.logger.debug(
            "Launching browser with configuration: %s",
            {
                "browser_type": self.config.browser.browser_type,
                "width": self.config.browser.width,
                "height": self.config.browser.height,
                "data_dir": str(data_dir),
            },
        )

        # Setup extensions if configured
        extension_paths = self._setup_extensions(data_dir)

        context_args = {
            "user_data_dir": str(data_dir),
            "headless": False,
            "viewport": {"width": self.config.browser.width, "height": self.config.browser.height},
            "device_scale_factor": self.config.browser.device_scale_factor,
            "is_mobile": self.config.browser.is_mobile,
            "has_touch": self.config.browser.has_touch,
            "user_agent": self._get_user_agent(),
            "bypass_csp": True,
            "ignore_https_errors": True,
            "permissions": ["geolocation"],
        }

        # Add browser arguments including extensions if any were set up
        context_args["args"] = self._get_browser_args(list(extension_paths.values()) if extension_paths else None)

        self.context = browser_type.launch_persistent_context(**context_args)

        self.page = self.context.new_page()
        self._setup_page()
        self._navigate_to_start_page()

    def _setup_extensions(self, data_dir: Path) -> Dict[str, str]:
        """Set up browser extensions if configured."""
        if not hasattr(self.config.browser, "extensions") or not self.config.browser.extensions:
            self.logger.debug("No extensions configured")
            return {}

        try:
            self.logger.debug("Setting up extensions from config: %s", list(self.config.browser.extensions.keys()))

            extension_manager = ExtensionManager(data_dir, self.config.browser.extensions)
            extension_paths = extension_manager.setup_extensions()

            if extension_paths:
                self.logger.debug("Successfully set up extensions: %s", list(extension_paths.keys()))
            else:
                self.logger.debug("No extensions were set up")

            return extension_paths
        except Exception as e:
            self.logger.error("Failed to set up extensions: %s", str(e))
            return {}

    def navigate(self, url: str) -> None:
        """Navigate to a specified URL."""
        if not self.page:
            return

        self.logger.debug("Navigating to URL: %s", url)
        self.page.goto(url, wait_until="networkidle")
        self.page.wait_for_load_state("networkidle")
        self.current_url = url

    def cleanup(self) -> None:
        """Clean up browser resources."""
        self.logger.debug("Cleaning up browser resources")
        try:
            # Close page first if it exists
            if self.page:
                try:
                    self.page.close(run_before_unload=False)
                except PlaywrightError as e:
                    self.logger.debug("Page already closed: %s", str(e))
                finally:
                    self.page = None

            # Close context if it exists
            if self.context:
                try:
                    self.context.close()
                except PlaywrightError as e:
                    self.logger.debug("Context already closed: %s", str(e))
                finally:
                    self.context = None

            # Stop playwright if it exists
            if self.playwright:
                try:
                    self.playwright.stop()
                except Exception as e:
                    self.logger.debug("Error stopping playwright: %s", str(e))
                finally:
                    self.playwright = None

            self.logger.debug("Browser cleanup completed successfully")
        except Exception as e:
            self.logger.error("Error during browser cleanup: %s", str(e))

    def _setup_page(self) -> None:
        """Configure page environment and anti-detection measures."""
        if not self.page:
            return

        self.logger.debug("Setting up page environment")
        self.page.add_init_script("""
            Object.defineProperty(navigator, 'webdriver', {
                get: () => false
            });

            Object.defineProperty(navigator, 'languages', {
                get: () => ['en-US', 'en']
            });

            Object.defineProperty(navigator, 'plugins', {
                get: () => [{
                    0: {
                        type: "application/x-google-chrome-pdf",
                        suffixes: "pdf",
                        description: "Portable Document Format"
                    },
                    description: "Portable Document Format",
                    filename: "internal-pdf-viewer",
                    length: 1,
                    name: "Chrome PDF Plugin"
                }]
            });
        """)

    def _navigate_to_start_page(self) -> None:
        """Navigate to the initial blank page."""
        if not self.page:
            return

        self.logger.debug("Navigating to start page: about:blank")
        self.page.goto("about:blank", wait_until="networkidle")
        self.page.wait_for_load_state("networkidle")
        self.current_url = "about:blank"

        browser_info = {
            "type": self.config.browser.browser_type,
            "size": f"{self.config.browser.width}x{self.config.browser.height}",
        }
        self.logger.debug("Browser launched successfully: %s", browser_info)

    def _get_user_agent(self) -> str:
        """Get the user agent string for the browser."""
        user_agent = (
            "Mozilla/5.0 (iPad; CPU OS 17_3_1 like Mac OS X) "
            "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            "Version/17.2 Mobile/15E148 Safari/604.1"
        )
        self.logger.debug("Using user agent: %s", user_agent)
        return user_agent

    def _get_browser_args(self, extension_paths: list[str] = None) -> list[str]:
        """Get browser launch arguments."""
        args = ["--no-first-run", "--enable-extensions"]

        if extension_paths:
            # Format paths and add extension arguments
            for path in extension_paths:
                abs_path = str(Path(path).absolute())
                args.extend([f"--disable-extensions-except={abs_path}", f"--load-extension={abs_path}"])

        self.logger.debug("Browser launch arguments: %s", args)
        return args
