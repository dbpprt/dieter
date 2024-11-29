"""Page analysis and state tracking."""

import base64
import io
import logging
from dataclasses import dataclass
from typing import Dict, List, Tuple

from PIL import Image
from playwright.sync_api import Page, TimeoutError
from rich.console import Console
from rich.status import Status

import src.omniparser as omniparser

from .interaction import NavigationState, ViewportInfo


@dataclass
class PageState:
    """Complete state of a page at a point in time."""

    encoded_image: str
    label_coordinates: Dict
    parsed_content: List[str]
    screenshot: Image.Image
    history_text: str
    viewport_info: ViewportInfo
    navigation_state: NavigationState


@dataclass
class HistoryEntry:
    """Single entry in page history."""

    url: str
    title: str


class PageAnalyzer:
    """Analyzes and tracks page state."""

    def __init__(self, page: Page, status: Status, max_history: int = 5):
        self.logger = logging.getLogger(__name__)
        self.page = page
        self.status = status
        self.console = Console()
        self.history: List[HistoryEntry] = []
        self.max_history = max_history

    def capture_state(self) -> PageState:
        """Capture and analyze current page state."""
        try:
            self.logger.debug("Starting page state capture")
            self.status.update("Loading page...")
            self._wait_for_load()
            self._update_history()

            self.logger.debug("Capturing and processing page screenshot")
            screenshot = self._capture_screenshot()
            encoded_image, label_coordinates, parsed_content = self._process_image(screenshot)

            self.logger.debug("Getting viewport and navigation info")
            viewport_info = ViewportInfo.from_page(self.page)
            nav_state = NavigationState.from_page(self.page)

            # Save debug screenshot with optimization
            image_bytes = base64.b64decode(encoded_image)
            annotated_image = Image.open(io.BytesIO(image_bytes))
            annotated_image.save(".screenshot.png", optimize=True)
            self.logger.debug("Debug screenshot saved")

            self.logger.debug("Page state capture completed")
            return PageState(
                encoded_image=encoded_image,
                label_coordinates=label_coordinates,
                parsed_content=parsed_content,
                screenshot=screenshot,
                history_text=self._format_history(),
                viewport_info=viewport_info,
                navigation_state=nav_state,
            )

        except TimeoutError:
            self.logger.warning("Page load timeout, proceeding with current state")
            self.status.update("Capturing current state...")
            return self._capture_current_state()

    def _capture_current_state(self) -> PageState:
        """Capture current state without waiting for load."""
        self.logger.debug("Capturing current state without load wait")
        screenshot = self._capture_screenshot()
        encoded_image, label_coordinates, parsed_content = self._process_image(screenshot)
        viewport_info = ViewportInfo.from_page(self.page)
        nav_state = NavigationState.from_page(self.page)

        image_bytes = base64.b64decode(encoded_image)
        annotated_image = Image.open(io.BytesIO(image_bytes))
        annotated_image.save(".screenshot.png", optimize=True)

        self.logger.debug("Current state capture completed")
        return PageState(
            encoded_image=encoded_image,
            label_coordinates=label_coordinates,
            parsed_content=parsed_content,
            screenshot=screenshot,
            history_text=self._format_history(),
            viewport_info=viewport_info,
            navigation_state=nav_state,
        )

    def _capture_screenshot(self) -> Image.Image:
        """Capture page screenshot."""
        self.logger.debug("Taking page screenshot")
        screenshot_bytes = self.page.screenshot(type="png")
        return Image.open(io.BytesIO(screenshot_bytes))

    def _process_image(
        self,
        screenshot: Image.Image,
        confidence_threshold: float = 0.15,  # Increased from 0.05 to reduce false positives
        iou_threshold: float = 0.3,  # Increased from 0.1 for better overlap detection
    ) -> Tuple[str, Dict, List[str]]:
        """Process screenshot with omniparser."""
        self.logger.debug(
            "Processing screenshot with omniparser (confidence: %.2f, iou: %.2f)", confidence_threshold, iou_threshold
        )
        self.status.update("Processing image...")
        result = omniparser.process_image(
            image=screenshot,
            confidence_threshold=confidence_threshold,
            iou_threshold=iou_threshold,
            image_size=screenshot.size[0],
        )
        self.logger.debug("Image processing completed")
        return result

    def _update_history(self) -> None:
        """Update page history."""
        try:
            current = HistoryEntry(url=self.page.url, title=self.page.title())
            self.logger.debug("Current page: %s - %s", current.title, current.url)

            if not self.history or self.history[-1] != current:
                self.history.append(current)
                if len(self.history) > self.max_history:
                    self.history.pop(0)
                self.logger.debug("History updated (entries: %d)", len(self.history))
        except Exception as e:
            self.logger.warning("Could not update history: %s", str(e))

    def _format_history(self) -> str:
        """Format history entries for prompt."""
        if not self.history:
            self.logger.debug("No history available")
            return "No history available yet."

        entries = []
        for entry in self.history:
            entries.append(f"URL: {entry.url}\nTitle: {entry.title}")

        self.logger.debug("History formatted (%d entries)", len(entries))
        return "\n\n".join(entries)

    def _wait_for_load(self, timeout: int = 5000) -> None:
        """Wait for page load with timeout."""
        try:
            self.logger.debug("Waiting for page load (timeout: %dms)", timeout)
            self.page.wait_for_load_state("domcontentloaded", timeout=timeout)
        except TimeoutError:
            self.logger.warning("Page load timeout after %dms", timeout)
