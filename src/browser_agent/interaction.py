"""Browser interaction handling."""

import logging
from dataclasses import dataclass
from typing import Dict, Tuple

from PIL import Image, ImageDraw
from playwright.sync_api import Page, TimeoutError
from rich.console import Console
from rich.status import Status


@dataclass
class ViewportInfo:
    """Information about the current viewport state."""

    scroll_y: int
    scroll_height: int
    viewport_height: int
    can_scroll_down: bool

    @classmethod
    def from_page(cls, page: Page) -> "ViewportInfo":
        """Create ViewportInfo from page metrics."""
        metrics = page.evaluate("""() => {
            const scrollY = window.scrollY;
            const scrollHeight = document.documentElement.scrollHeight;
            const viewportHeight = window.innerHeight;
            return {
                scroll_y: scrollY,
                scroll_height: scrollHeight,
                viewport_height: viewportHeight,
                can_scroll_down: scrollY + viewportHeight < scrollHeight - 10
            }
        }""")
        return cls(**metrics)


@dataclass
class NavigationState:
    """Information about navigation capabilities."""

    can_go_back: bool
    can_go_forward: bool

    @classmethod
    def from_page(cls, page: Page) -> "NavigationState":
        """Create NavigationState from page state."""
        return cls(
            can_go_back=page.evaluate("() => window.history.length > 1"),
            can_go_forward=page.evaluate("() => window.history.length > 1 && window.history.state !== null"),
        )


class BrowserInteraction:
    """Handles direct browser interactions."""

    def __init__(self, page: Page, status: Status):
        self.logger = logging.getLogger(__name__)
        self.page = page
        self.status = status
        self.console = Console()

    def find_element_coordinates(
        self, element_id: str, label_coordinates: Dict, screenshot: Image.Image, bbox_format: str = "xywh"
    ) -> Tuple[int, int]:
        """Calculate viewport coordinates for an element."""
        if element_id not in label_coordinates:
            raise ValueError(f"Element with ID {element_id} not found")

        viewport = self.page.viewport_size
        if not viewport:
            raise ValueError("Could not get viewport dimensions")

        # Calculate scaling factors
        scale_x = viewport["width"] / screenshot.size[0]
        scale_y = viewport["height"] / screenshot.size[1]

        # Get element box coordinates
        box = label_coordinates[element_id]

        # Calculate center point
        if bbox_format == "xywh":
            center_x = box[0] + box[2] / 2
            center_y = box[1] + box[3] / 2
        else:
            center_x = (box[0] + box[2]) / 2
            center_y = (box[1] + box[3]) / 2

        # Convert to viewport coordinates
        viewport_x = int(center_x * scale_x)
        viewport_y = int(center_y * scale_y)

        # Save debug visualization
        debug_image = screenshot.copy()
        draw = ImageDraw.Draw(debug_image)
        dot_size = 5
        draw.ellipse([center_x - dot_size, center_y - dot_size, center_x + dot_size, center_y + dot_size], fill="red")
        debug_image.save(".debug_click.png")

        self.logger.debug("Click coordinates calculated: (%d, %d)", viewport_x, viewport_y)
        if logging.getLogger().getEffectiveLevel() <= logging.INFO:
            self.console.print(f"\n[bold yellow]Click coordinates:[/bold yellow] ({viewport_x}, {viewport_y})")

        return viewport_x, viewport_y

    def click(self, element_id: str, label_coordinates: Dict, screenshot: Image.Image) -> None:
        """Click an element on the page."""
        self.logger.debug("Attempting to click element %s", element_id)
        x, y = self.find_element_coordinates(element_id, label_coordinates, screenshot)

        self.status.update("Clicking element...")
        self.page.mouse.click(x, y)
        self._wait_for_load()

        self.logger.info("Clicked element %s at (%d, %d)", element_id, x, y)

    def type_text(
        self, text: str, element_id: str, label_coordinates: Dict, screenshot: Image.Image, enter: bool = False
    ) -> None:
        """Type text into an element."""
        self.logger.debug("Attempting to type text into element %s", element_id)
        x, y = self.find_element_coordinates(element_id, label_coordinates, screenshot)

        status_text = f"Typing text{' (with Enter)' if enter else ''}..."
        self.status.update(status_text)
        self.page.mouse.click(x, y)
        # Add a small pause after clicking to ensure proper focus
        self.page.wait_for_timeout(200)
        self.page.keyboard.type(text)

        if enter:
            self.page.keyboard.press("Enter")

        self._wait_for_load()

        self.logger.info("Typed text into element %s", element_id)
        self.logger.debug("Text typed: %s", text)

    def scroll(self, direction: str) -> None:
        """Scroll the page up or down."""
        self.logger.debug("Scrolling %s", direction)
        key = "PageDown" if direction == "down" else "PageUp"

        self.status.update(f"Scrolling {direction}...")
        self.page.keyboard.press(key)
        self._wait_for_load()

        self.logger.info("Scrolled %s", direction)

    def navigate_back(self) -> None:
        """Navigate back in browser history."""
        self.logger.debug("Navigating back in history")
        self.status.update("Navigating back...")

        self.page.go_back(wait_until="domcontentloaded", timeout=5000)
        self._wait_for_load()

        self.logger.info("Navigated back")

    def _wait_for_load(self, timeout: int = 5000) -> None:
        """Wait for page to load, with timeout handling."""
        try:
            self.logger.debug("Waiting for page load (timeout: %dms)", timeout)
            self.page.wait_for_load_state("domcontentloaded", timeout=timeout)
        except TimeoutError:
            self.logger.warning("Page load timeout after %dms", timeout)

        # Small delay for stability
        self.page.wait_for_timeout(500)
