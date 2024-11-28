"""Color utilities for image processing and visualization."""
from typing import List, Tuple


class Color:
    """RGB color representation with BGR conversion capability."""
    BLACK: Tuple[int, int, int] = (0, 0, 0)
    WHITE: Tuple[int, int, int] = (255, 255, 255)

    def __init__(self, rgb: Tuple[int, int, int]):
        """Initialize color with RGB values."""
        self.rgb = rgb

    def as_bgr(self) -> Tuple[int, int, int]:
        """Convert to BGR color format for OpenCV."""
        return self.rgb[::-1]

    def as_rgb(self) -> Tuple[int, int, int]:
        """Get RGB color format."""
        return self.rgb


class ColorPalette:
    """Predefined color palette for visualization."""
    COLORS: List[Tuple[int, int, int]] = [
        (255, 0, 0),    # Red
        (0, 255, 0),    # Green
        (0, 0, 255),    # Blue
        (255, 255, 0),  # Yellow
        (255, 0, 255),  # Magenta
        (0, 255, 255),  # Cyan
    ]
    DEFAULT = Color((100, 0, 255))

    @staticmethod
    def by_idx(idx: int) -> Color:
        """Get color by index, cycling through available colors."""
        return Color(ColorPalette.COLORS[idx % len(ColorPalette.COLORS)])
